import 'package:crypto/crypto.dart';

/// SHA-256 of [bytes] as a lowercase 64-character hex string.
///
/// Uses the `crypto` package's synchronous digest, unlike the async WebCrypto
/// implementation in the TypeScript reference (`src/protocol/sha256.ts`).
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
