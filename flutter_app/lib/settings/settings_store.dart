/// Persists the default transfer settings in SharedPreferences.
///
/// Stored under individual keys (no JSON blob) so a future field addition is
/// a backward-compatible no-op. Any missing or corrupt value resolves to
/// [defaultTransferSettings]; storage failures never throw.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/sender/settings.dart';

/// Default transfer settings persisted across app restarts and pre-filling
/// each send flow.
class SettingsStore {
  SettingsStore({this._prefs});

  /// Injectable for tests; when null the store fetches the shared instance.
  final SharedPreferences? _prefs;

  static const _bytesPerTileKey = 'qrstream.defaults.bytesPerTile';
  static const _layoutKey = 'qrstream.defaults.layout';
  static const _targetFpsKey = 'qrstream.defaults.targetFps';
  static const _highRefreshKey = 'qrstream.defaults.highRefresh';

  Future<SharedPreferences> _instance() async =>
      _prefs ?? await SharedPreferences.getInstance();

  /// Loads the persisted defaults, falling back to [defaultTransferSettings]
  /// on any missing/corrupt value or storage failure.
  Future<qrc.TransferSettings> load() async {
    try {
      final prefs = await _instance();
      final bytesPerTile = _readBytesPerTile(prefs);
      final layout = _readLayout(prefs);
      final targetFps = prefs.getInt(_targetFpsKey);
      final highRefresh = prefs.getBool(_highRefreshKey);
      if (bytesPerTile == null ||
          layout == null ||
          targetFps == null ||
          highRefresh == null) {
        return defaultTransferSettings;
      }
      final settings = qrc.TransferSettings(
        bytesPerTile: bytesPerTile,
        layout: layout,
        targetFps: targetFps,
        highRefresh: highRefresh,
      );
      validateSettings(settings);
      return settings;
    } catch (_) {
      return defaultTransferSettings;
    }
  }

  /// Persists all four keys. Validates first so invalid settings fail loudly;
  /// storage write failures are swallowed (best-effort persistence).
  Future<void> save(qrc.TransferSettings settings) async {
    validateSettings(settings);
    try {
      final prefs = await _instance();
      await prefs.setString(_bytesPerTileKey, settings.bytesPerTile.id);
      await prefs.setString(_layoutKey, settings.layout.name);
      await prefs.setInt(_targetFpsKey, settings.targetFps);
      await prefs.setBool(_highRefreshKey, settings.highRefresh);
    } catch (_) {
      // Ignore storage failures; the in-memory settings still apply.
    }
  }

  qrc.BytesPerTileId? _readBytesPerTile(SharedPreferences prefs) {
    final raw = prefs.getString(_bytesPerTileKey);
    for (final id in qrc.BytesPerTileId.values) {
      if (id.id == raw) return id;
    }
    return null;
  }

  qrc.LayoutId? _readLayout(SharedPreferences prefs) {
    final raw = prefs.getString(_layoutKey);
    return qrc.LayoutId.values.asNameMap()[raw];
  }
}
