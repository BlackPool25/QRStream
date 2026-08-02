// RaptorQ FFI facade — T2.3, the native implementation of the fountain codec
// contract (Wave 2). Wraps the flutter_rust_bridge-generated bridge
// (core/lib/rust/) behind the codec/fountain/interface.dart contract, so the
// Dart app talks to native Rust RaptorQ through a generated, type-checked
// bridge that loads under plain `dart test`.
//
// Wire format (verified against the raptorq 2.0.1 crate and the PWA fixtures):
// every encoding packet is `[SBN u8][ESI BE24] + symbol bytes`, total length ==
// mtu. The single source block always carries SBN == 0; ESI is the 24-bit
// big-endian value in bytes 1..=3 — the same layout the PWA's wire frames carry,
// so FrameBuffer dedup by (sessionId, esi) works identically to the PWA.
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart' show visibleForTesting;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/rust/api.dart';
import 'package:qr_transfer_core/rust/frb_generated.dart' show RustLib;

/// Default debug dylib, relative to the `core/` package dir (`dart test` runs
/// from there, proven by the FRB spike).
const String _defaultDebugDylibPath =
    '../rust/target/debug/libqr_transfer_rust.so';

/// Default release dylib, same base.
const String _defaultReleaseDylibPath =
    '../rust/target/release/libqr_transfer_rust.so';

/// Windows defaults: the codec DLL is `qr_transfer_rust.dll` (no `lib`
/// prefix), and under `dart test` the cargo target dir is the same layout.
const String _defaultWindowsDebugDylibPath =
    '../rust/target/debug/qr_transfer_rust.dll';
const String _defaultWindowsReleaseDylibPath =
    '../rust/target/release/qr_transfer_rust.dll';

Future<void>? _rustLibInit;

/// Lazily initializes the Rust FFI library exactly once; every caller shares
/// the same Future, so `RustLib.init` (which throws if called twice) runs a
/// single time. If the first attempt fails (e.g. the dylib is missing), the
/// init state resets so a later call can retry.
///
/// [dylibPath] overrides the default resolution order:
/// `QR_RUST_DYLIB` env var → debug build → release build. Under plain
/// `dart test` from `core/`, the debug path is the spike-proven default.
Future<void> ensureRustLib({String? dylibPath}) {
  final existing = _rustLibInit;
  if (existing != null) {
    return existing;
  }
  final future = _initRustLib(dylibPath);
  _rustLibInit = future;
  return future;
}

Future<void> _initRustLib(String? dylibPath) async {
  try {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(dylibPath ?? resolveDylibPath()),
    );
  } catch (_) {
    _rustLibInit = null;
    rethrow;
  }
}

/// Resolves the dylib path in order: `QR_RUST_DYLIB` env var, then the debug
/// build if present, then the release build, then the debug path (letting the
/// load fail with a clear error).
///
/// The CWD is NOT a reliable base — `flutter run -d linux` sets it to the app
/// dir, but launching the bundle directly (or from another directory) does
/// not. So the repo-relative paths are resolved against the EXECUTABLE's
/// location first (walking up to the checkout), then against the CWD, then
/// the bundled-next-to-the-executable location (a standalone release copy).
///
/// On Android the codec ships inside the APK as `lib/<abi>/libqr_transfer_rust.so`
/// (see `scripts/build-android-so.sh`); dlopen finds it by bare name, so the
/// host-path checks are skipped entirely.
String resolveDylibPath() => resolveDylibPathFor(Platform.isAndroid);

/// Platform-injectable core of [resolveDylibPath], factored out so the
/// Android branch is unit-testable without touching [Platform] (which cannot
/// be mocked on this SDK).
@visibleForTesting
String resolveDylibPathFor(bool isAndroid, {bool? isWindows}) {
  final windows = isWindows ?? Platform.isWindows;
  if (isAndroid) {
    return 'libqr_transfer_rust.so';
  }
  final fromEnv = Platform.environment['QR_RUST_DYLIB'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }
  for (final candidate in dylibCandidates(isWindows: windows)) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return windows ? _defaultWindowsDebugDylibPath : _defaultDebugDylibPath;
}

