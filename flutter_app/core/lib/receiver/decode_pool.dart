/// Isolate-backed QR decode pool — the Dart port of the PWA's
/// `src/receiver/pool.ts` + `src/workers/decode.worker.ts`.
///
/// QR decode is the receiver's bottleneck; the PWA runs 2–4 zxing-wasm
/// workers and the Flutter port runs the same count of Dart isolates, each
/// with its own zxing2 `QRCodeReader`. Decodes are dispatched round-robin and
/// correlated per-call by an incrementing id; `TransferableTypedData` carries
/// each RGB frame into the worker isolate with a single copy instead of the
/// serialize/copy round-trip of a plain `Uint8List`.
///
/// The pool accepts RAW RGB bytes (3 bytes/pixel) and returns the decoded QR
/// payload bytes — the wire frame the receiver feeds to FrameBuffer. The
/// camera service (app layer) converts camera frames to RGB. A frame with no
/// QR decodes to an empty list, never an error.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Worker count for a pool: leave one core to the UI isolate, cap at 4 (more
/// workers than that contend for the same decode throughput), never fewer
/// than 2. Port of the PWA's `poolSize`.
int poolSizeFor({int? hardwareConcurrency}) {
  final hardware = hardwareConcurrency ?? 1;
  return max(2, min(4, max(1, hardware - 1)));
}

/// One decoded QR. [bytes] carries the QR payload — the wire frame bytes the
/// receiver feeds to FrameBuffer; [text] is the same content as a string.
class DecodeResult {
  const DecodeResult({this.text, this.bytes});

  final String? text;
  final Uint8List? bytes;
}

/// A worker handle: its isolate, its request port, and its reply stream.
class _Worker {
  _Worker(this.isolate, this.input, this.replies);

  final Isolate isolate;
  final SendPort input;
  final ReceivePort replies;
}

/// Request sent to a worker; the RGB buffer rides on [rgb] and is transferred
/// (not copied) into the worker isolate.
class _DecodeRequest {
  _DecodeRequest({
    required this.id,
    required this.rgb,
    required this.width,
    required this.height,
  });

  final int id;
  final TransferableTypedData rgb;
  final int width;
  final int height;
}

/// Reply from a worker: decoded [results], or [error] when decoding threw.
class _DecodeReply {
  _DecodeReply({required this.id, this.results, this.error});

  final int id;
  final List<DecodeResult>? results;
  final String? error;
}

/// A pool of zxing2 decode isolates. Decodes are dispatched round-robin and
/// correlated per-call by id; the pool owns the isolates — call [dispose].
class DecodePool {
  /// Spawns [size] isolates (default [poolSizeFor]); explicit sizes floor at
  /// 2, matching the PWA's `Math.max(2, size)`.
  DecodePool({int? size})
    : _size = size == null ? poolSizeFor() : (size < 2 ? 2 : size) {
    _ready = _spawnWorkers();
  }

  final int _size;
  late final Future<void> _ready;
  List<_Worker> _workers = const [];
  final Map<int, Completer<List<DecodeResult>>> _pending = {};
  int _nextId = 0;
  int _cursor = 0;
  bool _disposed = false;

  /// Decodes QR codes from raw RGB pixels (`width * height * 3` bytes, row
  /// major). Returns the decoded payload bytes of every QR found; an image
  /// without a QR resolves to an empty list.
  Future<List<DecodeResult>> decode(Uint8List rgb, int width, int height) {
    if (_disposed) {
      return Future.error(StateError('DecodePool has been disposed'));
    }
    if (width <= 0 || height <= 0 || rgb.length != width * height * 3) {
      return Future.error(
        ArgumentError(
          'decode expects width * height * 3 RGB bytes, got $width x $height '
          'and ${rgb.length} bytes',
        ),
      );
    }
    final id = _nextId++;
    final transfer = TransferableTypedData.fromList(<Uint8List>[rgb]);
    return _ready.then((_) {
      if (_disposed) {
        throw StateError('DecodePool has been disposed');
      }
      final worker = _workers[_cursor % _workers.length];
      _cursor++;
      final completer = Completer<List<DecodeResult>>();
      _pending[id] = completer;
      worker.input.send(
        _DecodeRequest(id: id, rgb: transfer, width: width, height: height),
      );
      return completer.future;
    });
  }

