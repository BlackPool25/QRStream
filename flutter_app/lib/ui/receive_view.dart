/// Receive view (Wave 5 T5.5) — the Flutter port of the PWA's ReceiverView +
/// ReceiverOrchestrator + StatusOverlay (src/ui/ReceiverView.tsx,
/// src/receiver/orchestrate.ts, src/ui/StatusOverlay.tsx).
///
/// Flow: Start scanning → camera → RGB frames → DecodePool → FrameBuffer →
/// live stats overlay → Reassembler (Rust FFI fountain) → SHA-256 VERIFIED
/// badge → Save card → tap-to-open. Linux (send-only) shows an info card.
///
/// The camera and saver are injected ([CameraService] / [Saver]) so widget
/// tests drive the full pipeline with fakes; reassembly always runs on the
/// real Rust decoder.
//
// allow: SIZE_OK — the whole receive view (orchestrator + overlay UI) must
// live in this one file per the task's explicit file-allowlist (no sibling
// files), and core's `stats.handleFeedResult` is nominal-only — it cannot
// consume the real frames/reassembler types — so the feed routing is inlined
// here (mirroring it) and the overlay uses the public updateStats.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:qr_data_transfer/receiver/camera_service.dart';
import 'package:qr_data_transfer/receiver/frame_decoder.dart';
import 'package:qr_data_transfer/receiver/receive_controller.dart';
import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_data_transfer/ui/saved_file_preview.dart';
import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/receiver/decode_pool.dart' show DecodeResult;
import 'package:qr_transfer_core/receiver/frames.dart'
    show FeedResult, FeedStatus, FrameBuffer;
import 'package:qr_transfer_core/receiver/reassembler.dart'
    show Reassembler, ReassemblyResult;
import 'package:qr_transfer_core/receiver/stats.dart'
    show FeedState, ReceiverStats, ReceiverStatus, StatsSample, updateStats;

class ReceiveView extends StatefulWidget {
  const ReceiveView({
    super.key,
    this.linuxOnly,
    this.cameraService,
    this.saver,
    this.frameDecoder,
    this.receiveController,
    this.dylibPath,
    this.onExit,
    this.onImmersiveChanged,
  });

  /// Overrides [Platform.isLinux] so tests can pin either mode.
  final bool? linuxOnly;
  final CameraService? cameraService;
  final Saver? saver;

  /// Frame decoder (default: native ML Kit); tests inject a fake.
  final FrameDecoder? frameDecoder;

  /// App-scoped session state; when null the view owns a private controller.
  /// The shell passes its shell-lifetime controller so a completed transfer
  /// survives the tab switches and breakpoint rebuilds that dispose this
  /// State.
  final ReceiveSessionController? receiveController;

  final String? dylibPath;
  final VoidCallback? onExit;

  /// Notified when scanning starts/stops (immersive) — the shell hides its
  /// brand header while the camera is actively decoding frames.
  final ValueChanged<bool>? onImmersiveChanged;

  @override
  State<ReceiveView> createState() => _ReceiveViewState();
}

class _ReceiveViewState extends State<ReceiveView> with RestorationMixin {
  bool get _linux => widget.linuxOnly ?? !Platform.isAndroid;
  late final CameraService _camera =
      widget.cameraService ?? PluginCameraService();
  late final Saver _saver = widget.saver ?? Saver();

  /// Session state lives in the controller so it survives this State being
  /// disposed (tab switch, 600dp breakpoint rebuild) and can be re-seeded
  /// after process death; the view keeps only the transient decode machinery
  /// below (camera, stats, FrameBuffer, reassembler).
  late final ReceiveSessionController _receiveController;
  bool _ownsController = false;
  bool _restoreApplied = false;

  // Process-death restoration: phase + saved-file metadata (SaveResult name,
  // method, uri) suffice to bring the saved card back — the received bytes
  // are not restorable and never re-enter the controller after a restart.
  final RestorableStringN _restorablePhase = RestorableStringN(null);
  final RestorableStringN _restorableName = RestorableStringN(null);
  final RestorableStringN _restorableMethod = RestorableStringN(null);
  final RestorableStringN _restorableUri = RestorableStringN(null);

