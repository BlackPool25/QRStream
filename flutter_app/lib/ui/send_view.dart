/// Send view placeholder.
///
/// Stub for the send task (T5.3): the shell only needs a `SendView` widget to
/// host in its navigation frame. The send task replaces this file's contents.
library;

import 'package:flutter/material.dart';

/// Hosts the sender flow — file pick, prepare and broadcast.
class SendView extends StatelessWidget {
  const SendView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.qr_code_2, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('Send', style: theme.textTheme.headlineSmall),
        ],
      ),
    );
  }
}
