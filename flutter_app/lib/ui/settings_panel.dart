import 'package:flutter/material.dart';
import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/sender/pacing.dart' as qrp;
import 'package:qr_transfer_core/sender/settings.dart';

import '../settings/settings_store.dart';

/// Nav-destination screen for app-level settings (the shell's third tab).
/// Edits the DEFAULT transfer settings, persisting each change immediately;
/// the values pre-fill the send flow. Transfer-specific settings
/// (fps/bytes/layout per-file) live in the send flow's SettingsPanel.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key, this.store});

  /// Injectable for tests; defaults to the real [SettingsStore].
  final SettingsStore? store;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final SettingsStore _store = widget.store ?? SettingsStore();
  bool _loaded = false;
  qrc.TransferSettings _settings = defaultTransferSettings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _store.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loaded = true;
    });
  }

  void _update(qrc.TransferSettings next) {
    setState(() => _settings = next);
    _store.save(next);
  }

  void _restoreDefaults() => _update(defaultTransferSettings);

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Default transfer settings',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Used to pre-fill each send. Change per-file in the send flow.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _sectionLabel(context, 'Display fps'),
              _fpsSelector(context),
              const SizedBox(height: 16),
              _sectionLabel(context, 'Bytes per tile'),
              _bytesSelector(context),
              const SizedBox(height: 16),
              _sectionLabel(context, 'Tile layout'),
              _layoutSelector(context),
              const SizedBox(height: 16),
              _refreshRow(context),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('restore_defaults'),
                  onPressed: _restoreDefaults,
                  child: const Text('Restore defaults'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _fpsSelector(BuildContext context) {
    return SegmentedButton<int>(
      key: const Key('fps_group'),
      segments: [
        for (final fps in SettingsPanel._fpsOptions)
          ButtonSegment<int>(
            value: fps,
            label: Text('$fps'),
            enabled: fps != 30 || _settings.highRefresh,
            icon: fps == 30 && !_settings.highRefresh
                ? const Tooltip(
                    message: 'Needs a 90 Hz+ display',
                    child: Icon(Icons.lock_outline, size: 14),
                  )
                : null,
          ),
      ],
      selected: {_settings.targetFps},
      onSelectionChanged: (sel) => _update(
        qrc.TransferSettings(
          bytesPerTile: _settings.bytesPerTile,
          layout: _settings.layout,
          targetFps: sel.first,
          highRefresh: _settings.highRefresh,
        ),
      ),
    );
  }

  Widget _bytesSelector(BuildContext context) {
    return SegmentedButton<qrc.BytesPerTileId>(
      key: const Key('bytes_group'),
      segments: [
        for (final id in SettingsPanel._tileOrder)
          ButtonSegment<qrc.BytesPerTileId>(
            value: id,
            label: Text(
              id == qrc.BytesPerTileId.oneK
                  ? '1 KB'
                  : id == qrc.BytesPerTileId.twoK
                  ? '2 KB'
                  : '2.5 KB',
            ),
          ),
      ],
      selected: {_settings.bytesPerTile},
      onSelectionChanged: (sel) => _update(
        qrc.TransferSettings(
          bytesPerTile: sel.first,
          layout: _settings.layout,
          targetFps: _settings.targetFps,
          highRefresh: _settings.highRefresh,
        ),
      ),
    );
  }

  Widget _layoutSelector(BuildContext context) {
    return Wrap(
      key: const Key('layout_group'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final layout in SettingsPanel._layoutOrder)
          ChoiceChip(
            key: Key('layout_${layout.name}'),
            label: Text(SettingsPanel._layoutLabel(layout)),
            avatar: SettingsPanel._layoutGlyph(context, layout),
            selected: _settings.layout == layout,
            showCheckmark: false,
            onSelected: (_) => _update(
              qrc.TransferSettings(
                bytesPerTile: _settings.bytesPerTile,
                layout: layout,
                targetFps: _settings.targetFps,
                highRefresh: _settings.highRefresh,
              ),
            ),
          ),
      ],
    );
  }

  Widget _refreshRow(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'HIGH REFRESH RATE',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                'Detected on the sending device',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Switch(
          key: const Key('high_refresh_switch'),
          value: _settings.highRefresh,
          onChanged: (v) => _update(
            qrc.TransferSettings(
              bytesPerTile: _settings.bytesPerTile,
              layout: _settings.layout,
              targetFps: _settings.targetFps,
              highRefresh: v,
            ),
          ),
        ),
      ],
    );
  }
}