  @override
  String get restorationId => 'receive';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_restorablePhase, 'phase');
    registerForRestoration(_restorableName, 'saved_name');
    registerForRestoration(_restorableMethod, 'saved_method');
    registerForRestoration(_restorableUri, 'saved_uri');
  }

  @override
  void initState() {
    super.initState();
    _receiveController = widget.receiveController ?? ReceiveSessionController();
    _ownsController = widget.receiveController == null;
    // A recreated State keeps the completed session; any leftover mid-scan
    // phase is meaningless without the camera, so only saved survives.
    if (_receiveController.phase != ReceivePhase.saved) {
      _receiveController.reset();
    }
    _receiveController.addListener(_onReceiveChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // restoreState has now restored the restorable properties; push the
    // restored saved-file metadata into the controller exactly once.
    if (!_restoreApplied) {
      _restoreApplied = true;
      _applyRestoredState();
    }
  }

  /// After process death, rehydrate the completed session from the restored
  /// metadata so the saved card reappears. A live completed session (the
  /// controller already saved, e.g. a tab switch) wins — it still carries the
  /// full result for the preview, which restoration data cannot.
  void _applyRestoredState() {
    if (_receiveController.phase == ReceivePhase.saved) return;
    final phase = _restorablePhase.value;
    final name = _restorableName.value;
    if (phase != ReceivePhase.saved.name || name == null) return;
    final method = SaveMethod.values.asNameMap()[_restorableMethod.value] ??
        SaveMethod.mediaStore;
    _receiveController.setSaved(
      SaveResult(name: name, method: method, uri: _restorableUri.value),
    );
  }

  /// Controller -> view: reflect every session transition in the tree and keep
  /// the restorable phase + saved metadata in sync for process-death restore.
  void _onReceiveChanged() {
    _restorablePhase.value = _receiveController.phase.name;
    _restorableName.value = _receiveController.saved?.name;
    _restorableMethod.value = _receiveController.saved?.method.name;
    _restorableUri.value = _receiveController.saved?.uri;
    setState(() {});
  }

  ReceivePhase get _phase => _receiveController.phase;
  ReassemblyResult? get _result => _receiveController.result;
  SaveResult? get _saved => _receiveController.saved;
  bool get _verified => _receiveController.verified;
  String? get _error => _receiveController.error;

  ReceiverStats _stats = ReceiverStats.empty();

  final FrameBuffer _buffer = FrameBuffer();
  FeedState _feedState = const FeedState(started: false, fedEsi: <int>{});
  Reassembler? _reassembler;
  String? _sid;
  int? _mtu;
  FrameDecoder? _decoder;
  bool _decoding =
      false; // in-flight guard: skip frames while one is processing
  bool _torch = false;
  double _zoom = 1.0;
  Stopwatch? _clock;
  int _window = 0;
  int _lastEmit = 0;
  Future<void> _queue = Future<void>.value();

  @override
  Widget build(BuildContext context) => _linux
      ? _card(
          context,
          Icons.smartphone,
          'Receive on your phone',
          'Open this app on Android and scan — this desktop build is '
              'send-only.',
        )
      : switch (_phase) {
          ReceivePhase.idle => _card(
            context,
            Icons.qr_code_scanner,
            'Scan a broadcast',
            "Point your camera at the sender's screen to receive a file. "
                'Everything happens on device — no network required.',
            action: FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Start scanning'),
            ),
            trailing: widget.onExit == null
                ? null
                : TextButton(
                    onPressed: widget.onExit,
                    child: const Text('Back'),
                  ),
          ),
          ReceivePhase.starting => const Center(child: CircularProgressIndicator()),
          ReceivePhase.saving => _card(
            context,
            Icons.download,
            'Saving…',
            'Saving ${_result?.filename ?? 'file'}…',
          ),
          ReceivePhase.saved => _savedCard(context),
          ReceivePhase.error => _card(
            context,
            Icons.error_outline,
            'Could not scan',
            _error ?? 'Something went wrong.',
            action: FilledButton(
              onPressed: _start,
              child: const Text('Try again'),
            ),
          ),
          ReceivePhase.scanning => _scanning(context),
        };

  // ---------------------------------------------------------------- flow

  Future<void> _start() async {
    _reset();
    _decoder = widget.frameDecoder ?? MlKitFrameDecoder();
    // Scanning precedes camera start so frames arriving during start() are
    // processed (mirrors the PWA's status order).
    _receiveController.setScanning();
    widget.onImmersiveChanged?.call(true);
    try {
      await _camera.start(_frame);
      _emit();
    } catch (e) {
      _fail('Could not start the camera: $e');
    }
  }

  Future<void> _restart() async {
    await _camera.stop();
    _releaseDecoder();
    _reset();
    setState(() => _stats = ReceiverStats.empty());
    widget.onImmersiveChanged?.call(false);
  }

  /// Disposes the decoder only when the view created it (an injected decoder
  /// is owned by the caller — e.g. a test shared across runs).
  void _releaseDecoder() {
    if (widget.frameDecoder == null) _decoder?.dispose();
    _decoder = null;
  }

  void _reset() {
    _buffer.reset();
    _feedState = const FeedState(started: false, fedEsi: <int>{});
    _reassembler?.reset();
    _reassembler = null;
    _sid = null;
    _mtu = null;
    _receiveController.reset();
    _clock = Stopwatch()..start();
    _lastEmit = 0;
    _window = 0;
  }

  void _frame(CameraImage image, int rotationDegrees) {
    final decoder = _decoder;
    if (decoder == null || _decoding) return; // in-flight guard
    _decoding = true;
    final stopwatch = Stopwatch()..start();
    unawaited(
      decoder
          .decode(image, rotationDegrees: rotationDegrees)
          .then((rs) {
            _decoding = false;
            _diagnose(decoder, stopwatch.elapsed);
            if (!mounted) return;
            // Decodes serialize through [_queue], exactly like the PWA's
            // feedQueue, so feed order is preserved and start()/feedMore() never
            // race.
            _queue = _queue.then((_) => _decoded(rs)).catchError((Object e) {
              if (mounted && _phase == ReceivePhase.scanning) _fail('$e');
            });
          })
          .catchError((Object e) {
            _decoding = false;
            if (mounted && _phase == ReceivePhase.scanning) {
              _fail('Decode failed: $e');
            }
          }),
    );
  }

  /// Decode-path diagnostic: logs when a frame decode was slow (>100 ms,
  /// blowing the ~66 ms frame budget) or the zxing pool had to carry it
  /// (ML Kit broken on this device) — the two signals that explain a
  /// throughput drop.
  void _diagnose(FrameDecoder decoder, Duration duration) {
    if (decoder is! MlKitFrameDecoder) return;
    final timing = decoder.lastTiming;
    if (timing == null) return;
    if (timing.path == MlKitDecodePath.zxing || duration.inMilliseconds > 100) {
      debugPrint('decode: ${timing.path.name} ${duration.inMilliseconds}ms');
    }
  }

  Future<void> _decoded(List<DecodeResult> rs) async {
    if (!mounted || _phase != ReceivePhase.scanning || _result != null) return;
    if (rs.isNotEmpty) _window++;
    for (final r in rs) {
      final bytes = r.bytes;
      if (bytes == null) continue;
      final feed = _buffer.feed(bytes);
      if (feed.isNewSession) {
        _reassembler?.reset();
        _reassembler = null;
        _sid = null;
        _mtu = null;
        _feedState = const FeedState(started: false, fedEsi: <int>{});
      }
      await _route(feed);
      final ra = _reassembler;
      if (ra != null && ra.isComplete) {
        await _complete();
        return;
      }
    }
    _emit();
  }

  /// Mirrors core `handleFeedResult`: once metadata is known, hand every
  /// not-yet-fed buffered symbol to start() (first batch) or feedMore().
  Future<void> _route(FeedResult feed) async {
    final meta = _buffer.metadata;
    if (feed.status != FeedStatus.ok || meta == null) return;
    final syms = _buffer.symbols();
    final esi = _buffer.symbolEsiSet().toList()..sort();
    final toFeed = <Uint8List>[];
    for (var i = 0; i < esi.length; i++) {
      if (!_feedState.fedEsi.contains(esi[i])) toFeed.add(syms[i]);
    }
    if (toFeed.isEmpty) return;
    final ra = _ensure();
    if (ra == null) return;
    if (_feedState.started) {
      ra.feedMore(toFeed, _buffer.symbolEsiSet());
    } else {
      await ra.start(meta, toFeed, _buffer.symbolEsiSet());
    }
    _feedState = FeedState(
      started: true,
      fedEsi: Set<int>.of(_feedState.fedEsi)..addAll(esi),
    );
  }

  Reassembler? _ensure() {
    final meta = _buffer.metadata;
    if (meta == null) return null;
    if (_reassembler == null || _sid != meta.sessionId || _mtu != meta.mtu) {
      _reassembler = Reassembler(mtu: meta.mtu, factory: RustRaptorqFactory());
      _sid = meta.sessionId;
      _mtu = meta.mtu;
    }
    return _reassembler;
  }

  Future<void> _complete() async {
    final ra = _reassembler;
    if (ra == null || _result != null) return;
    ReassemblyResult? res;
    try {
      res = await ra.finish();
    } catch (_) {
      return; // not complete / hash mismatch — keep scanning
    }
    if (!mounted) return;
    _receiveController.setVerified(res);
    setState(() => _stats = _statsNow());
    await _camera.stop();
  }

  void _emit() {
    if (!mounted || _phase != ReceivePhase.scanning) return;
    setState(() => _stats = _statsNow());
  }

  ReceiverStats _statsNow() {
    final now = _clock?.elapsedMilliseconds ?? 0;
    final win = math.max(1, now - _lastEmit);
    _lastEmit = now;
    final meta = _buffer.metadata;
    final b = updateStats(
      _stats,
      StatsSample((
        _buffer.uniqueSymbolCount,
        _buffer.k,
        _buffer.totalFramesSeen,
        _buffer.droppedCount,
        now,
        meta?.symbolSize,
        _window,
        win,
      )),
    );
    _window = 0;
    final st = _result != null
        ? ReceiverStatus.complete
        : _buffer.k != null
        ? ReceiverStatus.transferring
        : ReceiverStatus.scanning;
    return ReceiverStats((
      st,
      b.unique,
      b.k,
      b.totalFramesSeen,
      b.droppedCount,
      b.decodeRate,
      b.bytesPerSecond,
      b.etaSeconds,
      b.progress,
      meta != null,
      meta?.filename,
      _verified ? true : null,
    ));
  }

  Future<void> _save() async {
    final r = _result;
    if (r == null) return;
    _receiveController.setSaving();
    widget.onImmersiveChanged?.call(false);
    try {
      final saved = await _saver.saveFile(
        bytes: r.bytes,
        filename: r.filename,
        mime: r.mime,
      );
      if (!mounted) return;
      _receiveController.setSaved(saved);
    } catch (e) {
      if (!mounted) return;
      // Back to the save card (scanning) with the failure banner so the user
      // can retry saving without rescanning.
      _receiveController.setScanning(error: '$e');
      widget.onImmersiveChanged?.call(true);
    }
  }

  Future<void> _open() async {
    final s = _saved;
    if (s == null) return;
    try {
      await _saver.openSavedFile(s);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open the file: $e')));
    }
  }

  void _fail(String m) {
    if (!mounted) return;
    _receiveController.setError(m);
    widget.onImmersiveChanged?.call(false);
    _camera.stop();
  }

  @override
  void dispose() {
    widget.onImmersiveChanged?.call(false);
    _receiveController.removeListener(_onReceiveChanged);
    if (_ownsController) _receiveController.dispose();
    _releaseDecoder();
    _camera.stop();
    super.dispose();
  }

  // ------------------------------------------------------------------ UI

  Widget _card(
    BuildContext c,
    IconData icon,
    String title,
    String body, {
    Widget? bodyWidget,
    Widget? action,
    Widget? trailing,
  }) {
    final t = Theme.of(c);
    return Center(
      // shrinkWrap keeps tall screens identical (the viewport hugs the card
      // and Center still centers it), while short screens scroll so the
      // trailing action (e.g. 'Scan another') stays reachable instead of
      // overflowing below the fold.
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 48, color: t.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(title, style: t.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    body,
                    style: t.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  ?bodyWidget,
                  if (action != null) ...[const SizedBox(height: 16), action],
                  if (trailing != null) ...[const SizedBox(height: 8), trailing],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _savedCard(BuildContext c) {
    final r = _result;
    final s = _saved;
    return _card(
      c,
      Icons.check_circle_outline,
      'File saved',
      'Saved as ${s?.name ?? 'file'}',
      bodyWidget: r != null && s != null
          ? Padding(
              padding: const EdgeInsets.only(top: 16),
              child: SavedFilePreview(result: r, saved: s),
            )
          : null,
      action: FilledButton.icon(
        onPressed: _open,
        icon: const Icon(Icons.open_in_new),
        label: const Text('Open file'),
      ),
      trailing: TextButton(
        onPressed: _restart,
        child: const Text('Scan another'),
      ),
    );
  }

  Widget _scanning(BuildContext c) {
    final r = _result;
    return Stack(
      children: [
        // Live camera preview when available; the espresso backdrop otherwise
        // (fake services, still-initializing controller).
        Positioned.fill(
          child:
              _camera.buildPreview() ??
              const ColoredBox(color: Color(0xFF101316)),
        ),
        if (_error != null)
          Positioned(top: 8, left: 8, right: 8, child: _banner(c, _error!)),
        if (r != null)
          Positioned(left: 24, right: 24, bottom: 128, child: _saveCard(c, r)),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.center,
              child: _cameraControls(c),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: _StatsOverlay(_stats),
        ),
      ],
    );
  }

  /// Compact camera controls: flip front/back, torch, and zoom in/out.
  Widget _cameraControls(BuildContext c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xCC101316),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const Key('flip_camera'),
            onPressed: _flipCamera,
            icon: const Icon(Icons.cameraswitch_outlined, size: 20),
            color: Colors.white,
            tooltip: 'Switch camera',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const Key('toggle_torch'),
            onPressed: _toggleTorch,
            icon: Icon(
              _torch ? Icons.flash_on : Icons.flash_off,
              size: 20,
              color: _torch ? const Color(0xFFFFC46B) : Colors.white,
            ),
            tooltip: 'Torch',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const Key('zoom_out'),
            onPressed: _zoomOut,
            icon: const Icon(Icons.zoom_out, size: 20),
            color: Colors.white,
            tooltip: 'Zoom out',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const Key('zoom_in'),
            onPressed: _zoomIn,
            icon: const Icon(Icons.zoom_in, size: 20),
            color: Colors.white,
            tooltip: 'Zoom in',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Future<void> _flipCamera() async {
    await _camera.flipCamera();
  }

  Future<void> _toggleTorch() async {
    final next = !_torch;
    setState(() => _torch = next);
    await _camera.setTorch(next);
  }

  Future<void> _zoomIn() async {
    final next = (_zoom + 0.5).clamp(1.0, 8.0);
    setState(() => _zoom = next);
    await _camera.setZoom(next);
  }

  Future<void> _zoomOut() async {
    final next = (_zoom - 0.5).clamp(1.0, 8.0);
    setState(() => _zoom = next);
    await _camera.setZoom(next);
  }

  Widget _saveCard(BuildContext c, ReassemblyResult r) {
    final t = Theme.of(c);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '✓ Verified — file complete',
              style: t.textTheme.titleMedium?.copyWith(
                color: t.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              r.filename,
              style: t.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.download),
              label: const Text('Save file'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _banner(BuildContext c, String m) {
    final t = Theme.of(c);
    return Material(
      color: t.colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          m,
          style: t.textTheme.bodySmall?.copyWith(
            color: t.colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}

/// Compact live-stats overlay (port of the PWA's StatusOverlay): status chip,
/// SHA-256 badge, progress bar, count/file, and the decode/speed/ETA/dropped
/// grid.
class _StatsOverlay extends StatelessWidget {
  const _StatsOverlay(this.s);

  final ReceiverStats s;

  static String _eta(double? sec) {
    if (sec == null) return '—';
    final tot = math.max(0, sec.round());
    if (tot < 60) return '${tot}s';
    final m = tot ~/ 60;
    final r = tot % 60;
    return r == 0 ? '${m}m' : '${m}m ${r}s';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const dim = Color(0xFF9AA4B2);
    return Material(
      color: const Color(0xE6111519),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  s.status.name.toUpperCase(),
                  style: t.textTheme.labelSmall?.copyWith(color: dim),
                ),
                const Spacer(),
                if (s.verified == true)
                  Text(
                    '✓ VERIFIED (SHA-256)',
                    style: t.textTheme.labelSmall?.copyWith(
                      color: const Color(0xFF4ADE80),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (s.verified == false)
                  Text(
                    'HASH MISMATCH',
                    style: t.textTheme.labelSmall?.copyWith(
                      color: const Color(0xFFFCA5A5),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: s.progress.clamp(0.0, 1.0),
              minHeight: 6,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${s.unique} / ${s.k ?? '…'}',
                  style: t.textTheme.bodyMedium,
                ),
                const Spacer(),
                if (s.fileName != null)
                  Flexible(
                    child: Text(
                      s.fileName!,
                      style: t.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _cell(t, 'Decode', '${s.decodeRate.toStringAsFixed(1)} fps'),
                _cell(
                  t,
                  'Speed',
                  '${(s.bytesPerSecond / 1024).toStringAsFixed(1)} KB/s',
                ),
                _cell(t, 'ETA', _eta(s.etaSeconds)),
                _cell(t, 'Dropped', '${s.droppedCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget _cell(ThemeData t, String l, String v) => Column(
    children: [
      Text(
        l.toUpperCase(),
        style: t.textTheme.labelSmall?.copyWith(color: const Color(0xFF9AA4B2)),
      ),
      const SizedBox(height: 2),
      Text(v, style: t.textTheme.bodyMedium),
    ],
  );
}
