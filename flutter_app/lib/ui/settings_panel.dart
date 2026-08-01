/// Settings view placeholder.
///
/// Stub for the settings task (T5.5): the shell only needs a `SettingsView`
/// widget to host in its navigation frame. The settings task replaces this
/// file's contents.
library;

import 'package:flutter/material.dart';

/// Hosts transfer settings — display fps, bytes per tile, tile layout.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.settings, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('Settings', style: theme.textTheme.headlineSmall),
        ],
      ),
    );
  }
}
