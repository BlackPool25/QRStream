import 'package:flutter/material.dart';

import 'shell/app_shell.dart';
import 'theme/app_theme.dart';

/// Root widget: brown Material 3 theme (light + dark) hosting the adaptive
/// navigation shell. The shell renders Send / Receive / Settings with a
/// bottom NavigationBar on phones and a NavigationRail on desktop, and Linux
/// is send-only (AppShell handles that).
class QrTransferApp extends StatelessWidget {
  const QrTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QR Data Transfer',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}
