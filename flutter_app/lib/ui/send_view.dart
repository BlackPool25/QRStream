import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mime/mime.dart';
import 'package:qr_transfer_core/codec/fountain/interface.dart';
import 'package:qr_transfer_core/codec/raptorq_bridge.dart';
import 'package:qr_transfer_core/protocol/constants.dart' as qrc;
import 'package:qr_transfer_core/sender/pacing.dart' as qrp;
import 'package:qr_transfer_core/sender/pipeline.dart';
import 'package:qr_transfer_core/sender/settings.dart';

import 'broadcast_view.dart';
import 'settings_panel.dart';
import '../settings/settings_store.dart';

/// Result of picking a file.
typedef PickedFile = ({String name, String mime, Uint8List bytes});

/// File-picker abstraction so widget tests can inject a fake without
/// touching platform channels.
typedef FilePicker = Future<PickedFile?> Function();

/// Sender flow: pick file → prepare → settings → broadcast.
///
/// Caching + back-navigation contract (user requirement):
/// * the prepared transfer is cached in this widget's state, so going back
///   from the settings step or from a running broadcast does NOT re-chunk /
///   re-compress / re-encode the file;
/// * changing display fps / layout / high-refresh only updates the estimate,
///   never re-prepares (only a bytes-per-tile change re-encodes, because it
///   changes the mtu and therefore the chunking);
/// * stopping a broadcast returns to the settings step with the cached
///   transfer still in hand ("Different file" clears the cache).
class SendView extends StatefulWidget {
  const SendView({
    super.key,
    this.filePicker,
    this.factory,
    this.refreshRateProbe,
    this.settingsStore,
    this.onImmersiveChanged,
  });

  /// Overridable in tests; defaults to a real file selector.
  final FilePicker? filePicker;

  /// Overridable in tests; defaults to the Rust FFI factory.
  final FountainFactory? factory;

  /// Overridable in tests; defaults to a real SchedulerBinding frame probe.
  /// Returns the detected refresh rate (60/90/120).
  final Future<int> Function()? refreshRateProbe;

  /// Overridable in tests; defaults to the real [SettingsStore]. Its
  /// persisted defaults pre-fill the settings when a file is first picked.
  final SettingsStore? settingsStore;

  /// Notified when the send flow enters/leaves the preparing (immersive)
  /// phase — the shell hides its brand header while a transfer is being
  /// compressed and encoded.
  final ValueChanged<bool>? onImmersiveChanged;

  @override
  State<SendView> createState() => _SendViewState();
}

enum _SendPhase { idle, preparing, settings }

class _SendViewState extends State<SendView> {
  _SendPhase _phase = _SendPhase.idle;
  qrc.TransferSettings _settings = defaultTransferSettings;
  PreparedTransfer? _prepared;
  int? _refreshRate; // null while detecting
  qrc.LayoutId? _suggested;
  int _prepareSeq = 0; // guards against a stale async prepare landing late
  PickedFile? _lastPicked;
  String? _error;
  Future<qrc.TransferSettings>? _defaultsFuture;

  FountainFactory get _factory => widget.factory ?? RustRaptorqFactory();

  @override
  void initState() {
    super.initState();
    // Load the persisted defaults up front so the settings step is pre-filled
    // even when the user picks a file immediately.
    _defaultsFuture = (widget.settingsStore ?? SettingsStore()).load();
    // Refresh rate is measured lazily on entering the settings phase, not on
    // mount (avoids a frame-probe running behind the idle/other screens).
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is only legal from didChangeDependencies/build, not initState.
    _suggested ??= _suggestLayout();
  }

  void _detectRefreshRate() async {
    final probe = widget.refreshRateProbe ?? _measureRefreshRate;
    final rate = await probe();
    if (mounted) setState(() => _refreshRate = rate);
  }

  qrc.LayoutId _suggestLayout() {
    final size = MediaQuery.sizeOf(context);
    return qrp.suggestLayout(size.width.round(), size.height.round());
  }

  Future<void> _pickAndPrepare() async {
    // Pre-fill from the persisted defaults before picking so the file is
    // prepared with the user's saved settings even if they pick immediately.
    final defaultsFuture =
        _defaultsFuture ?? Future.value(defaultTransferSettings);
    final defaults = await defaultsFuture;
    if (!mounted) return;
    _settings = defaults;
    final picked = await (widget.filePicker ?? _realFilePicker)();
    if (picked == null || !mounted) return;
    setState(() {
      _lastPicked = picked;
      _phase = _SendPhase.preparing;
    });
    widget.onImmersiveChanged?.call(true);
    await _prepare(picked, _settings);
  }

