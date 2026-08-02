// ZXing-C++ QR decode FFI facade — Wave A2, the native implementation of the
// receive-view QR decoder seam. Wraps the flutter_rust_bridge-generated
// `decodeQrBarcodes` (core/lib/rust/) behind a tight-luma API: the camera
// receive path hands over a row-major grayscale frame and gets every QR
// payload in it back, byte-exact.
//
// The generated bridge (FRB 2.12.0) types the luma param as `List<int>`
// (loose) rather than `Uint8List` — FRB maps `Vec<u8>` params to `List<int>`
// by default and offers no per-function annotation to switch to a strict
// `Uint8List`. A luma frame is ~0.9–2 MB (720p–1080p), so this facade does the
// single `Uint8List` → `List<int>` conversion at the call site; the FFI call
// itself stays synchronous. The return value (`Vec<Vec<u8>>`) maps to
// `List<Uint8List>` (strict), so decoded payloads come back zero-copy.
import 'dart:typed_data';

import 'package:qr_transfer_core/codec/raptorq_bridge.dart' show ensureRustLib;
import 'package:qr_transfer_core/rust/api.dart' show decodeQrBarcodes;

/// Result type of the FFI decoder seam (the receive view decodes QR payloads).
typedef ZxingCppDecode =
    List<Uint8List> Function(Uint8List luma, int width, int height);

/// Decodes every QR in a tight luma buffer; empty when none. Throws on
/// dimension mismatch or FFI failure.
///
/// [luma] is a tight, row-major grayscale frame (1 byte/px, dark = 0,
/// light = 255) of exactly `width * height` bytes — the layout
/// `decode_qr_barcodes` (rust/src/api.rs) expects. Requires the Rust dylib to
/// be loaded (see [ensureRustLib]); tests call it in `setUpAll`.
List<Uint8List> decodeLuma(Uint8List luma, int width, int height) {
  return decodeQrBarcodes(luma: luma.toList(), width: width, height: height);
}
