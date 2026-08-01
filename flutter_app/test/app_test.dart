// App-entry tests: QrTransferApp builds, applies the research-locked brown
// theme, and lands on the Send destination of the adaptive shell. The counter
// demo is gone (no "You have pushed" text anywhere).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_data_transfer/app.dart';
import 'package:qr_data_transfer/theme/app_theme.dart';
import 'package:qr_data_transfer/theme/app_theme_constants.dart';
import 'package:qr_data_transfer/ui/send_view.dart';

void main() {
  testWidgets('QrTransferApp builds with the brown theme and Send default',
      (tester) async {
    await tester.pumpWidget(const QrTransferApp());
    await tester.pumpAndSettle();

    // The shell's first destination is Send.
    expect(find.byType(SendView), findsOneWidget);
    // No counter-demo remnants.
    expect(find.textContaining('You have pushed'), findsNothing);
    expect(find.textContaining('Flutter Demo'), findsNothing);
  });

  testWidgets('light theme primary is the research-locked deep cocoa',
      (tester) async {
    await tester.pumpWidget(const QrTransferApp());
    await tester.pumpAndSettle();

    // Read the theme from a widget INSIDE the MaterialApp's Theme (the
    // MaterialApp element itself sits above its own Theme, so Theme.of on it
    // would fall back to the default light scheme).
    final theme = Theme.of(tester.element(find.byType(SendView)));
    expect(theme.colorScheme.primary, lightPrimary);
    expect(theme.colorScheme.surface, lightSurface);
  });

  testWidgets('dark theme primary is the research-locked warm tan',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.colorScheme.primary, darkPrimary);
    expect(theme.colorScheme.surface, darkSurface);
  });
}
