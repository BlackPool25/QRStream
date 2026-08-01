import 'package:flutter/material.dart';

import 'app_theme_constants.dart';

export 'app_theme_constants.dart' show qrStageBackground;

/// Bundled Fraunces variable font family (see pubspec `flutter: fonts:`);
/// declared with the same name the asset registers, so text styles can
/// reference it directly — no google_fonts indirection.
const String _frauncesFamily = 'Fraunces';

/// Builds the app-wide Material 3 theme for [brightness].
///
/// RESEARCH-LOCKED (Wave 5 T5.1): cocoa seed `0xFF6D4C41` with the `content`
/// dynamic scheme variant, plus per-brightness role overrides pinned in
/// `app_theme_constants.dart`. Do not improvise values; change the constants
/// and the theme test together.
ThemeData buildAppTheme(Brightness brightness) {
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
  // Material type so dense screens read as system text. The bundled variable
  // font carries all weights, so plain fontFamily + the theme's FontWeight
  // resolve correctly offline.
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
  ).textTheme;
  TextStyle? fraunces(TextStyle? style) => style?.copyWith(
    fontFamily: _frauncesFamily,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: base.copyWith(
      displayLarge: fraunces(base.displayLarge),
      displayMedium: fraunces(base.displayMedium),
      displaySmall: fraunces(base.displaySmall),
      headlineLarge: fraunces(base.headlineLarge),
      headlineMedium: fraunces(base.headlineMedium),
      headlineSmall: fraunces(base.headlineSmall),
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
