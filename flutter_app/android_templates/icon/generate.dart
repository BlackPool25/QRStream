// QRStream launcher icon generator.
//
// Reproduces the entire Android launcher icon set deterministically:
//   * adaptive icon (API 26+): espresso background + cream QR foreground
//   * legacy mipmap PNGs (mdpi..xxxhdpi) with rounded corners
//
// The QR glyph is encoded by the app's own QR engine (package:qr ^4.0.0,
// same call shape as core/lib/qr/qr_encode.dart: Ecc.LOW, forced mask 2),
// so the icon IS a real, scannable QRSTREAM code.
//
// Run from flutter_app/ (so .dart_tool/package_config.json resolves
// package:qr), with ImageMagick available:
//
//   ~/dart-sdk/bin/dart android_templates/icon/generate.dart
//
// Deterministic: fixed payload + mask, PNGs carry no timestamps, ImageMagick
// is invoked with png:include-chunk=none. Re-running overwrites in place.
//
// Standalone tool (not part of the app's package graph): it resolves
// package:qr through the app's .dart_tool config and keeps an unused cream
// brand const for documentation, so the app-level lints don't apply.
// ignore_for_file: depend_on_referenced_packages, unused_element, unused_local_variable, prefer_spread_collections

import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';

import 'package:qr/qr.dart';

// ---------------------------------------------------------------------------
// Brand constants (match the locked theme exactly).
// ---------------------------------------------------------------------------
const _espresso = '#161312'; // dark surface — broadcast stage, icon background
const _cream = '#FFF8F6'; // warm cream — QR modules
const _masterModulePx = 32; // master glyph rasterisation scale

// Composition parameters.
const _quietZone = 4; // QR quiet-zone modules around the code
const _adaptiveGlyphFrac = 0.58; // glyph-with-quiet-zone over 108dp canvas
const _legacyGlyphFrac = 0.75; // glyph-with-quiet-zone over legacy icon
const _cornerRadiusFrac = 0.2; // legacy icon rounded-corner radius

// Legacy density map: density name -> icon size in px.
const _legacySizes = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

// ---------------------------------------------------------------------------
// Minimal deterministic PNG encoder (RGBA, 8-bit, no ancillary chunks).
// ---------------------------------------------------------------------------
Uint32List _crcTable() {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}

final Uint32List _crcTableData = _crcTable();

int _crc32(List<int> bytes, int start, int end) {
  var crc = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    crc = _crcTableData[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

void _writeChunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final len = data.length;
  final lenBytes = Uint8List(4)
    ..[0] = (len >> 24) & 0xFF
    ..[1] = (len >> 16) & 0xFF
    ..[2] = (len >> 8) & 0xFF
    ..[3] = len & 0xFF;
  out.add(lenBytes);
  out.add(typeBytes);
  out.add(data);
  final full = <int>[]..addAll(typeBytes)..addAll(data);
  final crcFull = _crc32(full, 0, full.length);
  out.add([
    (crcFull >> 24) & 0xFF,
    (crcFull >> 16) & 0xFF,
    (crcFull >> 8) & 0xFF,
    crcFull & 0xFF,
  ]);
}

/// Encodes [rgba] (width*height*4 bytes) as a minimal PNG.
Uint8List _encodePng(int width, int height, Uint8List rgba) {
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder();
  ihdr.add(_be32(width));
  ihdr.add(_be32(height));
  ihdr.add([8, 6, 0, 0, 0]); // 8-bit, RGBA, deflate, adaptive, no interlace
  _writeChunk(out, 'IHDR', ihdr.takeBytes());

  // Raw scanlines: each row prefixed with filter type 0.
  final stride = width * 4;
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    raw.add(rgba.sublist(y * stride, (y + 1) * stride));
  }
  final idat = zlib.encode(raw.takeBytes());
  _writeChunk(out, 'IDAT', idat);

  _writeChunk(out, 'IEND', const []);
  return out.takeBytes();
}

Uint8List _be32(int v) => Uint8List(4)
  ..[0] = (v >> 24) & 0xFF
  ..[1] = (v >> 16) & 0xFF
  ..[2] = (v >> 8) & 0xFF
  ..[3] = v & 0xFF;

