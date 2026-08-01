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
  const AppShell({super.key, this.linuxOnly});

  final bool? linuxOnly;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final bool _linuxOnly = widget.linuxOnly ?? Platform.isLinux;

  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final body = _buildBody();
        final destinations = _Destination.values;
        if (constraints.maxWidth < _compactBreakpoint) {
          return Scaffold(
            body: body,
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final d in destinations)
                  NavigationDestination(icon: Icon(d.icon), label: d.label),
              ],
            ),
          );
        }
        return Scaffold(
          body: Row(
            children: [
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
              ),
              Expanded(child: body),
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
        return const SendView();
      case _Destination.receive:
        return _linuxOnly ? const _LinuxReceiveCard() : const ReceiveView();
      case _Destination.settings:
        return const SettingsView();
    }
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
