import 'dart:ui';

// Research-locked Material 3 "cocoa" palette (Wave 5 T5.1).
//
// These values are the contract from the theme research. They live in the
// app layer (not core/) because `Color` comes from dart:ui, and core is
// pure Dart. Deviating from any of them requires re-running the theme
// research and updating this file and test/theme/app_theme_test.dart together.

/// Brand seed: cocoa. Drives `ColorScheme.fromSeed(..., DynamicSchemeVariant.content)`.
const seedBrown = Color(0xFF6D4C41);

// --- Light roles ---------------------------------------------------------
const lightPrimary = Color(0xFF53352B); // deep cocoa
const lightSurface = Color(0xFFFFF8F6); // warm cream
const lightPrimaryContainer = Color(0xFF6D4C41); // == seed
const lightOnPrimaryContainer = Color(0xFFEBBEB0);
const lightTertiary = Color(0xFF9A5B12); // deep amber accent
const lightOnTertiary = Color(0xFFFFFFFF); // white-ish on deep amber

// --- Dark roles ----------------------------------------------------------
const darkPrimary = Color(0xFFE9BDAE); // warm tan
const darkOnPrimary = Color(0xFF452920);
const darkSurface = Color(0xFF161312); // espresso
const darkTertiary = Color(0xFFFFC46B); // honey accent
const darkOnTertiary = Color(0xFF462A00);

/// QR broadcast stage background — hard-coded espresso regardless of app
/// brightness. The camera-facing stage is always dark for contrast.
const qrStageBackground = Color(0xFF161312);