// ---------------------------------------------------------------------------
// QR encoding — mirrors core/lib/qr/qr_encode.dart exactly.
// ---------------------------------------------------------------------------
/// Row-major module matrix of the QRSTREAM payload at Ecc.LOW, mask 2.
Uint8List _qrModules() {
  final code = QrCode(
    payload: QrPayload.fromTypedData(Uint8List.fromList(utf8.encode('QRSTREAM'))),
    errorCorrectLevel: QrErrorCorrectLevel.low,
    minTypeNumber: 1,
  );
  final image = QrImage.withMaskPattern(code, 2);
  final size = image.moduleCount;
  final modules = Uint8List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (image.isDark(y, x)) modules[y * size + x] = 1;
    }
  }
  return modules;
}

// ---------------------------------------------------------------------------
// Paths.
// ---------------------------------------------------------------------------
late final Directory _scriptDir;
late final Directory _appRoot; // flutter_app/
late final Directory _resRoot; // flutter_app/android/app/src/main/res/
late final Directory _workDir; // scratch (system temp; never committed)

void _initPaths() {
  _scriptDir = File.fromUri(Platform.script).parent;
  _appRoot = _scriptDir.parent.parent;
  _resRoot = Directory(
    '${_appRoot.path}${Platform.pathSeparator}android'
    '${Platform.pathSeparator}app'
    '${Platform.pathSeparator}src'
    '${Platform.pathSeparator}main'
    '${Platform.pathSeparator}res',
  );
  // Deterministic scratch path (system temp), outside the repo tree.
  final tmp = Directory.systemTemp;
  _workDir = Directory(
    '${tmp.path}${Platform.pathSeparator}qrstream_icon_gen',
  );
  if (!_workDir.existsSync()) _workDir.createSync(recursive: true);
}

// ---------------------------------------------------------------------------
// ImageMagick invocation.
// ---------------------------------------------------------------------------
late final String _magickBin;

String _findMagick() {
  for (final candidate in ['/usr/bin/magick', '/usr/bin/convert']) {
    if (File(candidate).existsSync()) return candidate;
  }
  final which = Process.runSync('which', ['magick']);
  if (which.exitCode == 0) return (which.stdout as String).trim();
  throw StateError('ImageMagick (magick/convert) not found on PATH');
}

Future<void> _runMagick(List<String> args) async {
  final result = await Process.run(_magickBin, args);
  if (result.exitCode != 0) {
    throw StateError(
      'ImageMagick failed (${result.exitCode}): ${result.stderr}',
    );
  }
}

/// Writes the cream-on-transparent QR glyph with quiet zone at [glyphPx] onto
/// an [espresso] or transparent canvas of [canvasPx] px, centered.
Future<void> _composeGlyph({
  required String masterPath,
  required int canvasPx,
  required int glyphPx,
  required String background, // 'none' or a hex colour
  required String outPath,
}) async {
  final size = '$canvasPx${'x'}$canvasPx';
  final cmd = <String>[
    '-size',
    size,
    'xc:$background',
    r'(',
    masterPath,
    '-filter',
    'point',
    '-resize',
    '${glyphPx}x$glyphPx',
    r')',
    '-gravity',
    'center',
    '-composite',
    '-define',
    'png:include-chunk=none',
    outPath,
  ];
  await _runMagick(cmd);
}

