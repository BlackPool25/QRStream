import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/sender/settings.dart';
import 'package:test/test.dart';

/// Drives the frame loop of [detectRefreshRateCore] exactly [frames] times,
/// spaced evenly across [windowMs], recording every canceled token. When
/// [advance] is false the clock never moves, probing the elapsed<=0 guard.
class _FakeScheduler {
  _FakeScheduler({required this.frames, required this.windowMs})
    : advance = true;

  _FakeScheduler.stalled() : frames = 1, windowMs = 400, advance = false;

  final int frames;
  final int windowMs;
  final bool advance;

  final List<int> canceled = <int>[];
  int _now = 0;
  int _nextToken = 1;
  void Function()? _pending;

  /// Token of the most recently scheduled frame.
  int? lastToken;

  int now() => _now;

  int schedule(void Function() onFrame) {
    _pending = onFrame;
    lastToken = _nextToken;
    return _nextToken++;
  }

  void cancel(int token) => canceled.add(token);

  void drive() {
    for (var i = 0; i < frames; i++) {
      if (advance) _now = ((i + 1) * windowMs) ~/ frames;
      _pending?.call();
    }
  }
}

/// Starts the probe, drives exactly `scheduler.frames` frames, then awaits the
/// classified rate (the probe only resolves once the window closes).
Future<int> _probe(_FakeScheduler scheduler) {
  final future = detectRefreshRateCore(
    scheduleFrame: scheduler.schedule,
    cancelFrame: scheduler.cancel,
    now: scheduler.now,
  );
  scheduler.drive();
  return future;
}

Matcher _throwsArgumentErrorWith(String field) => throwsA(
  isA<ArgumentError>().having(
    (e) => e.message.toString(),
    'message',
    contains(field),
  ),
);

void main() {
  group('defaultTransferSettings', () {
    test('matches the PWA defaults exactly', () {
      const expected = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 15,
        highRefresh: false,
      );
      expect(defaultTransferSettings, expected);
    });
  });

  group('validateSettings', () {
    // An out-of-range bytesPerTile/layout or a non-boolean highRefresh is
    // unrepresentable in sound Dart: the TransferSettings constructor
    // runtime-checks every typed parameter (a foreign value fails with a
    // TypeError at construction, not at validation), and `Enum` cannot be
    // implemented by user code. Those reject branches defend the future
    // untyped JSON boundary (port parity with the PWA) and are pinned here by
    // proving acceptance is total over the real domain; the reachable
    // violation class (targetFps) is exercised with a real construction.
    test('accepts the default settings', () {
      expect(() => validateSettings(defaultTransferSettings), returnsNormally);
    });

    test('accepts every allowed targetFps', () {
      for (final fps in <int>[12, 15, 24, 30]) {
        final s = TransferSettings(
          bytesPerTile: BytesPerTileId.oneK,
          layout: LayoutId.grid4,
          targetFps: fps,
          highRefresh: false,
        );
        expect(() => validateSettings(s), returnsNormally, reason: 'fps $fps');
      }
    });

    test('accepts every enum/flag combination (validation is total)', () {
      for (final tile in BytesPerTileId.values) {
        for (final layout in LayoutId.values) {
          for (final fps in <int>[12, 15, 24, 30]) {
            for (final highRefresh in <bool>[false, true]) {
              final s = TransferSettings(
                bytesPerTile: tile,
                layout: layout,
                targetFps: fps,
                highRefresh: highRefresh,
              );
              expect(
                () => validateSettings(s),
                returnsNormally,
                reason: '$tile / $layout / $fps / $highRefresh',
              );
            }
          }
        }
      }
    });

    test('rejects a targetFps outside {12, 15, 24, 30}', () {
      final bad = TransferSettings(
        bytesPerTile: BytesPerTileId.oneK,
        layout: LayoutId.grid4,
        targetFps: 20,
        highRefresh: false,
      );
      expect(
        () => validateSettings(bad),
        _throwsArgumentErrorWith('targetFps'),
      );
    });
  });

  group('classifyRefreshRate', () {
    test('classifies 120 at a rate of >= 105 fps', () {
      expect(classifyRefreshRate(frames: 48, elapsedMs: 400), 120);
      // 42 * 1000 / 400 = 105.0 exactly.
      expect(classifyRefreshRate(frames: 42, elapsedMs: 400), 120);
    });

    test('classifies 90 at a rate of >= 75 fps', () {
      expect(classifyRefreshRate(frames: 36, elapsedMs: 400), 90);
      // 41 * 1000 / 400 = 102.5 < 105; 30 * 1000 / 400 = 75.0 exactly.
      expect(classifyRefreshRate(frames: 41, elapsedMs: 400), 90);
      expect(classifyRefreshRate(frames: 30, elapsedMs: 400), 90);
    });

    test('classifies 60 below 75 fps', () {
      expect(classifyRefreshRate(frames: 24, elapsedMs: 400), 60);
      // 29 * 1000 / 400 = 72.5 < 75.
      expect(classifyRefreshRate(frames: 29, elapsedMs: 400), 60);
    });

    test('resolves 60 when elapsed is zero', () {
      expect(classifyRefreshRate(frames: 48, elapsedMs: 0), 60);
    });
  });

  group('detectRefreshRateCore', () {
    test(
      'classifies 120 from 48 frames in 400 ms and cancels the trailing frame',
      () async {
        final scheduler = _FakeScheduler(frames: 48, windowMs: 400);
        final rate = await _probe(scheduler);
        expect(rate, 120);
        expect(scheduler.canceled, <int>[scheduler.lastToken!]);
      },
    );

    test(
      'classifies 90 from 36 frames in 400 ms and cancels the trailing frame',
      () async {
        final scheduler = _FakeScheduler(frames: 36, windowMs: 400);
        final rate = await _probe(scheduler);
        expect(rate, 90);
        expect(scheduler.canceled, <int>[scheduler.lastToken!]);
      },
    );

    test(
      'classifies 60 from 24 frames in 400 ms and cancels the trailing frame',
      () async {
        final scheduler = _FakeScheduler(frames: 24, windowMs: 400);
        final rate = await _probe(scheduler);
        expect(rate, 60);
        expect(scheduler.canceled, <int>[scheduler.lastToken!]);
      },
    );

    test(
      'resolves 60 and cancels the trailing frame when the clock never advances',
      () async {
        final scheduler = _FakeScheduler.stalled();
        final rate = await _probe(scheduler);
        expect(rate, 60);
        expect(scheduler.canceled, <int>[scheduler.lastToken!]);
      },
    );
  });

  group('transferLabel', () {
    TransferSettings settings(BytesPerTileId tile, LayoutId layout) =>
        TransferSettings(
          bytesPerTile: tile,
          layout: layout,
          targetFps: 15,
          highRefresh: false,
        );

    test('formats V{version} · {rows}×{cols} from the profile tables', () {
      expect(
        transferLabel(settings(BytesPerTileId.oneK, LayoutId.grid4)),
        'V27 · 2×2',
      );
      // Layouts read as rows×cols: the 1-column column3 is "3×1", the
      // 1-row row3 is "1×3".
      expect(
        transferLabel(settings(BytesPerTileId.twoK, LayoutId.column3)),
        'V34 · 3×1',
      );
      expect(
        transferLabel(settings(BytesPerTileId.twoAndHalfK, LayoutId.row3)),
        'V40 · 1×3',
      );
      expect(
        transferLabel(settings(BytesPerTileId.oneK, LayoutId.single)),
        'V27 · 1×1',
      );
    });
  });
}
