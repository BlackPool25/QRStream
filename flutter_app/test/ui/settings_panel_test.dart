// SettingsPanel widget tests (T5.3): the send-flow settings step renders the
// fps / bytes-per-tile / layout / high-refresh controls with a live speed
// estimate, and fires onChanged for each control.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_transfer_core/protocol/constants.dart' as qrc;

import 'package:qr_data_transfer/ui/settings_panel.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  qrc.TransferSettings base() => const qrc.TransferSettings(
    bytesPerTile: qrc.BytesPerTileId.oneK,
    layout: qrc.LayoutId.grid4,
    targetFps: 15,
    highRefresh: false,
  );

  Future<qrc.TransferSettings? Function()> captureChange(
    WidgetTester tester, {
    qrc.TransferSettings? settings,
    int refreshRate = 60,
  }) async {
    qrc.TransferSettings? changed;
    await tester.pumpWidget(
      wrap(
        SettingsPanel(
          settings: settings ?? base(),
          onChanged: (s) => changed = s,
          compressedSize: 1024 * 1024,
          refreshRate: refreshRate,
          suggestedLayout: qrc.LayoutId.grid4,
          onBegin: () {},
          onDifferentFile: () {},
          fileName: 'test.bin',
          fileSize: 1024 * 1024,
        ),
      ),
    );
    // Return a getter: the tapping tests call it AFTER the tap to read the
    // latest onChanged value (the closure keeps capturing into `changed`).
    return () => changed;
  }

  testWidgets('renders all control groups + file header + estimate', (
    tester,
  ) async {
    await captureChange(tester);

    expect(find.byKey(const Key('fps_group')), findsOneWidget);
    expect(find.byKey(const Key('bytes_group')), findsOneWidget);
    expect(find.byKey(const Key('layout_group')), findsOneWidget);
    expect(find.byKey(const Key('high_refresh_switch')), findsOneWidget);
    expect(find.byKey(const Key('begin_broadcast')), findsOneWidget);
    expect(find.text('test.bin'), findsOneWidget);
    expect(find.textContaining('KB/s'), findsOneWidget);
    // V27 · 2×2 from transferLabel for the default profile+layout.
    expect(find.text('V27 · 2×2'), findsOneWidget);
  });

  testWidgets('30 fps is disabled without high-refresh (60 Hz detected)', (
    tester,
  ) async {
    await captureChange(tester, refreshRate: 60);

    final seg = tester.widget<SegmentedButton<int>>(
      find.byKey(const Key('fps_group')),
    );
    final fps30 = seg.segments.firstWhere((s) => s.value == 30);
    expect(fps30.enabled, isFalse, reason: '30 fps needs a 90 Hz+ display');
    // The switch is disabled on a 60 Hz display.
    final sw = tester.widget<Switch>(
      find.byKey(const Key('high_refresh_switch')),
    );
    expect(sw.onChanged, isNull);
    expect(find.text('Detected 60 Hz display'), findsOneWidget);
  });

  testWidgets('30 fps + high-refresh switch enabled on a 120 Hz display', (
    tester,
  ) async {
    await captureChange(
      tester,
      settings: const qrc.TransferSettings(
        bytesPerTile: qrc.BytesPerTileId.oneK,
        layout: qrc.LayoutId.grid4,
        targetFps: 30,
        highRefresh: true,
      ),
      refreshRate: 120,
    );

    final seg = tester.widget<SegmentedButton<int>>(
      find.byKey(const Key('fps_group')),
    );
    final fps30 = seg.segments.firstWhere((s) => s.value == 30);
    expect(fps30.enabled, isTrue);
    final sw = tester.widget<Switch>(
      find.byKey(const Key('high_refresh_switch')),
    );
    expect(sw.onChanged, isNotNull);
    expect(find.text('Detected 120 Hz display'), findsOneWidget);
  });

  testWidgets('tapping a layout chip fires onChanged with that layout', (
    tester,
  ) async {
    final readChanged = await captureChange(tester);
    await tester.tap(find.byKey(const Key('layout_row3')));
    await tester.pump();
    final changed = readChanged();
    expect(changed?.layout, qrc.LayoutId.row3);
    expect(changed?.targetFps, 15, reason: 'other fields preserved');
    expect(changed?.bytesPerTile, qrc.BytesPerTileId.oneK);
  });

  testWidgets('tapping a fps segment fires onChanged with that fps', (
    tester,
  ) async {
    final readChanged = await captureChange(tester);
    await tester.tap(find.text('24'));
    await tester.pump();
    expect(readChanged()?.targetFps, 24);
  });

  testWidgets('tapping a bytes segment fires onChanged with that tile size', (
    tester,
  ) async {
    final readChanged = await captureChange(tester);
    await tester.tap(find.text('2.5 KB'));
    await tester.pump();
    expect(readChanged()?.bytesPerTile, qrc.BytesPerTileId.twoAndHalfK);
  });

  testWidgets('estimate reflects the selected settings (2 KB, row3, 30fps)', (
    tester,
  ) async {
    await captureChange(
      tester,
      settings: const qrc.TransferSettings(
        bytesPerTile: qrc.BytesPerTileId.twoK,
        layout: qrc.LayoutId.row3,
        targetFps: 30,
        highRefresh: true,
      ),
      refreshRate: 120,
    );
    // estimateThroughput({2k,row3,30,hr}) = 30×(3−1/32)×2048 ≈ 182400 B/s ≈ 178 KB/s
    expect(find.text('~178 KB/s'), findsOneWidget);
  });

  testWidgets('row2 and column2 layout chips render with labels 1×2 / 2×1', (
    tester,
  ) async {
    await captureChange(tester);

    expect(find.byKey(const Key('layout_row2')), findsOneWidget);
    expect(find.byKey(const Key('layout_column2')), findsOneWidget);
    expect(find.text('1×2'), findsOneWidget);
    expect(find.text('2×1'), findsOneWidget);
  });

  testWidgets('column layout chips show a vertical-stack glyph and row chips a horizontal one', (
    tester,
  ) async {
    await captureChange(tester);

    // Labels read "rows × columns": 2×1/3×1 are vertical columns, 1×2/1×3 are
    // horizontal rows. The glyph is a mini-grid of that many cells, drawn
    // in the actual arrangement (stacked for a column, side by side for a
    // row). Verify the cell counts match rows × cols.
    final columnChip = find.byKey(const Key('layout_column2'));
    final column3Chip = find.byKey(const Key('layout_column3'));
    final rowChip = find.byKey(const Key('layout_row2'));
    final row3Chip = find.byKey(const Key('layout_row3'));
    expect(columnChip, findsOneWidget);
    expect(column3Chip, findsOneWidget);
    expect(rowChip, findsOneWidget);
    expect(row3Chip, findsOneWidget);

    int cellsIn(Finder chip) =>
        find.descendant(of: chip, matching: find.byType(Container)).evaluate().length;

    expect(cellsIn(columnChip), 2, reason: '2×1 = two cells');
    expect(cellsIn(column3Chip), 3, reason: '3×1 = three cells');
    expect(cellsIn(rowChip), 2, reason: '1×2 = two cells');
    expect(cellsIn(row3Chip), 3, reason: '1×3 = three cells');
  });

  testWidgets('tapping the row2 chip fires onChanged with LayoutId.row2', (
    tester,
  ) async {
    final readChanged = await captureChange(tester);
    await tester.tap(find.byKey(const Key('layout_row2')));
    await tester.pump();
    final changed = readChanged();
    expect(changed?.layout, qrc.LayoutId.row2);
    expect(changed?.targetFps, 15, reason: 'other fields preserved');
    expect(changed?.bytesPerTile, qrc.BytesPerTileId.oneK);
  });

  testWidgets(
    'tapping the column2 chip fires onChanged with LayoutId.column2',
    (tester) async {
      final readChanged = await captureChange(tester);
      await tester.tap(find.byKey(const Key('layout_column2')));
      await tester.pump();
      final changed = readChanged();
      expect(changed?.layout, qrc.LayoutId.column2);
      expect(changed?.targetFps, 15, reason: 'other fields preserved');
      expect(changed?.bytesPerTile, qrc.BytesPerTileId.oneK);
    },
  );

  testWidgets('row2 estimate matches single (dual-lane = 1 symbol/tick)', (
    tester,
  ) async {
    Future<String> estimateFor(qrc.LayoutId layout) async {
      await captureChange(
        tester,
        settings: qrc.TransferSettings(
          bytesPerTile: qrc.BytesPerTileId.oneK,
          layout: layout,
          targetFps: 15,
          highRefresh: false,
        ),
      );
      return tester.widget<Text>(find.textContaining('KB/s')).data ?? '';
    }

    final single = await estimateFor(qrc.LayoutId.single);
    final row2 = await estimateFor(qrc.LayoutId.row2);
    expect(
      row2,
      single,
      reason:
          'dual-lane shows 1 new symbol/tick, not 2 — the estimate '
          'must not double the single-tile rate',
    );
  });
}
