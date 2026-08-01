import 'dart:typed_data';

import 'package:qr/qr.dart';

/// Row-major QR module matrix; 1 = dark, 0 = light. Length = size * size.
/// Shape parity with the PWA's QrMatrix (src/qr/encode.ts), consumed by the
/// broadcast renderer.
class QrMatrix {
  const QrMatrix({required this.modules, required this.size});

  final Uint8List modules;
  final int size;
}

/// Thrown when a payload does not fit in the requested (or maximum) QR
/// version at Ecc.LOW — the Dart counterpart of the PWA's DataTooLongError.
class QrTooLongException implements Exception {
  const QrTooLongException(this.dataLen, this.version);

  final int dataLen;
  final int version;

  @override
  String toString() =>
      'QrTooLongException: $dataLen bytes do not fit in QR version '
      '$version at Ecc.LOW';
}

/// Largest byte payload a single QR code can hold (version 40, Ecc.LOW).
const maxQrCapacity = 2953;

/// Encode raw packet bytes into a QR module matrix.
///
/// Byte-oriented and Flutter-free so it runs in standalone `dart` tests and
/// in the sender loop alike. Parity with `encodeQrBytes` in src/qr/encode.ts:
/// forced mask (default 2), Ecc.LOW, and — when [version] is given — the
/// exact QR version (no silent upsize, matching the PWA's
/// minVersion=maxVersion call).
QrMatrix encodeQrBytes(Uint8List data, {int? version, int mask = 2}) {
  final QrCode code;
  try {
    code = QrCode(
      payload: QrPayload.fromTypedData(data),
      errorCorrectLevel: QrErrorCorrectLevel.low,
      minTypeNumber: version ?? 1,
    );
  } on InputTooLongException {
    throw QrTooLongException(data.length, version ?? 40);
  }
  // The package auto-selects the smallest version >= minTypeNumber that
  // fits; exact-version parity requires rejecting payloads that only fit a
  // larger version (e.g. 2082 bytes at V33 fits V34, and must throw).
  if (version != null && code.typeNumber != version) {
    throw QrTooLongException(data.length, version);
  }
  final image = QrImage.withMaskPattern(code, mask);
  final size = image.moduleCount;
  final modules = Uint8List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (image.isDark(y, x)) modules[y * size + x] = 1;
    }
  }
  return QrMatrix(modules: modules, size: size);
}

/// Largest integer pixel scale that renders [modules] modules within
/// [targetPx], floored at 1 — the render helper used by pacing's
/// computeLayoutGeometry (modules stay at whole-pixel scales for the camera).
int integerScalePx(int modules, int targetPx) {
  final scale = targetPx ~/ modules;
  return scale < 1 ? 1 : scale;
}
