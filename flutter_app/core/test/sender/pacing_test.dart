import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/sender/pacing.dart';
import 'package:test/test.dart';

void main() {
  group('computeFrameDelayMs', () {
    test('rounds 1000/fps to the nearest millisecond', () {
      expect(computeFrameDelayMs(24), 42);
      expect(computeFrameDelayMs(12), 83);
      expect(computeFrameDelayMs(60), 17);
    });
  });

  group('suggestLayout', () {
    test('extreme portrait and landscape win over size', () {
      expect(suggestLayout(790, 1000), LayoutId.column3); // aspect 0.79 < 0.8
      expect(suggestLayout(1260, 1000), LayoutId.row3); // aspect 1.26 > 1.25
    });

    test('square-ish canvases pick by min side', () {
      expect(
        suggestLayout(2000, 2000),
        LayoutId.grid9,
      ); // min side 2000 >= 1800
      expect(
        suggestLayout(1600, 1600),
        LayoutId.grid4,
      ); // 1800 > min side >= 800
      expect(suggestLayout(600, 600), LayoutId.single);
    });

    test('grid4 boundary at aspect 0.8 and 1.25', () {
      expect(suggestLayout(800, 1000), LayoutId.grid4); // aspect exactly 0.8
      expect(suggestLayout(1250, 1000), LayoutId.grid4); // aspect exactly 1.25
    });

    test('small portrait maps to column2 below the column2 threshold', () {
      expect(
        suggestLayout(400, 800),
        LayoutId.column2,
      ); // aspect 0.5, minSide 400
      expect(suggestLayout(479, 958), LayoutId.column2); // minSide 479 < 480
      expect(suggestLayout(480, 960), LayoutId.column3); // boundary: column3
    });

    test('small landscape maps to row2 below the row2 threshold', () {
      expect(suggestLayout(800, 400), LayoutId.row2); // aspect 2.0, minSide 400
      expect(suggestLayout(958, 479), LayoutId.row2); // minSide 479 < 480
      expect(suggestLayout(960, 480), LayoutId.row3); // boundary: row3
    });
  });

  group('resolvePacing', () {
    test('grid4 at 15 fps on a 1600px canvas', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 15,
        highRefresh: false,
      );
      final pacing = resolvePacing(settings, 1600, 1600);
      expect(pacing.tilesPerFrame, 4);
      expect(pacing.fpsCeiling, 24);
      expect(pacing.effectiveFps, 15);
      expect(pacing.suggestedLayout, LayoutId.grid4);
    });

    test('fps ceiling is the refresh-rate cap on a 60 Hz path', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 30,
        highRefresh: false,
      );
      final pacing = resolvePacing(settings, 1600, 1600);
      expect(pacing.tilesPerFrame, 4);
      expect(pacing.fpsCeiling, 24);
      expect(pacing.effectiveFps, 24);
    });

    test('high refresh unlocks 30 fps', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 30,
        highRefresh: true,
      );
      final pacing = resolvePacing(settings, 1600, 1600);
      expect(pacing.fpsCeiling, 30);
      expect(pacing.effectiveFps, 30);
    });

    test('grid9 caps at 24 even on high refresh', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid9,
        targetFps: 30,
        highRefresh: true,
      );
      final pacing = resolvePacing(settings, 2000, 2000);
      expect(pacing.tilesPerFrame, 9);
      expect(pacing.fpsCeiling, 24);
      expect(pacing.effectiveFps, 24);
    });

    test('single tile at 12 fps is unclamped', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.single,
        targetFps: 12,
        highRefresh: false,
      );
      final pacing = resolvePacing(settings, 600, 600);
      expect(pacing.tilesPerFrame, 1);
      expect(pacing.fpsCeiling, 24);
      expect(pacing.effectiveFps, 12);
      expect(pacing.suggestedLayout, LayoutId.single);
    });
  });

  group('estimateThroughput', () {
    test('1k grid4 at 15 fps: 15 * (4 - 1/32) * 1024 = 60960', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 15,
        highRefresh: false,
      );
      expect(estimateThroughput(settings), closeTo(60960, 1e-9));
    });

    test('2k grid4 at 24 fps: 24 * (4 - 1/32) * 2048 = 195072', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.twoK,
        layout: LayoutId.grid4,
        targetFps: 24,
        highRefresh: false,
      );
      expect(estimateThroughput(settings), closeTo(195072, 1e-9));
    });

    test(
      '2.5k row3 at 30 fps high refresh: 30 * (3 - 1/32) * 2560 = 228000',
      () {
        const settings = TransferSettings(
          bytesPerTile: BytesPerTileId.twoAndHalfK,
          layout: LayoutId.row3,
          targetFps: 30,
          highRefresh: true,
        );
        expect(estimateThroughput(settings), closeTo(228000, 1e-9));
      },
    );

    test('estimateEtaSeconds divides compressed size by throughput', () {
      const settings = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 15,
        highRefresh: false,
      );
      expect(estimateEtaSeconds(settings, 1048576), closeTo(17.2, 0.01));
    });
  });

  group('renderBudgetOk', () {
    test('fits budget with default 1.5x overhead margin', () {
      expect(renderBudgetOk(20, 42), isTrue);
      expect(renderBudgetOk(30, 42), isFalse);
    });
  });

  group('adaptFps', () {
    test('keeps fps while inside the budget', () {
      expect(adaptFps(24, 10, 42), 24);
    });

    test('steps down by 4 when over budget', () {
      expect(adaptFps(24, 30, 42), 20);
    });

    test('floors at minFps 8', () {
      expect(adaptFps(10, 30, 42), 8);
    });
  });

  group('nextEsiRoundRobin', () {
    const k = 10;
    const repairAvailable = 5;
    const tilesPerFrame = 4;

    List<int> frame(int frameIndex) =>
        nextEsiRoundRobin(k, repairAvailable, frameIndex, tilesPerFrame);

    test('walks forward from frameIndex * tilesPerFrame mod pool', () {
      expect(frame(0), [0, 1, 2, 3]);
      expect(frame(1), [4, 5, 6, 7]);
      expect(frame(4), [1, 2, 3, 4]); // start 16 % 15
    });

    test('esis are distinct within every frame', () {
      for (var frameIndex = 0; frameIndex < 30; frameIndex++) {
        final esis = frame(frameIndex);
        expect(
          esis.toSet(),
          hasLength(esis.length),
          reason: 'frame $frameIndex must not repeat esis',
        );
      }
    });

    test('esis never exceed the pool upper bound', () {
      for (var frameIndex = 0; frameIndex < 30; frameIndex++) {
        for (final esi in frame(frameIndex)) {
          expect(esi, inInclusiveRange(0, k + repairAvailable - 1));
        }
      }
    });

    test('empty pool yields no esis', () {
      expect(nextEsiRoundRobin(0, 0, 0, tilesPerFrame), isEmpty);
    });
  });

  group('dual-lane schedule', () {
    const k = 50;
    const repairAvailable = 100;
    final poolSize = k + repairAvailable; // 150

    List<int> at(int tick) => nextEsiDualLane(k, repairAvailable, tick);

    test('isDualLaneLayout identifies only the two 2-tile layouts', () {
      expect(isDualLaneLayout(LayoutId.row2), isTrue);
      expect(isDualLaneLayout(LayoutId.column2), isTrue);
      expect(isDualLaneLayout(LayoutId.single), isFalse);
      expect(isDualLaneLayout(LayoutId.column3), isFalse);
      expect(isDualLaneLayout(LayoutId.row3), isFalse);
      expect(isDualLaneLayout(LayoutId.grid4), isFalse);
      expect(isDualLaneLayout(LayoutId.grid9), isFalse);
    });

    test('layoutMaxFps caps row2 and column2 at 30', () {
      expect(layoutMaxFps[LayoutId.row2], 30);
      expect(layoutMaxFps[LayoutId.column2], 30);
    });

    test('pins the first six ticks exactly', () {
      final half = poolSize ~/ 2;
      expect(at(0), [0, half]);
      expect(at(1), [0, half + 1]);
      expect(at(2), [1, half + 1]);
      expect(at(3), [1, half + 2]);
      expect(at(4), [2, half + 2]);
      expect(at(5), [2, half + 3]);
    });

    test('lane0 holds even→odd and advances on even ticks', () {
      final t0 = at(0);
      final t1 = at(1);
      final t2 = at(2);
      expect(t0[0], t1[0]); // holds 0 -> 1
      expect(t1[0], isNot(t2[0])); // advances on even tick 2
    });

    test('lane1 advances on odd ticks and holds odd→even', () {
      final t0 = at(0);
      final t1 = at(1);
      final t2 = at(2);
      expect(t0[1], isNot(t1[1])); // advances on odd tick 0 -> 1
      expect(t1[1], t2[1]); // holds 1 -> 2
    });

    test('each lane holds its esi exactly 2 ticks', () {
      for (var tick = 0; tick < 2 * poolSize; tick++) {
        final a = at(tick);
        final b = at(tick + 1);
        expect(
          a[0] == b[0],
          tick.isEven,
          reason: 'lane0 must hold on even ticks, got tick $tick',
        );
        expect(
          a[1] == b[1],
          tick.isOdd,
          reason: 'lane1 must hold on odd ticks, got tick $tick',
        );
      }
    });

    test('each lane covers every esi once over a cycle (no repeats)', () {
      for (var lane = 0; lane < 2; lane++) {
        final seen = <int>{};
        for (var tick = 0; tick < 2 * poolSize; tick++) {
          seen.add(at(tick)[lane]);
        }
        expect(
          seen,
          hasLength(poolSize),
          reason: 'lane $lane must visit all $poolSize esis over a cycle',
        );
      }
    });

    test('lanes are cross-distinct on every tick (even pool)', () {
      for (var tick = 0; tick < 2 * poolSize; tick++) {
        final esis = at(tick);
        expect(esis[0], isNot(esis[1]), reason: 'tick $tick');
      }
    });

    test('lanes stay cross-distinct with an odd pool size', () {
      const kOdd = 51;
      const rOdd = 100;
      final pOdd = kOdd + rOdd; // 151 — the P~/2 phase offset still separates
      for (var tick = 0; tick < 2 * pOdd; tick++) {
        final esis = nextEsiDualLane(kOdd, rOdd, tick);
        expect(esis[0], isNot(esis[1]), reason: 'odd pool tick $tick');
      }
    });

    test('reaches repair esis and wraps to 0 over a cycle', () {
      final seen = <int>{};
      for (var tick = 0; tick < 2 * poolSize; tick++) {
        seen.addAll(at(tick));
      }
      expect(seen.any((esi) => esi >= k), isTrue);
      // lane0 wraps back to 0 after exactly poolSize holds; lane1 returns to
      // its tick-0 value one full cycle later.
      expect(at(2 * poolSize)[0], 0);
      expect(at(2 * poolSize)[1], at(0)[1]);
    });

    test('is deterministic: same inputs always give the same esis', () {
      for (var tick = 0; tick < 20; tick++) {
        expect(at(tick), at(tick));
      }
    });

    test('empty pool yields no esis', () {
      expect(nextEsiDualLane(0, 0, 0), isEmpty);
    });
  });

  group('symbolsPerTickFor', () {
    test('dual-lane is 1 - 1/32; other layouts are tilesPerFrame - 1/32', () {
      final dataPerTick = 1 - 1 / 32;
      expect(symbolsPerTickFor(LayoutId.row2), closeTo(dataPerTick, 1e-9));
      expect(symbolsPerTickFor(LayoutId.column2), closeTo(dataPerTick, 1e-9));
      expect(symbolsPerTickFor(LayoutId.single), closeTo(dataPerTick, 1e-9));
      expect(symbolsPerTickFor(LayoutId.column3), closeTo(3 - 1 / 32, 1e-9));
      expect(symbolsPerTickFor(LayoutId.row3), closeTo(3 - 1 / 32, 1e-9));
      expect(symbolsPerTickFor(LayoutId.grid4), closeTo(4 - 1 / 32, 1e-9));
      expect(symbolsPerTickFor(LayoutId.grid9), closeTo(9 - 1 / 32, 1e-9));
    });
  });

  group('estimateThroughput dual-lane', () {
    test('row2 == single == column2 for equal fps and bytes', () {
      TransferSettings s(LayoutId layout) => TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: layout,
        targetFps: 15,
        highRefresh: false,
      );
      final single = estimateThroughput(s(LayoutId.single));
      final row2 = estimateThroughput(s(LayoutId.row2));
      final column2 = estimateThroughput(s(LayoutId.column2));
      expect(row2, single);
      expect(column2, single);
      // 2 tiles at half rate = 1 symbol/tick = same as a single tile.
      expect(row2, closeTo(15 * (1 - 1 / 32) * 1024, 1e-9));
    });
  });

  group('FramePool', () {
    late List<Uint8List> dataFrames;
    var repairBatchesGenerated = 0;

    List<Uint8List> repairBatch(int count) {
      repairBatchesGenerated++;
      return List.generate(
        count,
        (i) => Uint8List.fromList([0xAA, i & 0xff]),
        growable: false,
      );
    }

    FramePool pool({int k = 10}) {
      dataFrames = List.generate(
        k,
        (i) => Uint8List.fromList([0x11, i]),
        growable: false,
      );
      return FramePool(
        k: k,
        dataFrames: () => dataFrames,
        repairFrames: repairBatch,
      );
    }

    setUp(() {
      repairBatchesGenerated = 0;
    });

    test('repairAvailable is ceil(k * 0.3) + 100', () {
      expect(pool().repairAvailable, 103);
    });

    test('frameBytes below k returns the source frame', () {
      final p = pool();
      for (var esi = 0; esi < 10; esi++) {
        expect(identical(p.frameBytes(esi), dataFrames[esi]), isTrue);
      }
      expect(repairBatchesGenerated, 0);
    });

    test('frameBytes at k and beyond generates one repair batch, cached', () {
      final p = pool();
      final first = p.frameBytes(10);
      expect(first, [0xAA, 0x00]); // repair batch index esi - k = 0
      expect(repairBatchesGenerated, 1);
      final again = p.frameBytes(10);
      expect(
        identical(again, first),
        isTrue,
        reason: 'repair batch must be reused',
      );
      p.frameBytes(112); // last repair esi
      expect(repairBatchesGenerated, 1);
    });

    test('esi out of range throws RangeError', () {
      final p = pool();
      expect(() => p.frameBytes(113), throwsRangeError); // k + repairAvailable
      expect(() => p.frameBytes(-1), throwsRangeError);
    });
  });

  group('SenderStats', () {
    test('carries the six stats fields', () {
      const stats = SenderStats(
        tickCount: 123,
        fps: 24,
        droppedTicks: 2,
        avgTickMs: 41.7,
        layout: LayoutId.grid4,
        k: 10,
      );
      expect(stats.tickCount, 123);
      expect(stats.fps, 24);
      expect(stats.droppedTicks, 2);
      expect(stats.avgTickMs, closeTo(41.7, 1e-9));
      expect(stats.layout, LayoutId.grid4);
      expect(stats.k, 10);
    });
  });

  group('computeLayoutGeometry', () {
    test('grid4 on a 1600 square: 800px cells, 6 px/module at v27', () {
      final g = computeLayoutGeometry(1600, 1600, LayoutId.grid4, 27);
      expect(g.cellW, 800);
      expect(g.cellH, 800);
      expect(g.ppm, 6); // floor(800 / (27*4 + 17 + 8))
    });

    test('column3 portrait: cells split on the tall side', () {
      final g = computeLayoutGeometry(900, 2400, LayoutId.column3, 27);
      expect(g.cellW, 900);
      expect(g.cellH, 800);
      expect(g.ppm, 6);
    });

    test('row3 landscape: cells split on the wide side', () {
      final g = computeLayoutGeometry(2400, 900, LayoutId.row3, 27);
      expect(g.cellW, 800);
      expect(g.cellH, 900);
      expect(g.ppm, 6);
    });
  });
}
