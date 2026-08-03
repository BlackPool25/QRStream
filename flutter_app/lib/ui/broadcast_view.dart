/// Broadcast view — the always-dark QR stage with minimal transport controls.
/// Port of the PWA's `SenderBroadcast` (src/ui/SenderBroadcast.tsx).
///
/// A [BroadcastController] drives a continuous grid of QR tiles; the view
/// paints them full-bleed on the espresso stage via [QrGridPainter], repainting
/// on the controller's frame signal. The overlay is deliberately minimal so
/// the receiver camera sees as much clean QR as possible: one compact pill of
/// transport controls (Fullscreen / Stop) at the top and a single
/// dim live-stats line at the bottom. Fullscreen hides the system bars
/// (immersive sticky) so the whole display is QR.
///
/// The stage theme comes from lib/theme/app_theme.dart (T5.1): the Scaffold
/// always paints the espresso background, so the stage stays dark even under a
/// light app theme.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide LayoutId;
import 'package:flutter/services.dart';
import 'package:qr_transfer_core/protocol/constants.dart';
import 'package:qr_transfer_core/qr/qr_encode.dart';
import 'package:qr_transfer_core/sender/encode_worker.dart';
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
    this.encodeBackend,
  });

  /// The transfer to broadcast; the controller owns and disposes its encoder.
  final PreparedTransfer prepared;

  /// Broadcast settings; must match [PreparedTransfer.info] settings.
  final TransferSettings settings;

  /// Invoked once the broadcast has been stopped and disposed.
  final VoidCallback onStop;

  /// Encode backend for the broadcast loop; defaults to the background
  /// isolate worker. Tests inject a synchronous fake.
  final EncodeBackend? encodeBackend;

  @override
  State<BroadcastView> createState() => _BroadcastViewState();
}

