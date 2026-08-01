/// Broadcast view — the always-dark QR stage with status chips and Boost/Stop
/// transport controls. Port of the PWA's `SenderBroadcast`
/// (src/ui/SenderBroadcast.tsx).
///
/// A [BroadcastController] drives a continuous grid of QR tiles; the view
/// paints them full-bleed on the espresso stage via [QrGridPainter], repainting
/// on the controller's frame signal. A bottom gradient overlay carries the
/// live status chips (filename, size, transfer profile, rate, k, fps, dropped,
/// elapsed) and the Boost (screen-awake) and Stop controls.
///
/// The stage theme comes from lib/theme/app_theme.dart (T5.1): the Scaffold
/// always paints the espresso background, so the stage stays dark even under a
/// light app theme.
library;

import 'package:flutter/material.dart' hide LayoutId;
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/sender/pacing.dart';
import 'package:qr_transfer_core/sender/pipeline.dart';
import 'package:qr_transfer_core/sender/settings.dart';

import '../sender/broadcast_controller.dart';
import '../theme/app_theme.dart';
import 'qr_grid_painter.dart';

/// Full-screen broadcast display for one prepared transfer.
class BroadcastView extends StatefulWidget {
  const BroadcastView({
    super.key,
    required this.prepared,
    required this.settings,
    required this.onStop,
  });

  /// The transfer to broadcast; the controller owns and disposes its encoder.
  final PreparedTransfer prepared;

  /// Broadcast settings; must match [PreparedTransfer.info] settings.
  final TransferSettings settings;

  /// Invoked once the broadcast has been stopped and disposed.
  final VoidCallback onStop;

  @override
  State<BroadcastView> createState() => _BroadcastViewState();
}

class _BroadcastViewState extends State<BroadcastView>
    with SingleTickerProviderStateMixin {
  late final BroadcastController _controller;
  SenderStats? _stats;
  bool _boost = false;

  @override
  void initState() {
    super.initState();
    _controller = BroadcastController(
      prepared: widget.prepared,
      settings: widget.settings,
      vsync: this,
      onStats: (stats) => setState(() => _stats = stats),
    )..start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleBoost() {
    setState(() => _boost = !_boost);
    _controller.setBoost(_boost);
  }

  void _stop() {
    _controller.dispose();
    widget.onStop();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildQrStageTheme(),
      child: Scaffold(
        backgroundColor: qrStageBackground,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomPaint(
              painter: QrGridPainter(
                tiles: _controller.currentFrame,
                layout: _controller.settings.layout,
                version: _controller.version,
                repaint: _controller.frameSignal,
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: DecoratedBox(
                decoration: _stageOverlayGradient,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: _statusChips(),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            _boostButton(),
                            const SizedBox(width: 12),
                            _stopButton(),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const BoxDecoration _stageOverlayGradient = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: <double>[0, 0.65, 1],
      colors: <Color>[
        Color(0x000F1115),
        Color(0x8C0F1115),
        Color(0xEB0F1115),
      ],
    ),
  );

  List<Widget> _statusChips() {
    final stats = _stats;
    final info = widget.prepared.info;
    if (stats == null) {
      return <Widget>[const _Chip(text: 'Starting…')];
    }
    final settings = info.settings;
    final elapsed = stats.fps > 0 ? (stats.tickCount / stats.fps).round() : 0;
    return <Widget>[
      _Chip(text: info.filename, ellipsis: true),
      _Chip(text: _formatBytes(info.totalSize)),
      _Chip(text: transferLabel(settings), variant: _ChipVariant.accent),
      if (stats.fps > 0)
        _Chip(text: '${_formatBytes(estimateThroughput(settings).round())}/s'),
      _Chip(text: 'k ${stats.k}'),
      _Chip(text: '${stats.fps} fps'),
      _Chip(text: '${stats.droppedTicks} dropped', variant: _ChipVariant.warn),
      _Chip(text: _formatEta(elapsed)),
    ];
  }

  Widget _boostButton() => OutlinedButton.icon(
        onPressed: _toggleBoost,
        icon: Icon(_boost ? Icons.brightness_high : Icons.brightness_low),
        label: const Text('Boost'),
      );

  Widget _stopButton() => OutlinedButton.icon(
        onPressed: _stop,
        icon: const Icon(Icons.stop_rounded),
        label: const Text('Stop'),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFFF8A84),
          side: const BorderSide(color: Color(0x73F85149)),
        ),
      );
}

enum _ChipVariant { muted, accent, warn }

class _Chip extends StatelessWidget {
  const _Chip({
    required this.text,
    this.variant = _ChipVariant.muted,
    this.ellipsis = false,
  });

  final String text;
  final _ChipVariant variant;
  final bool ellipsis;

  @override
  Widget build(BuildContext context) {
    final (Color foreground, Color border) = switch (variant) {
      _ChipVariant.muted => (const Color(0xFF8B93A0), const Color(0xFF232830)),
      _ChipVariant.accent => (const Color(0xFF8FB8FF), const Color(0x734F8CFF)),
      _ChipVariant.warn => (const Color(0xFFE0B35C), const Color(0x73D29922)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF161A20),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      constraints: ellipsis
          ? const BoxConstraints(maxWidth: 176)
          : const BoxConstraints(),
      child: Text(
        text,
        maxLines: 1,
        overflow: ellipsis ? TextOverflow.ellipsis : TextOverflow.clip,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontFamily: 'monospace',
            ),
      ),
    );
  }
}

/// Human-readable byte size, matching the PWA's `formatBytes`.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  do {
    value /= 1024;
    unit += 1;
  } while (value >= 1024 && unit < units.length - 1);
  final formatted = value >= 100 ? value.round() : (value * 10).round() / 10;
  return '$formatted ${units[unit]}';
}

/// Human-readable duration from seconds, matching the PWA's `formatEta`.
String _formatEta(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final restSeconds = seconds % 60;
  if (minutes < 60) {
    return restSeconds == 0 ? '${minutes}m' : '${minutes}m ${restSeconds}s';
  }
  final hours = minutes ~/ 60;
  final restMinutes = minutes % 60;
  return restMinutes == 0 ? '${hours}h' : '${hours}h ${restMinutes}m';
}