  /// Terminates all isolates and rejects any in-flight decodes. Idempotent.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final worker in _workers) {
      worker.isolate.kill(priority: Isolate.immediate);
      worker.replies.close();
    }
    _workers = const [];
    final error = StateError('DecodePool has been disposed');
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _spawnWorkers() async {
    _workers = await Future.wait(List.generate(_size, (_) => _spawnWorker()));
    // Dispose can race the spawn: kill workers that came up after dispose.
    if (_disposed) {
      for (final worker in _workers) {
        worker.isolate.kill(priority: Isolate.immediate);
        worker.replies.close();
      }
      _workers = const [];
    }
  }

  Future<_Worker> _spawnWorker() async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_decodeWorker, replies.sendPort);
    // One listener carries both the init handshake (the worker's request port)
    // and the result replies; a ReceivePort cannot be re-listened after first.
    final init = Completer<SendPort>();
    replies.listen((dynamic message) {
      if (!init.isCompleted) {
        init.complete(message as SendPort);
      } else {
        _onReply(message);
      }
    });
    final input = await init.future;
    return _Worker(isolate, input, replies);
  }

  void _onReply(dynamic message) {
    final reply = message as _DecodeReply;
    final completer = _pending.remove(reply.id);
    if (completer == null) {
      return;
    }
    final error = reply.error;
    if (error != null) {
      completer.completeError(StateError(error));
    } else {
      completer.complete(reply.results!);
    }
  }
}

/// Isolate entrypoint: listens for [_DecodeRequest]s, decodes each with one
/// cached [QRCodeReader], and replies on [resultPort]. Announces its request
/// port to the pool as the first message. Top-level, as isolate entrypoints
/// must be.
void _decodeWorker(SendPort resultPort) {
  final input = ReceivePort();
  resultPort.send(input.sendPort);
  final reader = QRCodeReader();
  // Force Latin-1 text decoding so arbitrary byte payloads never throw from
  // the charset heuristic; [bytes] is unaffected and remains the contract.
  final hints = DecodeHints()..put(DecodeHintType.characterSet, 'ISO-8859-1');
  // Pure-grid decode: skips the finder detector, which is fragile on
  // perfectly aligned module grids (a dimension mod-4 estimation edge).
  final pureHints = DecodeHints()..put(DecodeHintType.pureBarcode);
  input.listen((dynamic message) {
    final request = message as _DecodeRequest;
    try {
      final results = _decodeRgb(request, reader, hints, pureHints);
      resultPort.send(_DecodeReply(id: request.id, results: results));
    } catch (error) {
      resultPort.send(_DecodeReply(id: request.id, error: '$error'));
    }
  });
}

List<DecodeResult> _decodeRgb(
  _DecodeRequest request,
  QRCodeReader reader,
  DecodeHints hints,
  DecodeHints pureHints,
) {
  final rgb = request.rgb.materialize().asUint8List();
  final width = request.width;
  final height = request.height;
  final pixels = Int32List(width * height);
  for (var i = 0, p = 0; i < rgb.length; i += 3, p++) {
    pixels[p] = 0xff000000 | (rgb[i] << 16) | (rgb[i + 1] << 8) | rgb[i + 2];
  }
  final bitmap = BinaryBitmap(
    GlobalHistogramBinarizer(RGBLuminanceSource(width, height, pixels)),
  );
  try {
    return [_resultFrom(reader.decode(bitmap, hints: hints))];
  } on ReaderException {
    // Detector failed; the pure path samples the module grid directly and
    // recovers clean, aligned QRs the finder pattern scan rejects.
    try {
      return [_resultFrom(reader.decode(bitmap, hints: pureHints))];
    } on ReaderException {
      return const [];
    }
  }
}

DecodeResult _resultFrom(Result result) {
  final segments =
      result.resultMetadata[ResultMetadataType.byteSegments] as List<Int8List>?;
  final bytes = _joinSegments(segments);
  return DecodeResult(
    text: result.text.isEmpty ? null : result.text,
    bytes: (bytes == null || bytes.isEmpty) ? null : bytes,
  );
}

/// Concatenates the byte-mode payload segments — the exact encoded bytes,
/// unlike [Result.rawBytes], which also carries mode headers and padding.
Uint8List? _joinSegments(List<Int8List>? segments) {
  if (segments == null) {
    return null;
  }
  var total = 0;
  for (final segment in segments) {
    total += segment.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final segment in segments) {
    for (var i = 0; i < segment.length; i++) {
      out[offset + i] = segment[i] & 0xff;
    }
    offset += segment.length;
  }
  return out;
}