/// Settings step of the send flow: pick display fps, bytes-per-tile,
/// tile layout and high-refresh, with a live speed/ETA estimate.
///
/// Changing [settings] via [onChanged] never re-encodes: the parent only
/// re-prepares the transfer when [qrc.TransferSettings.bytesPerTile] changes
/// (different mtu -> different chunking). fps/layout/high-refresh changes
/// just re-run the estimate here.
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.compressedSize,
    required this.refreshRate,
    required this.suggestedLayout,
    required this.onBegin,
    required this.onDifferentFile,
    required this.fileName,
    required this.fileSize,
  });

  /// Current transfer settings (the parent owns the state).
  final qrc.TransferSettings settings;

  /// Fired when the user changes any setting; the parent decides whether to
  /// re-prepare (bytesPerTile) or just accept the new estimate.
  final ValueChanged<qrc.TransferSettings> onChanged;

  /// Post-compression payload size (from the prepared transfer) — drives ETA.
  final int compressedSize;

  /// Detected display refresh rate; null while still detecting.
  final int? refreshRate;

  /// Layout the viewport calls for; shown as "recommended" until overridden.
  final qrc.LayoutId suggestedLayout;

  final VoidCallback onBegin;
  final VoidCallback onDifferentFile;
  final String fileName;
  final int fileSize;

  static const List<int> _fpsOptions = [12, 15, 24, 30];
  static const List<qrc.BytesPerTileId> _tileOrder = [
    qrc.BytesPerTileId.oneK,
    qrc.BytesPerTileId.twoK,
    qrc.BytesPerTileId.twoAndHalfK,
  ];
  // Chips read "rows × columns", grouped by family: single, then the
  // columns (2×1, 3×1) and rows (1×2, 1×3), then the grids (2×2, 3×3).
  static const List<qrc.LayoutId> _layoutOrder = [
    qrc.LayoutId.single,
    qrc.LayoutId.column2,
    qrc.LayoutId.column3,
    qrc.LayoutId.row2,
    qrc.LayoutId.row3,
    qrc.LayoutId.grid4,
    qrc.LayoutId.grid9,
  ];

  @override
  Widget build(BuildContext context) {
    final bps = qrp.estimateThroughput(settings);
    final etaSeconds = qrp.estimateEtaSeconds(settings, compressedSize);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _fileHeader(context),
          const SizedBox(height: 20),
          _sectionLabel(context, 'Display fps'),
          _fpsSelector(context),
          const SizedBox(height: 16),
          _sectionLabel(context, 'Bytes per tile'),
          _bytesSelector(context),
          const SizedBox(height: 16),
          _sectionLabel(context, 'Tile layout'),
          _layoutSelector(context),
          const SizedBox(height: 16),
          _refreshRow(context),
          const SizedBox(height: 20),
          _estimateCard(context, bps, etaSeconds),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('begin_broadcast'),
            onPressed: onBegin,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Begin broadcast'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          TextButton(
            onPressed: onDifferentFile,
            child: const Text('Different file'),
          ),
        ],
      ),
    );
  }

  Widget _fileHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fileName,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              Text(
                _formatBytes(fileSize),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Chip(
          label: Text(transferLabel(settings)),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _fpsSelector(BuildContext context) {
    return SegmentedButton<int>(
      key: const Key('fps_group'),
      segments: [
        for (final fps in _fpsOptions)
          ButtonSegment<int>(
            value: fps,
            label: Text('$fps'),
            enabled: fps != 30 || settings.highRefresh,
            icon: fps == 30 && !settings.highRefresh
                ? const Tooltip(
                    message: 'Needs a 90 Hz+ display',
                    child: Icon(Icons.lock_outline, size: 14),
                  )
                : null,
          ),
      ],
      selected: {settings.targetFps},
      onSelectionChanged: (sel) => onChanged(
        qrc.TransferSettings(
          bytesPerTile: settings.bytesPerTile,
          layout: settings.layout,
          targetFps: sel.first,
          highRefresh: settings.highRefresh,
        ),
      ),
    );
  }

  Widget _bytesSelector(BuildContext context) {
    return SegmentedButton<qrc.BytesPerTileId>(
      key: const Key('bytes_group'),
      segments: [
        for (final id in _tileOrder)
          ButtonSegment<qrc.BytesPerTileId>(
            value: id,
            label: Text(
              id == qrc.BytesPerTileId.oneK
                  ? '1 KB'
                  : id == qrc.BytesPerTileId.twoK
                  ? '2 KB'
                  : '2.5 KB',
            ),
          ),
      ],
      selected: {settings.bytesPerTile},
      onSelectionChanged: (sel) => onChanged(
        qrc.TransferSettings(
          bytesPerTile: sel.first,
          layout: settings.layout,
          targetFps: settings.targetFps,
          highRefresh: settings.highRefresh,
        ),
      ),
    );
  }

  Widget _layoutSelector(BuildContext context) {
    return Wrap(
      key: const Key('layout_group'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final layout in _layoutOrder)
          ChoiceChip(
            key: Key('layout_${layout.name}'),
            label: Text(_layoutLabel(layout)),
            avatar: _layoutGlyph(context, layout),
            selected: settings.layout == layout,
            showCheckmark: false,
            onSelected: (_) => onChanged(
              qrc.TransferSettings(
                bytesPerTile: settings.bytesPerTile,
                layout: layout,
                targetFps: settings.targetFps,
                highRefresh: settings.highRefresh,
              ),
            ),
          ),
      ],
    );
  }

  Widget _refreshRow(BuildContext context) {
    final theme = Theme.of(context);
    final detecting = refreshRate == null;
    final supported = (refreshRate ?? 0) >= 90;
    final hint = detecting
        ? 'Detecting display…'
        : 'Detected $refreshRate Hz display';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'HIGH REFRESH RATE',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(hint, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        Switch(
          key: const Key('high_refresh_switch'),
          value: settings.highRefresh,
          onChanged: detecting || !supported
              ? null
              : (v) => onChanged(
                  qrc.TransferSettings(
                    bytesPerTile: settings.bytesPerTile,
                    layout: settings.layout,
                    targetFps: settings.targetFps,
                    highRefresh: v,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _estimateCard(BuildContext context, double bps, double etaSeconds) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'EXPECTED SPEED',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '~${(bps / 1024).round()} KB/s',
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  '~${_formatEta(etaSeconds)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          Icon(Icons.speed, color: theme.colorScheme.tertiary, size: 32),
        ],
      ),
    );
  }

  static String _layoutLabel(qrc.LayoutId layout) {
    // Labels read as "rows × columns" (standard grid notation): the 1×3
    // column of tiles is "3×1" (3 rows, 1 column) and the 3-across row is
    // "1×3" (1 row, 3 columns).
    switch (layout) {
      case qrc.LayoutId.single:
        return '1×1';
      case qrc.LayoutId.column2:
        return '2×1';
      case qrc.LayoutId.column3:
        return '3×1';
      case qrc.LayoutId.row2:
        return '1×2';
      case qrc.LayoutId.row3:
        return '1×3';
      case qrc.LayoutId.grid4:
        return '2×2';
      case qrc.LayoutId.grid9:
        return '3×3';
    }
  }

  static Widget? _layoutGlyph(BuildContext context, qrc.LayoutId layout) {
    // Draw the ACTUAL tile arrangement (rows × cols) so the glyph is
    // unambiguous: 2×1 is two stacked squares, 1×2 is two side-by-side.
    // Material's view_agenda/view_column icons are too similar at 14px.
    return switch (layout) {
      qrc.LayoutId.single => _layoutMiniGrid(context, 1, 1),
      qrc.LayoutId.column2 => _layoutMiniGrid(context, 2, 1),
      qrc.LayoutId.column3 => _layoutMiniGrid(context, 3, 1),
      qrc.LayoutId.row2 => _layoutMiniGrid(context, 1, 2),
      qrc.LayoutId.row3 => _layoutMiniGrid(context, 1, 3),
      qrc.LayoutId.grid4 => _layoutMiniGrid(context, 2, 2),
      qrc.LayoutId.grid9 => _layoutMiniGrid(context, 3, 3),
    };
  }

  /// A tiny grid of rounded squares reflecting the layout's rows × cols.
  static Widget _layoutMiniGrid(BuildContext context, int rows, int cols) {
    const gap = 2.0;
    const tile = 4.0;
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget cell(Widget child, int c) => Padding(
      padding: EdgeInsets.only(right: c == cols - 1 ? 0 : gap),
      child: child,
    );
    Widget row(int r) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var c = 0; c < cols; c++)
          cell(
            Container(
              width: tile,
              height: tile,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            c,
          ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) const SizedBox(height: gap),
          row(r),
        ],
      ],
    );
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _formatEta(double seconds) {
    if (seconds < 1) return '<1s';
    if (seconds < 60) return '${seconds.round()}s';
    return '${(seconds / 60).toStringAsFixed(0)}m';
  }
}
