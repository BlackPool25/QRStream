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
import 'package:qr_data_transfer/receiver/camera_service.dart';
import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/receiver/decode_pool.dart';
import 'package:qr_transfer_core/receiver/frames.dart' show FeedResult, FeedStatus, FrameBuffer;
import 'package:qr_transfer_core/receiver/reassembler.dart' show Reassembler, ReassemblyResult;
import 'package:qr_transfer_core/receiver/stats.dart' show FeedState, ReceiverStats, ReceiverStatus, StatsSample, updateStats;

enum _Phase { idle, starting, scanning, saving, saved, error }

class ReceiveView extends StatefulWidget {
  const ReceiveView({
    super.key,
    this.linuxOnly,
    this.cameraService,
    this.saver,
    this.decodePool,
    this.dylibPath,
    this.onExit,
  });

  /// Overrides [Platform.isLinux] so tests can pin either mode.
  final bool? linuxOnly;
  final CameraService? cameraService;
  final Saver? saver;
  final DecodePool? decodePool;
  final String? dylibPath;
  final VoidCallback? onExit;

  @override
  State<ReceiveView> createState() => _ReceiveViewState();
}

class _ReceiveViewState extends State<ReceiveView> {
  bool get _linux => widget.linuxOnly ?? Platform.isLinux;
  late final CameraService _camera =
      widget.cameraService ?? PluginCameraService();
  late final Saver _saver = widget.saver ?? Saver();

  _Phase _phase = _Phase.idle;
  ReceiverStats _stats = ReceiverStats.empty();
  ReassemblyResult? _result;
  SaveResult? _saved;
  String? _error;
  bool _verified = false;

