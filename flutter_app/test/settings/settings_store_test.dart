// SettingsStore tests: persists TransferSettings in SharedPreferences under
// individual keys, falls back to defaults on any missing/corrupt value, and
// round-trips a save. Uses the in-memory mock store (no platform channels).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/sender/settings.dart';

import 'package:qr_data_transfer/settings/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load returns defaultTransferSettings on empty prefs', () async {
    SharedPreferences.setMockInitialValues({});

    final settings = await SettingsStore().load();

    expect(settings, defaultTransferSettings);
  });

  test('save then load round-trips the settings byte-for-byte', () async {
    SharedPreferences.setMockInitialValues({});
    const custom = qrc.TransferSettings(
      bytesPerTile: qrc.BytesPerTileId.twoK,
      layout: qrc.LayoutId.row3,
      targetFps: 24,
      highRefresh: true,
    );

    await SettingsStore().save(custom);
    final loaded = await SettingsStore().load();

    expect(loaded, custom);

    // The four individual keys are written in the documented formats.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('qrstream.defaults.bytesPerTile'), '2k');
    expect(prefs.getString('qrstream.defaults.layout'), 'row3');
    expect(prefs.getInt('qrstream.defaults.targetFps'), 24);
    expect(prefs.getBool('qrstream.defaults.highRefresh'), isTrue);
  });

  test('corrupt values fall back to defaults without throwing', () async {
    SharedPreferences.setMockInitialValues({
      'qrstream.defaults.targetFps': 999,
      'qrstream.defaults.layout': 'nope',
      'qrstream.defaults.bytesPerTile': 'not-a-size',
      'qrstream.defaults.highRefresh': false,
    });

    final settings = await SettingsStore().load();

    expect(settings, defaultTransferSettings);
  });

  test('partially missing values fall back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      'qrstream.defaults.targetFps': 24,
      // bytesPerTile and layout missing entirely.
    });

    final settings = await SettingsStore().load();

    expect(settings, defaultTransferSettings);
  });
}
