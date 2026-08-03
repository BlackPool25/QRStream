/// Adaptive app shell — the navigation frame of the Flutter port.
///
/// Port of the PWA's mode switcher (src/ui/App.tsx): the shell hosts the
/// three destinations — Send, Receive, Settings — and adapts the chrome to
/// the surface. Narrow (phone) layouts get a bottom [NavigationBar]; wide
/// (desktop) layouts get an extended [NavigationRail]. Linux desktop is
/// send-only — the `camera` plugin is Android-only at runtime, so the
/// Receive destination renders a "receive on your phone" card that points at
/// the Android app instead of the camera view. Settings stays available.
///
/// The shell is theme-agnostic: it reads every color from [Theme.of], so it
/// renders in whatever ThemeData the app supplies (the brown app theme from
/// the theme task, wired in by the app task).
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../receiver/receive_controller.dart';
import '../ui/receive_view.dart';
import '../ui/send_view.dart';
import '../ui/settings_panel.dart';

/// Below this width the shell renders a bottom [NavigationBar].
const double _compactBreakpoint = 600;

/// At or above this width the [NavigationRail] is extended (icon + label).
const double _railExtendedBreakpoint = 1000;

/// The three destinations, in index order.
enum _Destination {
  send('Send', Icons.qr_code_2),
  receive('Receive', Icons.camera_alt),
  settings('Settings', Icons.settings);

  const _Destination(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Adaptive navigation shell. [linuxOnly] defaults to the host platform and
/// is injectable so tests (and Linux builds) can pin the send-only mode.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.linuxOnly, this.receiveController});

  final bool? linuxOnly;

  /// Injectable receive-session controller (tests pre-seed it with a completed
  /// state); when null the shell owns a fresh one for its whole lifetime.
  final ReceiveSessionController? receiveController;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final bool _linuxOnly = widget.linuxOnly ?? !Platform.isAndroid;

  /// Outlives every [ReceiveView] State, so a completed receive session
  /// survives tab switches and the 600dp breakpoint body swap.
  late final ReceiveSessionController _receiveController =
      widget.receiveController ?? ReceiveSessionController();

  int _index = 0;

  /// True while the active destination is in an immersive operation (camera
  /// scanning or transfer preparation) — the brand header hides then.
  bool _immersive = false;

  void _setImmersive(bool value) {
    if (_immersive != value) setState(() => _immersive = value);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _compactBreakpoint;
        final destinations = _Destination.values;
        final content = Column(
          children: [
            if (!_immersive) const _BrandHeader(),
            Expanded(child: _buildBody()),
          ],
        );
        return Scaffold(
          body: Row(
            children: [
              // The rail slot is ALWAYS at index 0 — NavigationRail when wide,
              // an empty placeholder when narrow — so the destination at index
              // 1 keeps the same element path across the 600dp breakpoint.
              // Rotating a phone crosses it; a stable path lets Flutter reuse
              // the existing State instead of recreating SendView/SettingsView
              // and resetting their state.
              if (wide)
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  extended: constraints.maxWidth >= _railExtendedBreakpoint,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        label: Text(d.label),
                      ),
                  ],
                )
              else
                const SizedBox.shrink(),
              Expanded(child: content),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final d in destinations)
                      NavigationDestination(icon: Icon(d.icon), label: d.label),
                  ],
                ),
        );
      },
    );
  }

  /// The body for the current destination index. Receive is send-only on
  /// Linux (see the class doc); the exhaustive switch is over the enum so a
  /// new destination fails to compile until it is handled here.
  Widget _buildBody() {
    switch (_Destination.values[_index]) {
      case _Destination.send:
        return SendView(onImmersiveChanged: _setImmersive);
      case _Destination.receive:
        return _linuxOnly
            ? const _LinuxReceiveCard()
            : ReceiveView(
                // linuxOnly mirrors the shell's override so a test-pinned
                // non-Linux shell renders the real receive flow on any host.
                linuxOnly: widget.linuxOnly,
                receiveController: _receiveController,
                onImmersiveChanged: _setImmersive,
              );
      case _Destination.settings:
        return const SettingsView();
    }
  }

  @override
  void dispose() {
    _receiveController.dispose();
    super.dispose();
  }
}

/// The QRStream brand mark: the logo chip + wordmark, shown as the shell's
/// header in normal (non-immersive) destinations.
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/logo.png',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'QRStream',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFamily: 'Fraunces',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Linux has no camera plugin, so Receive points the user at the Android app
/// with an info card instead of the camera view.
class _LinuxReceiveCard extends StatelessWidget {
  const _LinuxReceiveCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.smartphone,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text('Receive on your phone', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Open this app on Android and scan',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