  final FrameBuffer _buffer = FrameBuffer();
  FeedState _feedState = const FeedState(started: false, fedEsi: <int>{});
  Reassembler? _reassembler;
  String? _sid;
  int? _mtu;
  DecodePool? _pool;
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
          _Phase.idle => _card(
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
                  : TextButton(onPressed: widget.onExit, child: const Text('Back')),
            ),
          _Phase.starting => const Center(child: CircularProgressIndicator()),
          _Phase.saving => _card(
              context,
              Icons.download,
              'Saving…',
              'Saving ${_result?.filename ?? 'file'}…',
            ),
          _Phase.saved => _savedCard(context),
          _Phase.error => _card(
              context,
              Icons.error_outline,
              'Could not scan',
              _error ?? 'Something went wrong.',
              action: FilledButton(
                onPressed: _start,
                child: const Text('Try again'),
              ),
            ),
          _Phase.scanning => _scanning(context),
        };

  // ---------------------------------------------------------------- flow

  Future<void> _start() async {
    _reset();
    _pool = widget.decodePool ?? DecodePool();
    // Scanning precedes camera start so frames arriving during start() are
    // processed (mirrors the PWA's status order).
    setState(() {
      _phase = _Phase.scanning;
      _error = null;
    });
    try {
      await _camera.start(_frame);
      _emit();
    } catch (e) {
      _fail('Could not start the camera: $e');
    }
  }

  Future<void> _restart() async {
    await _camera.stop();
    _releasePool();
    _reset();
    setState(() {
      _phase = _Phase.idle;
      _stats = ReceiverStats.empty();
    });
  }

  /// Disposes the decode pool only when the view created it (an injected
  /// pool is owned by the caller — e.g. a test shared across runs).
  void _releasePool() {
    if (widget.decodePool == null) _pool?.dispose();
    _pool = null;
  }

  void _reset() {
    _buffer.reset();
    _feedState = const FeedState(started: false, fedEsi: <int>{});
    _reassembler?.reset();
    _reassembler = null;
    _sid = null;
    _mtu = null;
    _verified = false;
    _result = null;
    _saved = null;
    _clock = Stopwatch()..start();
    _lastEmit = 0;
    _window = 0;
  }

  void _frame(Uint8List rgb, int w, int h) {
    final pool = _pool;
    if (pool == null) return;
    // Decodes serialize through [_queue], exactly like the PWA's feedQueue,
    // so feed order is preserved and start()/feedMore() never race.
    unawaited(
      pool
          .decode(rgb, w, h)
          .then((rs) {
            _queue = _queue
                .then((_) => _decoded(rs))
                .catchError((Object e) {
                  if (mounted && _phase == _Phase.scanning) _fail('$e');
                });
          })
          .catchError((Object e) {
            if (mounted && _phase == _Phase.scanning) _fail('Decode failed: $e');
          }),
    );
  }

  Future<void> _decoded(List<DecodeResult> rs) async {
    if (!mounted || _phase != _Phase.scanning || _result != null) return;
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
        _verified = false;
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
    setState(() {
      _verified = true;
      _result = res;
      _stats = _statsNow();
    });
    await _camera.stop();
  }

  void _emit() {
    if (!mounted || _phase != _Phase.scanning) return;
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
    setState(() => _phase = _Phase.saving);
    try {
      final saved = await _saver.saveFile(
        bytes: r.bytes,
        filename: r.filename,
        mime: r.mime,
      );
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _phase = _Phase.saved;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _phase = _Phase.scanning;
      });
    }
  }

  Future<void> _open() async {
    final s = _saved;
    if (s != null) await _saver.openSavedFile(s);
  }

  void _fail(String m) {
    if (!mounted) return;
    setState(() {
      _error = m;
      _phase = _Phase.error;
    });
    _camera.stop();
  }

  @override
  void dispose() {
    _releasePool();
    _camera.stop();
    super.dispose();
  }

  // ------------------------------------------------------------------ UI

  Widget _card(
    BuildContext c,
    IconData icon,
    String title,
    String body, {
    Widget? action,
    Widget? trailing,
  }) {
    final t = Theme.of(c);
    return Center(
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
                Text(body, style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
                if (action != null) ...[const SizedBox(height: 16), action],
                if (trailing != null) ...[const SizedBox(height: 8), trailing],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _savedCard(BuildContext c) => _card(
        c,
        Icons.check_circle_outline,
        'File saved',
        'Saved as ${_saved?.name ?? 'file'}',
        action: FilledButton.icon(
          onPressed: _open,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open file'),
        ),
        trailing: TextButton(onPressed: _restart, child: const Text('Scan another')),
      );

  Widget _scanning(BuildContext c) {
    final r = _result;
    return Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Color(0xFF101316))),
        if (_error != null)
          Positioned(top: 8, left: 8, right: 8, child: _banner(c, _error!)),
        if (r != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: 128,
            child: _saveCard(c, r),
          ),
        Positioned(left: 12, right: 12, bottom: 12, child: _StatsOverlay(_stats)),
      ],
    );
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
            Text(r.filename, style: t.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
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
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onErrorContainer),
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
                Text(s.status.name.toUpperCase(), style: t.textTheme.labelSmall?.copyWith(color: dim)),
                const Spacer(),
                if (s.verified == true)
                  Text('✓ VERIFIED (SHA-256)', style: t.textTheme.labelSmall?.copyWith(color: const Color(0xFF4ADE80), fontWeight: FontWeight.w700)),
                if (s.verified == false)
                  Text('HASH MISMATCH', style: t.textTheme.labelSmall?.copyWith(color: const Color(0xFFFCA5A5))),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: s.progress.clamp(0.0, 1.0), minHeight: 6),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('${s.unique} / ${s.k ?? '…'}', style: t.textTheme.bodyMedium),
                const Spacer(),
                if (s.fileName != null)
                  Flexible(child: Text(s.fileName!, style: t.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _cell(t, 'Decode', '${s.decodeRate.toStringAsFixed(1)} fps'),
                _cell(t, 'Speed', '${(s.bytesPerSecond / 1024).toStringAsFixed(1)} KB/s'),
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
          Text(l.toUpperCase(), style: t.textTheme.labelSmall?.copyWith(color: const Color(0xFF9AA4B2))),
          const SizedBox(height: 2),
          Text(v, style: t.textTheme.bodyMedium),
        ],
      );
}
