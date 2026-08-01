/// Receive view placeholder.
///
/// Stub for the receive task (T5.5): the shell only needs a `ReceiveView`
/// widget to host in its navigation frame. The receive task replaces this
/// file's contents.
library;

import 'package:flutter/material.dart';

/// Hosts the receiver flow — camera scan, decode, verify and save.
class ReceiveView extends StatelessWidget {
  const ReceiveView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.camera_alt, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('Receive', style: theme.textTheme.headlineSmall),
        ],
      ),
    );
  }
}
