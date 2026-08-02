# Google ML Kit barcode scanning is reached through firebase-components
# registration and reflection; the bundled in-APK model's native classes are
# not referenced directly. R8 in AGP 9 full mode strips them and the release
# build then crashes with "getClass() on a null object reference" inside
# BarcodeScanner.process(). Keep every ML Kit barcode class reached
# dynamically: the public API + client (com.google.mlkit.vision.barcode,
# incl. the bundled.internal ThickBarcodeScannerCreator the client dispatches
# to), the bundled model implementation, and the common internals.
-keep class com.google.mlkit.vision.barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode_bundled.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
