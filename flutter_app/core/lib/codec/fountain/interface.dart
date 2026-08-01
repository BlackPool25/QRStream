// Fountain codec contract for the Dart core (Wave 2 T2.4).
//
// Byte-oriented port of the PWA's src/codec/fountain/interface.ts. Codecs hand
// out wire-serialized packet bytes that round-trip through the protocol's
// DATA frames untouched; implementations live behind FFI (the Rust facade,
// T2.3) or a fallback. This file is the contract only — no codec logic.
import 'dart:typed_data';

/// Wire-serialized encoding packet (header + payload), ready for a DATA frame.
class EncodedSymbol {
  const EncodedSymbol({required this.bytes, required this.esi});

  /// Wire-serialized encoding packet (header + payload), ready for a DATA frame.
  final Uint8List bytes;

  /// Encoding symbol id. Advisory for the caller (e.g. progress "k/unique");
  /// the decoder itself dedups by esi internally, so duplicate bytes are
  /// harmless.
  final int esi;
}

/// Encoder for one file. Implemented by the Rust facade (T2.3).
abstract class FountainEncoder {
  /// The K source symbols in esi order — the systematic set.
  List<EncodedSymbol> encodeSourceSymbols();

  /// K source symbols followed by `count` repair symbols (fresh serializations).
  List<EncodedSymbol> encodeRepair(int count);

  /// Wire byte size of one encoded symbol (== mtu for the supported profiles).
  int get symbolSize;

  /// K = ceil(fileLength / (symbolSize - 4)), for progress and profile
  /// selection.
  int get sourceSymbolCount;

  /// Releases the underlying codec resources. No-op after the first call.
  void dispose();
}

/// One-shot decoder for one transfer of one file. Implemented by the Rust
/// facade (T2.3).
abstract class FountainDecoder {
  /// Feeds one encoded symbol; returns the full file once >=K distinct
  /// symbols have arrived, null until then. Order-independent; duplicates
  /// harmless. After completion, keeps returning the recovered file.
  Uint8List? decode(Uint8List symbolBytes);

  /// True once [decode] has returned the recovered file.
  bool get isComplete;

  /// Releases the underlying codec resources. No-op after the first call.
  void dispose();
}

/// Builds encoders and decoders for transfers. Implemented by the Rust facade
/// (T2.3).
abstract class FountainFactory {
  /// Builds an encoder for one file. [mtu] must be an integer in
  /// [minMtu, maxMtu].
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu);

  /// Builds a one-shot decoder for one transfer of [totalLength] bytes.
  Future<FountainDecoder> createDecoder(int totalLength, int mtu);
}

/// Smallest wire symbol size (== smallest QR tile byte capacity).
const int minMtu = 64;

/// Largest wire symbol size (a full QR V40 tile).
const int maxMtu = 65535;

/// K = ceil(totalLength / (mtu - 4)) — the source symbol count used for
/// progress and profile selection. The -4 is the per-symbol wire header.
/// A zero-length payload yields 0 (ceil(0 / x) == 0): nothing to encode, the
/// sender skips it.
int symbolCountForLength(int totalLength, int mtu) =>
    (totalLength / (mtu - 4)).ceil();

/// Pipeline-side guard before hitting FFI. The Rust crate enforces the same
/// bound; this keeps invalid mtus out of the codec boundary.
void assertMtuValid(int mtu) {
  RangeError.checkValueInInterval(mtu, minMtu, maxMtu, 'mtu');
}
