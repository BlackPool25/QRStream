# Google ML Kit is reached through firebase-components registration, reflection
# and Android content-provider discovery (MlKitInitProvider builds the
# component dependency graph at process start). R8 in AGP 9 full mode strips
# the reachable-only-via-registration classes and the release build then
# crashes — either at startup with "Unsatisfied dependency ... class
# com.google.mlkit.common.sdkinternal.d" (MlKitInitProvider) or at scan time
# with "getClass() on a null object reference" (BarcodeScanner.process()). Keep
# every ML Kit class reached dynamically: the whole com.google.mlkit tree (the
# common base SDK + the barcode client incl. the bundled.internal
# ThickBarcodeScannerCreator it dispatches to), the firebase-components
# framework that wires it, and the bundled model implementations.
-keep class com.google.mlkit.** { *; }
-keep class com.google.firebase.components.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode_bundled.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
