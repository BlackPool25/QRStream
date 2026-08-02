import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/protocol/metadata.dart';
import 'package:qr_transfer_core/receiver/stats.dart';
import 'package:test/test.dart';

/// Metadata payload content is irrelevant to the stats module; a fixed,
/// well-formed instance proves start() receives the buffer's metadata.
const _meta = TransferMetadata(
  magic: metaMagic,
  protoVer: protoVersion,
  sessionId: '0011223344556677',
  filename: 'test.bin',
  mime: 'application/octet-stream',
  totalSize: 1024,
  compressedSize: 0,
  compressed: false,
  k: 3,
  symbolSize: 1024,
  mtu: 1028,
  fileSHA256:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  flags: 0,
);

/// A sample builder with all-zero defaults so each test states only the
/// fields it cares about.
StatsSample sample({
  int unique = 0,
  int? k,
  int totalFramesSeen = 0,
  int droppedCount = 0,
  int elapsedMs = 0,
  int? symbolSize,
  int decodedInWindow = 0,
  int windowMs = 0,
}) => StatsSample((
  unique,
  k,
  totalFramesSeen,
  droppedCount,
  elapsedMs,
  symbolSize,
  decodedInWindow,
  windowMs,
));

/// Fake buffer honoring the FrameBuffer contract: symbols() is esi-sorted.
class FakeBuffer implements FrameBuffer {
  FakeBuffer({this.metadata, List<Uint8List>? symbols, Set<int>? esis})
    : _symbols = symbols ?? const [],
      _esis = esis ?? const {};

  @override
  final TransferMetadata? metadata;

  final List<Uint8List> _symbols;
  final Set<int> _esis;

  @override
  List<Uint8List> symbols() => _symbols;

  @override
  Set<int> symbolEsiSet() => Set<int>.of(_esis);
}

/// Fake reassembler recording every call the feed handler drives.
class FakeReassembler implements ReassemblerLike {
  int resetCalls = 0;
  TransferMetadata? startMetadata;
  final List<List<Uint8List>> starts = [];
  final List<List<Uint8List>> feeds = [];

  @override
  Future<void> start(
    TransferMetadata metadata,
    List<Uint8List> symbols,
    Set<int> esiSet,
  ) async {
    startMetadata = metadata;
    starts.add(symbols);
  }

  @override
  void feedMore(List<Uint8List> symbols, Set<int> esiSet) {
    feeds.add(symbols);
  }

  @override
  bool get isComplete => false;

  @override
  Future<void> finish() async {}

  @override
  void reset() {
    resetCalls++;
  }
}