/// Applies rounded corners of [radius]% to a square icon.
Future<void> _roundCorners({
  required int size,
  required String path,
}) async {
  final radius = (size * _cornerRadiusFrac).round();
  final maskPath = '${_workDir.path}${Platform.pathSeparator}corner_mask_$size.png';
  await _runMagick([
    '-size',
    '${size}x$size',
    'xc:none',
    '-draw',
    'roundrectangle 0,0,${size - 1},${size - 1},$radius,$radius',
    '-define',
    'png:include-chunk=none',
    maskPath,
  ]);
  await _runMagick([
    path,
    maskPath,
    '-alpha',
    'set',
    '-compose',
    'DstIn',
    '-composite',
    '-define',
    'png:include-chunk=none',
    path,
  ]);
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------
Future<void> main() async {
  _initPaths();
  _magickBin = _findMagick();

  final modules = _qrModules();
  final qrSize = sqrt(modules.length).round();

  // --- master glyph PNG: cream QR + quiet zone on transparent -------------
  final grid = qrSize + 2 * _quietZone;
  final masterPx = grid * _masterModulePx;
  final rgba = Uint8List(masterPx * masterPx * 4);
  const cream = (0xFF, 0xF8, 0xF6);
  for (var gy = 0; gy < grid; gy++) {
    for (var gx = 0; gx < grid; gx++) {
      final mx = gx - _quietZone;
      final my = gy - _quietZone;
      final dark =
          mx >= 0 && my >= 0 && mx < qrSize && my < qrSize && modules[my * qrSize + mx] == 1;
      if (!dark) continue;
      for (var py = 0; py < _masterModulePx; py++) {
        for (var px = 0; px < _masterModulePx; px++) {
          final idx = ((gy * _masterModulePx + py) * masterPx + (gx * _masterModulePx + px)) * 4;
          rgba[idx] = 255;
          rgba[idx + 1] = 248;
          rgba[idx + 2] = 246;
          rgba[idx + 3] = 255;
        }
      }
    }
  }
  final masterPath = '${_workDir.path}${Platform.pathSeparator}master_qr.png';
  File(masterPath).writeAsBytesSync(_encodePng(masterPx, masterPx, rgba));
  stdout.writeln('QR payload QRSTREAM -> ${qrSize}x$qrSize modules, '
      'master ${masterPx}x$masterPx');

  // --- adaptive icon (API 26+) ---------------------------------------------
  const adaptiveCanvas = 432; // 108dp @ 4x
  final adaptiveGlyph =
      ((adaptiveCanvas * _adaptiveGlyphFrac) / 2).round() * 2; // keep even → exact center
  final adaptiveDir = Directory(
    '${_resRoot.path}${Platform.pathSeparator}mipmap-anydpi-v26',
  );
  adaptiveDir.createSync(recursive: true);
  final foregroundPng = '${_resRoot.path}${Platform.pathSeparator}mipmap-xxxhdpi'
      '${Platform.pathSeparator}ic_launcher_foreground.png';
  Directory(File(foregroundPng).parent.path).createSync(recursive: true);
  await _composeGlyph(
    masterPath: masterPath,
    canvasPx: adaptiveCanvas,
    glyphPx: adaptiveGlyph,
    background: 'none',
    outPath: foregroundPng,
  );

  File('${adaptiveDir.path}${Platform.pathSeparator}ic_launcher.xml')
      .writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
''');

  final drawableDir = Directory('${_resRoot.path}${Platform.pathSeparator}drawable');
  drawableDir.createSync(recursive: true);
  File('${drawableDir.path}${Platform.pathSeparator}ic_launcher_background.xml')
      .writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#161312" />
</shape>
''');
  File('${drawableDir.path}${Platform.pathSeparator}ic_launcher_foreground.xml')
      .writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<bitmap xmlns:android="http://schemas.android.com/apk/res/android"
    android:src="@mipmap/ic_launcher_foreground"
    android:gravity="center" />
''');

  // --- legacy mipmap PNGs (API 24-25 + non-adaptive launchers) -------------
  for (final entry in _legacySizes.entries) {
    final size = entry.value;
    final glyph = ((size * _legacyGlyphFrac) / 2).round() * 2;
    final dir = Directory(
      '${_resRoot.path}${Platform.pathSeparator}mipmap-${entry.key}',
    );
    dir.createSync(recursive: true);
    final outPath = '${dir.path}${Platform.pathSeparator}ic_launcher.png';
    await _composeGlyph(
      masterPath: masterPath,
      canvasPx: size,
      glyphPx: glyph,
      background: _espresso,
      outPath: outPath,
    );
    await _roundCorners(size: size, path: outPath);
  }

  // --- report ---------------------------------------------------------------
  stdout.writeln('Wrote adaptive icon (canvas ${adaptiveCanvas}px, '
      'glyph ${adaptiveGlyph}px @ ${(adaptiveGlyph / adaptiveCanvas * 100).toStringAsFixed(1)}%)');
  for (final entry in _legacySizes.entries) {
    final size = entry.value;
    final glyph = ((size * _legacyGlyphFrac) / 2).round() * 2;
    stdout.writeln(
        'Wrote mipmap-${entry.key}/ic_launcher.png (${size}px, glyph ${glyph}px)');
  }
  stdout.writeln('Done.');
}
