// QRStream launcher icon generator — LOGO variant.
//
// Builds the Android launcher icon set + the Linux window/desktop icon from
// the user's logo (repo-root logo.png, 485x485 RGBA), instead of the default
// QRSTREAM QR glyph (see generate.dart). Uses ImageMagick for all raster
// composition; the output matches the QR variant's structure so the rest of
// the Android resource tree is unchanged.
//
//   * adaptive icon (API 26+): espresso background + logo foreground
//   * legacy mipmap PNGs (mdpi..xxxhdpi) with rounded corners
//   * linux/runner/icon.png (256px) for the Linux window + .desktop icon
//
// Run from flutter_app/ with ImageMagick available:
//
//   ~/dart-sdk/bin/dart android_templates/icon/generate_logo.dart
//
// Deterministic composition (fixed fractions + espresso), PNGs carry no
// timestamps (png:include-chunk=none). Re-running overwrites in place.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Brand constants (match the locked theme exactly).
// ---------------------------------------------------------------------------
const _espresso = '#161312'; // dark surface — icon background

const _adaptiveLogoFrac = 0.56; // logo over 108dp adaptive canvas
const _legacyLogoFrac = 0.72; // logo over legacy icon
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
  final tmp = Directory.systemTemp;
  _workDir = Directory(
    '${tmp.path}${Platform.pathSeparator}qrstream_icon_gen_logo',
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

/// Composes the logo onto [canvasPx] x [canvasPx], centered at [logoFrac] of
/// the canvas, on [background] ('none' or a hex colour) -> [outPath].
Future<void> _composeLogo({
  required String logoPath,
  required int canvasPx,
  required double logoFrac,
  required String background,
  required String outPath,
}) async {
  // Keep even so the composite centers exactly.
  final logoPx = ((canvasPx * logoFrac) / 2).round() * 2;
  final size = '${canvasPx}x$canvasPx';
  await _runMagick([
    '-size',
    size,
    'xc:$background',
    r'(',
    logoPath,
    '-resize',
    '${logoPx}x$logoPx',
    r')',
    '-gravity',
    'center',
    '-composite',
    '-define',
    'png:include-chunk=none',
    outPath,
  ]);
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

  final logoPath = File(
    '${_scriptDir.path}${Platform.pathSeparator}..'
    '${Platform.pathSeparator}..'
    '${Platform.pathSeparator}..'
    '${Platform.pathSeparator}logo.png',
  ).absolute.path;
  if (!File(logoPath).existsSync()) {
    throw StateError('logo.png not found at $logoPath — drop the logo there.');
  }

  // --- master logo glyph: padded on transparent so nothing touches edges ----
  final masterPath = '${_workDir.path}${Platform.pathSeparator}master_logo.png';
  await _runMagick([
    logoPath,
    '-bordercolor',
    'none',
    '-border',
    '10%',
    '-define',
    'png:include-chunk=none',
    masterPath,
  ]);
  stdout.writeln('logo -> master glyph: $masterPath');

  // --- adaptive icon (API 26+) ---------------------------------------------
  const adaptiveCanvas = 432; // 108dp @ 4x
  final adaptiveDir = Directory(
    '${_resRoot.path}${Platform.pathSeparator}mipmap-anydpi-v26',
  );
  adaptiveDir.createSync(recursive: true);
  final foregroundPng = '${_resRoot.path}${Platform.pathSeparator}mipmap-xxxhdpi'
      '${Platform.pathSeparator}ic_launcher_foreground.png';
  Directory(File(foregroundPng).parent.path).createSync(recursive: true);
  await _composeLogo(
    logoPath: masterPath,
    canvasPx: adaptiveCanvas,
    logoFrac: _adaptiveLogoFrac,
    background: 'none',
    outPath: foregroundPng,
  );

  // espresso background (same XML shape as the QR generator).
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
  File('${adaptiveDir.path}${Platform.pathSeparator}ic_launcher.xml')
      .writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
''');

  // --- legacy mipmap PNGs (API 24-25 + non-adaptive launchers) -------------
  for (final entry in _legacySizes.entries) {
    final size = entry.value;
    final dir = Directory(
      '${_resRoot.path}${Platform.pathSeparator}mipmap-${entry.key}',
    );
    dir.createSync(recursive: true);
    final outPath = '${dir.path}${Platform.pathSeparator}ic_launcher.png';
    await _composeLogo(
      logoPath: masterPath,
      canvasPx: size,
      logoFrac: _legacyLogoFrac,
      background: _espresso,
      outPath: outPath,
    );
    await _roundCorners(size: size, path: outPath);
  }

  // --- Linux window / desktop icon (256px) ----------------------------------
  final linuxIcon = File(
    '${_appRoot.path}${Platform.pathSeparator}linux'
    '${Platform.pathSeparator}runner'
    '${Platform.pathSeparator}icon.png',
  );
  linuxIcon.parent.createSync(recursive: true);
  await _composeLogo(
    logoPath: masterPath,
    canvasPx: 256,
    logoFrac: _legacyLogoFrac,
    background: _espresso,
    outPath: linuxIcon.path,
  );

  // --- report ---------------------------------------------------------------
  stdout.writeln('Wrote adaptive icon (canvas ${adaptiveCanvas}px, '
      'logo ${((adaptiveCanvas * _adaptiveLogoFrac) / 2).round() * 2}px)');
  for (final entry in _legacySizes.entries) {
    stdout.writeln(
        'Wrote mipmap-${entry.key}/ic_launcher.png (${entry.value}px)');
  }
  stdout.writeln('Wrote linux/runner/icon.png (256px)');
  stdout.writeln('Done.');
}