/// Ordered dylib locations: bundled next to the executable, then the repo
/// checkout relative to the executable (bundle at
/// `flutter_app/build/linux/<arch>/<mode>/bundle`), then CWD-relative
/// (`flutter run` from `flutter_app/`). On Windows the codec ships as
/// `qr_transfer_rust.dll` (no `lib` prefix, no `.so`), so the candidates use
/// the platform's extension and are probed for existence in order.
@visibleForTesting
Iterable<String> dylibCandidates({required bool isWindows}) sync* {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  yield isWindows
      ? '$exeDir${Platform.pathSeparator}qr_transfer_rust.dll'
      : '$exeDir${Platform.pathSeparator}lib${Platform.pathSeparator}libqr_transfer_rust.so';
  final repo = _walkUpToCheckout(exeDir);
  if (repo != null) {
    yield isWindows
        ? '$repo${Platform.pathSeparator}rust${Platform.pathSeparator}target${Platform.pathSeparator}debug${Platform.pathSeparator}qr_transfer_rust.dll'
        : '$repo${Platform.pathSeparator}rust${Platform.pathSeparator}target${Platform.pathSeparator}debug${Platform.pathSeparator}libqr_transfer_rust.so';
    yield isWindows
        ? '$repo${Platform.pathSeparator}rust${Platform.pathSeparator}target${Platform.pathSeparator}release${Platform.pathSeparator}qr_transfer_rust.dll'
        : '$repo${Platform.pathSeparator}rust${Platform.pathSeparator}target${Platform.pathSeparator}release${Platform.pathSeparator}libqr_transfer_rust.so';
  }
  yield isWindows ? _defaultWindowsDebugDylibPath : _defaultDebugDylibPath;
  yield isWindows ? _defaultWindowsReleaseDylibPath : _defaultReleaseDylibPath;
}

/// Walks up from [dir] (max 10 levels) looking for a directory containing
/// `rust/Cargo.toml` — the flutter_app checkout. Returns its path or null.
String? _walkUpToCheckout(String dir) {
  var current = dir;
  for (var i = 0; i < 10; i++) {
    if (File('$current/rust/Cargo.toml').existsSync()) {
      return current;
    }
    final parent = Directory(current).parent.path;
    if (parent == current) return null; // filesystem root
    current = parent;
  }
  return null;
}

/// Reads the ESI (encoding symbol id) from a wire-serialized RaptorQ packet:
/// bytes 1..=3 are the 24-bit big-endian ESI. The header byte (SBN) must be 0
/// for the single-source-block transfers this facade produces.
int readEsiFromPacket(Uint8List packet) {
  assert(packet.length >= 4, 'packet shorter than the 4-byte RaptorQ header');
  assert(packet[0] == 0, 'source block number must be 0 (single source block)');
  return (packet[1] << 16) | (packet[2] << 8) | packet[3];
}

List<EncodedSymbol> _toSymbols(List<Uint8List> packets) => [
  for (final packet in packets)
    EncodedSymbol(bytes: packet, esi: readEsiFromPacket(packet)),
];

/// Native RaptorQ encoder ([FountainEncoder]) backed by a generated
/// `RaptorqEncoder` opaque handle. The handle is released when the wrapper is
/// garbage-collected (FRB arc management); [dispose] is a no-op.
class RustRaptorqEncoder implements FountainEncoder {
  RustRaptorqEncoder(this._inner);

  final RaptorqEncoder _inner;

  @override
  List<EncodedSymbol> encodeSourceSymbols() =>
      _toSymbols(_inner.encodeSourcePackets());

  @override
  List<EncodedSymbol> encodeRepair(int count) =>
      _toSymbols(_inner.encodeRepairPackets(count: BigInt.from(count)));

  @override
  int get symbolSize => _inner.symbolSize().toInt();

  @override
  int get sourceSymbolCount => _inner.sourceSymbolCount().toInt();

  @override
  void dispose() {
    // The generated opaque handle is arc-managed: dropping this wrapper drops
    // the Rust `RaptorqEncoder`. No explicit free() is exposed.
  }
}

/// Native one-shot RaptorQ decoder ([FountainDecoder]) backed by a generated
/// `RaptorqDecoder` opaque handle. After completion, [decode] keeps returning
/// the recovered file (the interface contract); the Rust decoder itself is
/// one-shot.
class RustRaptorqDecoder implements FountainDecoder {
  RustRaptorqDecoder(this._inner);

  final RaptorqDecoder _inner;
  Uint8List? _result;

  @override
  Uint8List? decode(Uint8List symbolBytes) {
    if (_result != null) {
      return _result;
    }
    _result = _inner.decode(packet: symbolBytes);
    return _result;
  }

  @override
  bool get isComplete => _result != null;

  @override
  void dispose() {
    // Arc-managed handle; see RustRaptorqEncoder.dispose().
  }
}

/// [FountainFactory] building native RaptorQ encoders/decoders. Construction
/// latches the lazy Rust library init; the factory functions are async because
/// init is, mirroring the PWA's wasm-init-awaiting factory.
class RustRaptorqFactory implements FountainFactory {
  @override
  Future<FountainEncoder> createEncoder(Uint8List data, int mtu) async {
    assertMtuValid(mtu);
    await ensureRustLib();
    return RustRaptorqEncoder(
      RaptorqEncoder.withDefaults(data: data, mtu: mtu),
    );
  }

  @override
  Future<FountainDecoder> createDecoder(int totalLength, int mtu) async {
    assertMtuValid(mtu);
    await ensureRustLib();
    return RustRaptorqDecoder(
      RaptorqDecoder(totalLength: BigInt.from(totalLength), mtu: mtu),
    );
  }
}