void main() {
  group('downsampleTarget', () {
    test('1920x1080 scales to at most 2MP and exactly 1280 wide', () {
      final target = downsampleTarget(1920, 1080);
      expect(target, (width: 1280, height: 720));
      expect(target.width * target.height, lessThanOrEqualTo(2000000));
    });

    test('1280x720 is already within budget and stays unchanged', () {
      expect(downsampleTarget(1280, 720), (width: 1280, height: 720));
    });

    test('4000x3000 downscales within 2MP preserving the aspect ratio', () {
      final target = downsampleTarget(4000, 3000);
      expect(target.width, 1280);
      expect(target.height, 960);
      expect(target.width * target.height, lessThanOrEqualTo(2000000));
      expect(target.width / target.height, closeTo(4 / 3, 1e-9));
    });

    test('zero and negative inputs fall back to 1x1', () {
      expect(downsampleTarget(0, 100), (width: 1, height: 1));
      expect(downsampleTarget(100, 0), (width: 1, height: 1));
      expect(downsampleTarget(-5, 10), (width: 1, height: 1));
    });
  });

  group('updateStats EMA decode rate', () {
    test('100ms window: prev 0, inst 100 -> 0 * 0.9 + 100 * 0.1 = 10', () {
      final stats = updateStats(
        ReceiverStats.empty(),
        sample(decodedInWindow: 10, windowMs: 100),
      );
      expect(stats.decodeRate, 10.0);
    });

    test('next window: prev 10, inst 100 -> 10 * 0.9 + 100 * 0.1 = 19', () {
      final prev = updateStats(
        ReceiverStats.empty(),
        sample(decodedInWindow: 10, windowMs: 100),
      );
      final stats = updateStats(
        prev,
        sample(decodedInWindow: 10, windowMs: 100),
      );
      expect(stats.decodeRate, 19.0);
    });

    test('windowMs 0 keeps the previous rate', () {
      final prev = updateStats(
        ReceiverStats.empty(),
        sample(decodedInWindow: 10, windowMs: 100),
      );
      final stats = updateStats(
        prev,
        sample(decodedInWindow: 999, windowMs: 0),
      );
      expect(stats.decodeRate, 10.0);
    });

    test('windowMs >= 1000 blends with alpha 1 -> the instantaneous rate', () {
      final stats = updateStats(
        ReceiverStats.empty(),
        sample(decodedInWindow: 200, windowMs: 2000),
      );
      expect(stats.decodeRate, 100.0);
    });
  });

  group('updateStats bytesPerSecond and eta', () {
    test(
      'bps = new unique symbols in window * symbolSize / windowSeconds',
      () {
        final stats = updateStats(
          ReceiverStats.empty(),
          sample(
            unique: 40,
            k: 100,
            symbolSize: 1024,
            windowMs: 2000,
          ),
        );
        // 40 new symbols in a 2s window -> 40 * 1024 / 2 = 20480 B/s.
        expect(stats.bytesPerSecond, closeTo(20480.0, 1e-9));
        expect(stats.etaSeconds, closeTo(3.0, 1e-9)); // 60 * 1024 / 20480
        expect(stats.progress, 0.4);
      },
    );

    test('no window -> bps 0 -> eta unknown', () {
      final stats = updateStats(
        ReceiverStats.empty(),
        sample(unique: 40, k: 100, symbolSize: 1024, elapsedMs: 0),
      );
      expect(stats.bytesPerSecond, 0.0);
      expect(stats.etaSeconds, isNull);
    });

    test('k unknown -> eta unknown even with a positive bps', () {
      final stats = updateStats(
        ReceiverStats.empty(),
        sample(
          unique: 40,
          k: null,
          symbolSize: 1024,
          windowMs: 2000,
        ),
      );
      expect(stats.bytesPerSecond, closeTo(20480.0, 1e-9));
      expect(stats.etaSeconds, isNull);
    });

    test('metaSeen reflects a known symbolSize', () {
      final seen = updateStats(
        ReceiverStats.empty(),
        sample(unique: 40, symbolSize: 1024, elapsedMs: 2000),
      );
      expect(seen.metaSeen, isTrue);
      final unseen = updateStats(
        ReceiverStats.empty(),
        sample(symbolSize: null),
      );
      expect(unseen.metaSeen, isFalse);
    });

    test('result equals a hand-built ReceiverStats (==)', () {
      final stats = updateStats(
        ReceiverStats.empty(),
        sample(
          unique: 40,
          k: 100,
          symbolSize: 1024,
          elapsedMs: 2000,
          decodedInWindow: 10,
          windowMs: 100,
        ),
      );
      // Windowed bps: 40 new symbols × 1024 B in 0.1s = 409600 instant,
      // EMA-blended from 0 with alpha 0.1 → 40960.
      expect(
        stats,
        ReceiverStats((
          ReceiverStatus.idle,
          40,
          100,
          0,
          0,
          10.0,
          40960.0,
          1.5,
          0.4,
          true,
          null,
          null,
        )),
      );
    });
  });

  group('progressOf', () {
    test('k unknown -> 0', () {
      expect(progressOf(50, null), 0.0);
      expect(progressOf(50, 0), 0.0);
    });

    test('unique / k when k is known', () {
      expect(progressOf(50, 100), 0.5);
    });

    test('clamped to 1.0 past k', () {
      expect(progressOf(200, 100), 1.0);
    });
  });

  group('handleFeedResult', () {
    final s0 = Uint8List.fromList([0]);
    final s1 = Uint8List.fromList([1]);
    final s2 = Uint8List.fromList([2]);

    test('new session resets the reassembler and the feed state', () async {
      final re = FakeReassembler();
      final state = FeedState(started: true, fedEsi: {0, 1});
      final result = await handleFeedResult(
        buffer: FakeBuffer(metadata: _meta, symbols: [s0, s1], esis: {0, 1}),
        reassembler: re,
        result: const FeedResult(status: FeedStatus.ok, isNewSession: true),
        state: state,
      );
      expect(re.resetCalls, 1);
      expect(result.action, FeedAction.start); // state was reset -> first start
      expect(result.state.started, isTrue);
      expect(result.state.fedEsi, {0, 1});
    });

    test(
      'new session with a corrupt feed still resets (action reset)',
      () async {
        final re = FakeReassembler();
        final state = FeedState(started: true, fedEsi: {0});
        final result = await handleFeedResult(
          buffer: FakeBuffer(metadata: _meta, symbols: [s0], esis: {0}),
          reassembler: re,
          result: const FeedResult(
            status: FeedStatus.error,
            isNewSession: true,
          ),
          state: state,
        );
        expect(re.resetCalls, 1);
        expect(result.action, FeedAction.reset);
        expect(result.state.started, isFalse);
        expect(result.state.fedEsi, isEmpty);
      },
    );

    test(
      'first metadata + symbols -> start once with the buffer metadata',
      () async {
        final re = FakeReassembler();
        final result = await handleFeedResult(
          buffer: FakeBuffer(metadata: _meta, symbols: [s0, s1], esis: {0, 1}),
          reassembler: re,
          result: const FeedResult(status: FeedStatus.ok),
          state: FeedState(started: false, fedEsi: <int>{}),
        );
        expect(result.action, FeedAction.start);
        expect(result.state.started, isTrue);
        expect(result.state.fedEsi, {0, 1});
        expect(re.startMetadata, same(_meta));
        expect(re.starts.single, [s0, s1]);
        expect(re.feeds, isEmpty);
      },
    );

    test('later symbols -> feedMore only, deduped by fedEsi', () async {
      final re = FakeReassembler();
      final result = await handleFeedResult(
        buffer: FakeBuffer(
          metadata: _meta,
          symbols: [s0, s1, s2],
          esis: {0, 1, 2},
        ),
        reassembler: re,
        result: const FeedResult(status: FeedStatus.ok),
        state: FeedState(started: true, fedEsi: {0, 1}),
      );
      expect(result.action, FeedAction.feedMore);
      expect(result.state.fedEsi, {0, 1, 2});
      expect(re.starts, isEmpty);
      expect(re.feeds.single, [s2]);
    });

    test(
      'out-of-order late low esi is fed (fedEsi tracking, not slice index)',
      () async {
        final re = FakeReassembler();
        // The buffer holds esis 0..2 sorted; only 1 and 2 were fed before, so
        // the 0th (lowest-esi) symbol must be the only one handed over now.
        final result = await handleFeedResult(
          buffer: FakeBuffer(
            metadata: _meta,
            symbols: [s0, s1, s2],
            esis: {0, 1, 2},
          ),
          reassembler: re,
          result: const FeedResult(status: FeedStatus.ok),
          state: FeedState(started: true, fedEsi: {1, 2}),
        );
        expect(result.action, FeedAction.feedMore);
        expect(re.feeds.single, [s0]);
        expect(result.state.fedEsi, {0, 1, 2});
      },
    );

    test('corrupt feed result is a no-op', () async {
      final re = FakeReassembler();
      final state = FeedState(started: true, fedEsi: {0});
      final result = await handleFeedResult(
        buffer: FakeBuffer(metadata: _meta, symbols: [s0], esis: {0}),
        reassembler: re,
        result: const FeedResult(status: FeedStatus.error),
        state: state,
      );
      expect(result.action, FeedAction.none);
      expect(result.state, same(state));
      expect(re.resetCalls, 0);
      expect(re.starts, isEmpty);
      expect(re.feeds, isEmpty);
    });

    test('metadata unknown is a no-op even when the feed is ok', () async {
      final re = FakeReassembler();
      final state = FeedState(started: false, fedEsi: <int>{});
      final result = await handleFeedResult(
        buffer: FakeBuffer(symbols: [s0], esis: {0}),
        reassembler: re,
        result: const FeedResult(status: FeedStatus.ok),
        state: state,
      );
      expect(result.action, FeedAction.none);
      expect(result.state, same(state));
      expect(re.starts, isEmpty);
    });

    test('META-only feed does not start until symbols exist', () async {
      final re = FakeReassembler();
      final result = await handleFeedResult(
        buffer: FakeBuffer(metadata: _meta),
        reassembler: re,
        result: const FeedResult(status: FeedStatus.ok),
        state: FeedState(started: false, fedEsi: <int>{}),
      );
      expect(result.action, FeedAction.none);
      expect(result.state.started, isFalse);
      expect(result.state.fedEsi, isEmpty);
      expect(re.starts, isEmpty);
    });

    test('nothing new to feed is a no-op', () async {
      final re = FakeReassembler();
      final state = FeedState(started: true, fedEsi: {0});
      final result = await handleFeedResult(
        buffer: FakeBuffer(metadata: _meta, symbols: [s0], esis: {0}),
        reassembler: re,
        result: const FeedResult(status: FeedStatus.ok),
        state: state,
      );
      expect(result.action, FeedAction.none);
      expect(result.state, same(state));
      expect(re.feeds, isEmpty);
    });
  });
}
