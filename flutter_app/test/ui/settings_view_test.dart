// SettingsView widget tests: the nav-destination editor for DEFAULT transfer
// settings. Loads persisted defaults, persists each change immediately, and
// "Restore defaults" resets + saves. Uses a real SettingsStore backed by the
// in-memory SharedPreferences mock (no platform channels).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/sender/settings.dart';

import 'package:qr_data_transfer/settings/settings_store.dart';
import 'package:qr_data_transfer/ui/settings_panel.dart';

void main() {
  Future<void> pumpView(
    WidgetTester tester, {
    Map<String, Object> initial = const {},
  }) async {
    SharedPreferences.setMockInitialValues(initial);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsView(store: SettingsStore())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, Object> defaults() => {
        'qrstream.defaults.bytesPerTile': '1k',
        'qrstream.defaults.layout': 'grid4',
        'qrstream.defaults.targetFps': 15,
        'qrstream.defaults.highRefresh': false,
      };

  testWidgets('editor loads and shows the persisted defaults', (tester) async {
    await pumpView(tester, initial: defaults());

    expect(find.text('Default transfer settings'), findsOneWidget);
    expect(
      find.text('Used to pre-fill each send. Change per-file in the send flow.'),
      findsOneWidget,
    );
    // 15 fps selected.
    final fps = tester.widget<SegmentedButton<int>>(
      find.byKey(const Key('fps_group')),
    );
    expect(fps.selected, {15});
    // 1 KB selected.
    final bytes = tester.widget<SegmentedButton<qrc.BytesPerTileId>>(
      find.byKey(const Key('bytes_group')),
    );
    expect(bytes.selected, {qrc.BytesPerTileId.oneK});
    // 2×2 layout chip selected.
    expect(
      tester.widget<ChoiceChip>(find.byKey(const Key('layout_grid4'))).selected,
      isTrue,
    );
    expect(find.byKey(const Key('high_refresh_switch')), findsOneWidget);
  });

  testWidgets('tapping fps/bytes/layout/high-refresh persists immediately',
      (tester) async {
    await pumpView(tester, initial: defaults());

    await tester.tap(find.text('24'));
    await tester.tap(find.text('2 KB'));
    await tester.tap(find.byKey(const Key('layout_row3')));
    await tester.tap(find.byKey(const Key('high_refresh_switch')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('qrstream.defaults.targetFps'), 24);
    expect(prefs.getString('qrstream.defaults.bytesPerTile'), '2k');
    expect(prefs.getString('qrstream.defaults.layout'), 'row3');
    expect(prefs.getBool('qrstream.defaults.highRefresh'), isTrue);

    // The UI reflects the new values too (no separate Save button).
    final fps = tester.widget<SegmentedButton<int>>(
      find.byKey(const Key('fps_group')),
    );
    expect(fps.selected, {24});
    expect(
      tester.widget<ChoiceChip>(find.byKey(const Key('layout_row3'))).selected,
      isTrue,
    );
  });

  testWidgets('Restore defaults resets the editor and saves', (tester) async {
    await pumpView(tester, initial: {
      'qrstream.defaults.bytesPerTile': '2k',
      'qrstream.defaults.layout': 'row3',
      'qrstream.defaults.targetFps': 24,
      'qrstream.defaults.highRefresh': true,
    });

    await tester.tap(find.byKey(const Key('restore_defaults')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('qrstream.defaults.targetFps'),
      defaultTransferSettings.targetFps,
    );
    expect(
      prefs.getString('qrstream.defaults.bytesPerTile'),
      defaultTransferSettings.bytesPerTile.id,
    );
    expect(
      prefs.getString('qrstream.defaults.layout'),
      defaultTransferSettings.layout.name,
    );
    expect(
      prefs.getBool('qrstream.defaults.highRefresh'),
      defaultTransferSettings.highRefresh,
    );
    final fps = tester.widget<SegmentedButton<int>>(
      find.byKey(const Key('fps_group')),
    );
    expect(fps.selected, {defaultTransferSettings.targetFps});
  });
}