  Future<void> _prepare(PickedFile picked, qrc.TransferSettings settings) async {
    final seq = ++_prepareSeq;
    try {
      final prepared = await prepareTransfer(
        file: picked.bytes,
        filename: picked.name,
        mime: picked.mime,
        settings: settings,
        factory: _factory,
      );
      if (!mounted || seq != _prepareSeq) return; // stale prepare — discard
      setState(() {
        _prepared = prepared;
        _settings = settings;
        _phase = _SendPhase.settings;
      });
      widget.onImmersiveChanged?.call(false);
      // Measure the display refresh rate once, when the settings step is shown.
      if (_refreshRate == null) {
        _detectRefreshRate();
      }
    } catch (e) {
      if (!mounted || seq != _prepareSeq) return;
      setState(() {
        _error = e.toString();
        _phase = _SendPhase.idle;
      });
      widget.onImmersiveChanged?.call(false);
    }
  }

  /// Only a bytes-per-tile change re-encodes (new mtu → new chunking).
  /// fps / layout / high-refresh changes just update the estimate.
  void _onSettingsChanged(qrc.TransferSettings next) {
    if (next.bytesPerTile != _settings.bytesPerTile &&
        _lastPicked != null) {
      // Keep the cached transfer visible while re-preparing the new mtu.
      setState(() => _phase = _SendPhase.preparing);
      widget.onImmersiveChanged?.call(true);
      _prepare(_lastPicked!, next);
    } else {
      setState(() => _settings = next);
    }
  }

  void _clearCache() {
    _prepareSeq++; // invalidate any in-flight prepare
    final prepared = _prepared;
    if (prepared != null) {
      prepared.encoder.dispose(); // release the native codec
    }
    setState(() {
      _prepared = null;
      _lastPicked = null;
      _phase = _SendPhase.idle;
    });
    widget.onImmersiveChanged?.call(false);
  }

  @override
  void dispose() {
    _prepareSeq++;
    _prepared?.encoder.dispose();
    widget.onImmersiveChanged?.call(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _SendPhase.idle:
        return _buildIdle(context);
      case _SendPhase.preparing:
        return _buildPreparing(context);
      case _SendPhase.settings:
        return _prepared == null
            ? _buildIdle(context)
            : SettingsPanel(
                settings: _settings,
                onChanged: _onSettingsChanged,
                compressedSize: _prepared!.info.compressedSize,
                refreshRate: _refreshRate,
                suggestedLayout: _suggested ?? qrc.LayoutId.grid4,
                onBegin: _beginBroadcast,
                onDifferentFile: _clearCache,
                fileName: _prepared!.info.filename,
                fileSize: _prepared!.info.totalSize,
              );
    }
  }

  /// Pushes the broadcast as a full-screen route so the shell chrome
  /// (NavigationBar) is hidden and Android back pops back to this settings
  /// step with the prepared-transfer cache intact (D9).
  void _beginBroadcast() {
    final prepared = _prepared;
    if (prepared == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => BroadcastView(
          prepared: prepared,
          settings: _settings,
          onStop: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
  }

  Widget _buildIdle(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_2, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('Send a file', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Broadcast a file as a QR stream. No network — the receiver '
              'scans your screen.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('pick_file'),
              onPressed: _pickAndPrepare,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose a file'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPreparing(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Preparing transfer… (compressing and encoding)'),
        ],
      ),
    );
  }
}

/// Default real file picker: uses `file_selector`'s openFile. Kept as a
/// top-level function so the widget stays testable with an injected fake.
Future<PickedFile?> _realFilePicker() async {
  try {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Any', extensions: null),
    ]);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    // Real MIME from the extension — the wire metadata and the MediaStore
    // MIME_TYPE row inherit this, so the saved file opens in file managers
    // (a hardcoded application/octet-stream makes Google Files refuse it).
    final mime = lookupMimeType(file.name) ?? 'application/octet-stream';
    return (name: file.name, mime: mime, bytes: bytes);
  } catch (_) {
    return null;
  }
}

/// Measures the display refresh rate by counting frames over ~400ms and
/// classifying (>=105→120, >=75→90, else 60). Uses a short frame callback
/// loop via SchedulerBinding; returns 60 if measurement is unavailable.
Future<int> _measureRefreshRate() async {
  try {
    final binding = SchedulerBinding.instance;
    final stopwatch = Stopwatch()..start();
    var frames = 0;
    var done = false;
    final completer = Completer<int>();
    void onFrame(Duration _) {
      if (done) return;
      frames++;
      if (stopwatch.elapsedMilliseconds >= 400) {
        done = true;
        completer.complete(
          classifyRefreshRate(
            frames: frames,
            elapsedMs: stopwatch.elapsedMilliseconds,
          ),
        );
      } else {
        binding.scheduleFrameCallback(onFrame);
      }
    }

    binding.scheduleFrameCallback(onFrame);
    return await completer.future.timeout(const Duration(seconds: 2),
        onTimeout: () {
      done = true;
      return 60;
    });
  } catch (_) {
    return 60;
  }
}
