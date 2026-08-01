// QrEncodeWorker — the background QR-encode isolate behind the broadcast loop.
//
// The worker QR-encodes wire frames (source/repair/meta) on demand and caches
// the resulting matrices per pool index, so after the first pass through the
// pool the display loop is served from cache with zero re-encoding. Requests
// carry the wire bytes (the worker owns no byte state); replies carry the
// encoded matrices. esi -1 is the reserved META slot.
//
// The cache budget is measured in BYTES (default 16 MiB — the wire format's
// total-length cap) and converted to an entry count from the QR version's
// matrix size, so a V40 pool does not silently blow past the budget.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:qr_transfer_core/qr/qr_encode.dart';

/// Reserved pool index for the META frame (slot 0 on meta ticks).
const int metaSlotEsi = -1;

/// Default cache budget for [QrEncodeWorker]: the wire format caps a single
/// transfer at 16 MiB, so a budget of 16 MiB of matrices covers any file the
/// protocol can carry.
const int defaultEncodeCacheBytes = 16 * 1024 * 1024;

/// The QR-encode backend seam of the broadcast loop. The production
/// implementation is a background isolate ([QrEncodeWorker]); tests inject a
/// synchronous fake.
abstract class EncodeBackend {
  /// Requests the tiles for [frameIndex]. [esis] lists each tile's pool index
  /// ([metaSlotEsi] for the META slot); [frameBytes] carries the matching wire
  /// bytes (always non-null on first sight — the worker caches by esi, so
  /// re-requests of the same pool index are cheap).
  void requestFrame({
    required int frameIndex,
    required List<int> esis,
    required List<Uint8List?> frameBytes,
  });

  /// Non-blocking: every frame completed since the last call, in request
  /// order, as `(frameIndex, tiles)`. Callers drop frames older than what
  /// they have already rendered and apply at most one per display tick.
  List<(int, List<QrMatrix?>)> drain();

  /// Releases the backend (kills the isolate). Idempotent.
  void dispose();
}

/// Worker configuration sent once after the isolate handshake.
class _WorkerInit {
  _WorkerInit({required this.version, required this.maxCacheBytes});

  final int version;
  final int maxCacheBytes;
}

/// Request sent to the encode worker.
class _EncodeRequest {
  _EncodeRequest({
    required this.frameIndex,
    required this.esis,
    required this.frameBytes,
  });

  final int frameIndex;
  final List<int> esis;
  final List<Uint8List?> frameBytes;
}

/// Reply from the encode worker: one matrix per requested tile (null when a
/// tile failed to encode — e.g. a payload that overflows the QR version).
class _EncodeReply {
  _EncodeReply({required this.frameIndex, required this.tiles});

  final int frameIndex;
  final List<QrMatrix?> tiles;
}

/// Background QR-encode isolate with a bounded per-esi matrix cache.
///
/// [QrEncodeWorker] mirrors the DecodePool pattern: one isolate, a request
/// port and an ordered reply stream (a single sender/receiver pair preserves
/// message order, so replies arrive in request order with no ids). The cache
/// is an LRU capped at [maxCacheBytes] of matrices (default
/// [defaultEncodeCacheBytes]); evicted entries are simply re-encoded on their
/// next sighting.
class QrEncodeWorker implements EncodeBackend {
  QrEncodeWorker({
    required this.version,
    this.maxCacheBytes = defaultEncodeCacheBytes,
  }) : _inputPort = ReceivePort() {
    _spawn();
  }

  /// QR version every requested frame is encoded at.
  final int version;

  /// Cache budget in bytes of encoded matrices.
  final int maxCacheBytes;

  late final ReceivePort _inputPort;
  Future<Isolate>? _isolate;
  SendPort? _output;
  final List<(int, List<QrMatrix?>)> _ready = [];
  final List<Object> _pending = []; // requests queued until the handshake lands
  bool _disposed = false;

  void _spawn() {
    _isolate = Isolate.spawn(_encodeWorker, _inputPort.sendPort);
    // The worker announces its request port as the first message.
    _inputPort.listen((dynamic message) {
      if (message is SendPort) {
        _output = message;
        message.send(
          _WorkerInit(version: version, maxCacheBytes: maxCacheBytes),
        );
        for (final pending in _pending) {
          message.send(pending);
        }
        _pending.clear();
      } else {
        final reply = message as _EncodeReply;
        _ready.add((reply.frameIndex, reply.tiles));
      }
    });
  }

  @override
  void requestFrame({
    required int frameIndex,
    required List<int> esis,
    required List<Uint8List?> frameBytes,
  }) {
    if (_disposed) return;
    final request = _EncodeRequest(
      frameIndex: frameIndex,
      esis: esis,
      frameBytes: frameBytes,
    );
    final output = _output;
    if (output == null) {
      _pending.add(request);
    } else {
      output.send(request);
    }
  }

  @override
  List<(int, List<QrMatrix?>)> drain() {
    if (_ready.isEmpty) return const [];
    final out = List<(int, List<QrMatrix?>)>.of(_ready);
    _ready.clear();
    return out;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Kill the spawned isolate once it exists (dispose can race the spawn).
    _isolate?.then((iso) => iso.kill(priority: Isolate.immediate));
    _isolate = null;
    _inputPort.close();
  }
}

/// Isolate entrypoint: encodes [QrMatrix]es from wire bytes, caching by pool
/// index (LRU bounded by the init's byte budget); [metaSlotEsi] caches the
/// META matrix under its reserved index. Top-level, as isolate entrypoints
/// must be.
void _encodeWorker(SendPort announce) {
  final input = ReceivePort();
  announce.send(input.sendPort);
  var version = 27;
  var cache = _LruCache<int, QrMatrix>(maxEntries: 1024);
  input.listen((dynamic message) {
    if (message is _WorkerInit) {
      version = message.version;
      final matrixBytes = (version * 4 + 17) * (version * 4 + 17);
      cache = _LruCache<int, QrMatrix>(
        maxEntries: math.max(1, message.maxCacheBytes ~/ matrixBytes),
      );
      return;
    }
    final request = message as _EncodeRequest;
    final tiles = <QrMatrix?>[];
    for (var i = 0; i < request.esis.length; i++) {
      final esi = request.esis[i];
      final bytes = request.frameBytes[i];
      final cached = cache[esi];
      if (cached != null) {
        tiles.add(cached);
        continue;
      }
      if (bytes == null) {
        tiles.add(null);
        continue;
      }
      QrMatrix? matrix;
      try {
        matrix = encodeQrBytes(bytes, version: version);
      } on Exception {
        matrix = null;
      } catch (_) {
        // Any Error (e.g. ArgumentError) must not kill the worker isolate —
        // a dead worker would stall the whole broadcast.
        matrix = null;
      }
      if (matrix != null) cache[esi] = matrix;
      tiles.add(matrix);
    }
    announce.send(_EncodeReply(frameIndex: request.frameIndex, tiles: tiles));
  });
}

/// Minimal LRU map: iteration order is least-recently-used first, so eviction
/// is `removeFirst`. Not thread-safe — used only inside the worker isolate.
class _LruCache<K, V> {
  _LruCache({required this.maxEntries});

  final int maxEntries;
  final Map<K, V> _map = <K, V>{};

  V? operator [](K key) {
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value; // move to most-recently-used (map insertion order)
    return value;
  }

  void operator []=(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > maxEntries) {
      _map.remove(_map.keys.first);
    }
  }
}
