import 'package:flutter/material.dart';
import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/sender/pacing.dart' as qrp;
import 'package:qr_transfer_core/sender/settings.dart';

/// Nav-destination screen for app-level settings (the shell's third tab).
/// Holds the default transfer settings + refresh-rate info; transfer-specific
/// settings (fps/bytes/layout per-file) live in the send flow's SettingsPanel.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('Settings', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Default transfer settings: ${transferLabel(defaultTransferSettings)}. '
              'Per-file settings (fps, bytes per tile, layout, high refresh) '
              'are chosen in the send flow before broadcasting.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
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
  static const List<qrc.LayoutId> _layoutOrder = [
    qrc.LayoutId.single,
    qrc.LayoutId.column3,
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
            label: Text(id == qrc.BytesPerTileId.oneK
                ? '1 KB'
                : id == qrc.BytesPerTileId.twoK
                    ? '2 KB'
                    : '2.5 KB'),
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
            avatar: _layoutGlyph(layout),
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
              Text('HIGH REFRESH RATE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
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
                Text('EXPECTED SPEED',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.2,
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
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
    switch (layout) {
      case qrc.LayoutId.single:
        return '1×1';
      case qrc.LayoutId.column3:
        return '1×3';
      case qrc.LayoutId.row3:
        return '3×1';
      case qrc.LayoutId.grid4:
        return '2×2';
      case qrc.LayoutId.grid9:
        return '3×3';
    }
  }

  static Widget? _layoutGlyph(qrc.LayoutId layout) {
    switch (layout) {
      case qrc.LayoutId.column3:
        return const Icon(Icons.view_column, size: 14);
      case qrc.LayoutId.row3:
        return const Icon(Icons.view_agenda, size: 14);
      default:
        return null;
    }
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