class _BroadcastViewState extends State<BroadcastView>
    with SingleTickerProviderStateMixin {
  late final BroadcastController _controller;
  late final _TileImageCache _imageCache;
  SenderStats? _stats;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// Overlay controls auto-hide after this long so they never sit over the QR
  /// stream during active broadcasting; tapping the stage brings them back.
  static const Duration _controlsTimeout = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _imageCache = _TileImageCache();
    _controller = BroadcastController(
      prepared: widget.prepared,
      settings: widget.settings,
      vsync: this,
      onStats: (stats) => setState(() => _stats = stats),
      onFramesDrained: _onFramesDrained,
      encode: widget.encodeBackend,
    )..start();
    // Rebuild on every applied frame (and on tile-bitmap decodes) so the
    // painter always reads the controller's LIVE frame — the CustomPaint's
    // `repaint` listenable alone would repaint the last-BUILT painter with
    // stale tiles, freezing the visible stream between stats rebuilds.
    _controller.frameSignal.addListener(_onFrame);
    _imageCache.addListener(_onFrame);
    _scheduleHide();
  }

  void _onFrame() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.frameSignal.removeListener(_onFrame);
    _imageCache.removeListener(_onFrame);
    _imageCache.dispose();
    _controller.dispose();
    // Leave fullscreen when the broadcast ends (best-effort; fire-and-forget).
    if (_fullscreen) {
      unawaited(_setBroadcastFullscreen(false));
    }
    super.dispose();
  }

  /// Pre-decodes the drained frames' tiles into the bitmap cache so they are
  /// ready to blit one frame before they are displayed.
  void _onFramesDrained(List<DrainedFrame> frames) {
    for (final frame in frames) {
      for (var i = 0; i < frame.tiles.length; i++) {
        final esi = i < frame.esis.length ? frame.esis[i] : i;
        _imageCache.ensure(esi, frame.tiles[i]);
      }
    }
  }

  /// Shows the overlay and restarts the auto-hide countdown.
  void _pokeControls() {
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsTimeout, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleFullscreen() {
    _pokeControls();
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    unawaited(_setBroadcastFullscreen(next));
  }

  /// Fullscreen the broadcast stage: real window fullscreen on Linux desktop
  /// (GTK via the runner's `qrstream/window` channel); immersive system bars
  /// on Android/iOS.
  static Future<void> _setBroadcastFullscreen(bool on) async {
    if (Platform.isLinux) {
      const channel = MethodChannel('qrstream/window');
      try {
        await channel.invokeMethod<void>('setFullscreen', <bool>[on]);
      } on MissingPluginException {
        // Not running under the desktop runner (e.g. widget tests) — no-op.
      }
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(
      on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
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
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Tapping the QR stage brings the overlay back (and resets the
          // auto-hide countdown).
          onTap: _pokeControls,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // Adaptive re-flow: fit the tile grid to the live stage size.
              // suggestLayout is a pure function of the physical canvas, so the
              // builder only calls setLayout when the suggestion actually
              // differs from the controller's current layout (no per-frame
              // churn) — mutating controller state, never widget state, so
              // there is no setState during build.
              LayoutBuilder(
                builder: (context, constraints) {
                  final dpr = MediaQuery.devicePixelRatioOf(context);
                  final suggested = suggestLayout(
                    (constraints.maxWidth * dpr).round(),
                    (constraints.maxHeight * dpr).round(),
                  );
                  if (suggested != _controller.layout) {
                    _controller.setLayout(suggested);
                  }
                  return CustomPaint(
                    painter: QrGridPainter(
                      tiles: _controller.currentFrame,
                      esis: _controller.lastEsis,
                      images: _imageCache.images,
                      layout: _controller.layout,
                      version: _controller.version,
                      devicePixelRatio: dpr,
                    ),
                  );
                },
              ),
              Positioned(
                top: 12,
                right: 12,
                child: SafeArea(
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      key: const Key('overlay_controls'),
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: _controlsPill(),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: SafeArea(
                  top: false,
                  child: Center(
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        key: const Key('overlay_stats'),
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: _statsLine(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact transport controls: Fullscreen / Stop in one subtle pill.
  Widget _controlsPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xCC0F1115),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x33232830)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _pillButton(
            key: const Key('fullscreen_button'),
            onPressed: _toggleFullscreen,
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            label: 'Fullscreen',
          ),
          _pillButton(
            key: const Key('stop_button'),
            onPressed: _stop,
            icon: Icons.stop_rounded,
            label: 'Stop',
            foreground: const Color(0xFFFF8A84),
          ),
        ],
      ),
    );
  }

  Widget _pillButton({
    required Key key,
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    Color? foreground,
  }) {
    return TextButton.icon(
      key: key,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        foregroundColor: foreground ?? const Color(0xFFC9D1DC),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// One dim line of live stats — the whole status, no chip clutter.
  Widget _statsLine() {
    final stats = _stats;
    final info = widget.prepared.info;
    if (stats == null) {
      return _pill(const Text('Starting…', style: _statsTextStyle));
    }
    final settings = info.settings;
    final parts = <String>[
      info.filename,
      transferLabel(settings),
      '${stats.fps.toStringAsFixed(1)} fps',
      '${_formatBytes(estimateThroughput(settings).round())}/s',
      'k ${stats.k}',
      '${stats.droppedTicks} dropped',
    ];
    return _pill(
      Text(
        parts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _statsTextStyle,
      ),
    );
  }

  static const TextStyle _statsTextStyle = TextStyle(
    color: Color(0xFF9AA4B2),
    fontSize: 12,
    fontFamily: 'monospace',
  );

  Widget _pill(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC0F1115),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x33232830)),
      ),
      child: child,
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

/// Bounded cache of pre-decoded tile bitmaps keyed by pool index. The
/// broadcast view decodes each tile's matrix to a [ui.Image] one frame before
/// it is displayed (see [_BroadcastViewState._onFramesDrained]); the painter
/// blits the cached image (a single renderer-friendly draw per tile) instead
/// of re-drawing thousands of module rects every frame.
class _TileImageCache extends ChangeNotifier {
  /// Cache cap in tile images (each ~matrix-resolution RGBA); evicted tiles
  /// are simply re-decoded on their next appearance.
  static const int _maxImages = 256;

  final Map<int, ui.Image> _images = <int, ui.Image>{};
  final Set<int> _decoding = <int>{};
  bool _disposed = false;

  /// Bitmaps ready to blit, keyed by pool index.
  Map<int, ui.Image> get images => _images;

  /// Decodes [matrix] for [esi] into the cache if not already present.
  void ensure(int esi, QrMatrix? matrix) {
    if (_disposed ||
        matrix == null ||
        _images.containsKey(esi) ||
        _decoding.contains(esi)) {
      return;
    }
    _decoding.add(esi);
    final rgba = matrixToRgba(matrix);
    final m = matrix.size;
    ui.decodeImageFromPixels(rgba, m, m, ui.PixelFormat.rgba8888, (image) {
      _decoding.remove(esi);
      if (_disposed) {
        image.dispose();
        return;
      }
      _images[esi] = image;
      while (_images.length > _maxImages) {
        _images.remove(_images.keys.first)?.dispose();
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    super.dispose();
  }
}
