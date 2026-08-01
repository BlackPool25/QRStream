import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_theme_constants.dart';

export 'app_theme_constants.dart' show qrStageBackground;

/// Builds the app-wide Material 3 theme for [brightness].
///
/// RESEARCH-LOCKED (Wave 5 T5.1): cocoa seed `0xFF6D4C41` with the `content`
/// dynamic scheme variant, plus per-brightness role overrides pinned in
/// `app_theme_constants.dart`. Do not improvise values; change the constants
/// and the theme test together.
ThemeData buildAppTheme(Brightness brightness) {
  // Offline-first: never fetch fonts at runtime. Fraunces is bundled as an
  // asset (see pubspec `flutter: fonts:`), so text rendering falls back to
  // the declared 'Fraunces' family instead of a network fetch.
  GoogleFonts.config.allowRuntimeFetching = false;

  final isLight = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: seedBrown,
    dynamicSchemeVariant: DynamicSchemeVariant.content,
    brightness: brightness,
  ).copyWith(
    primary: isLight ? lightPrimary : darkPrimary,
    surface: isLight ? lightSurface : darkSurface,
    primaryContainer: isLight ? lightPrimaryContainer : null,
    onPrimaryContainer: isLight ? lightOnPrimaryContainer : null,
    onPrimary: isLight ? null : darkOnPrimary,
    tertiary: isLight ? lightTertiary : darkTertiary,
    onTertiary: isLight ? lightOnTertiary : darkOnTertiary,
  );

  // Fraunces drives the display/headline tiers; body stays on the default
  // Material type so dense screens read as system text.
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
  ).textTheme;
  final fraunces = GoogleFonts.frauncesTextTheme(base);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: base.copyWith(
      displayLarge: fraunces.displayLarge,
      displayMedium: fraunces.displayMedium,
      displaySmall: fraunces.displaySmall,
      headlineLarge: fraunces.headlineLarge,
      headlineMedium: fraunces.headlineMedium,
      headlineSmall: fraunces.headlineSmall,
    ),
  );
}

/// Builds the QR broadcast stage theme — ALWAYS espresso dark, regardless of
/// the app brightness, so the camera-facing stage stays high-contrast.
///
/// [brightness] is accepted for call-site symmetry with [buildAppTheme] but
/// deliberately ignored: the broadcast stage is hard-coded dark.
ThemeData buildQrStageTheme([Brightness brightness = Brightness.dark]) {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: qrStageBackground,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedBrown,
      dynamicSchemeVariant: DynamicSchemeVariant.content,
      brightness: Brightness.dark,
    ).copyWith(
      surface: qrStageBackground,
      surfaceTint: Colors.transparent, // no elevation tint on the stage
    ),
  );
}
