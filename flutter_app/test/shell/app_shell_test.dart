// Widget tests for the adaptive app shell: phone vs desktop chrome and the
// Linux send-only Receive destination. Every test pins [linuxOnly] explicitly
// so the host platform never leaks into the assertions.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_data_transfer/shell/app_shell.dart';
import 'package:qr_data_transfer/ui/receive_view.dart';
import 'package:qr_data_transfer/ui/send_view.dart';
import 'package:qr_data_transfer/ui/settings_panel.dart';

void main() {
  Future<void> pumpShell(
    WidgetTester tester, {
    required bool linuxOnly,
    required double width,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AppShell(linuxOnly: linuxOnly)),
    );
  }

  testWidgets('phone width: bottom NavigationBar, no rail, Send default',
      (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 390);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(SendView), findsOneWidget);
  });

  testWidgets('phone width: tapping Receive swaps in ReceiveView',
      (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 390);

    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();

    expect(find.byType(ReceiveView), findsOneWidget);
    expect(find.byType(SendView), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('desktop width: extended NavigationRail, three destinations',
      (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 1200);

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    // Extended rail renders all three labels; the rail owns 3 destinations.
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations.length, 3);
    for (final label in ['Send', 'Receive', 'Settings']) {
      expect(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    expect(find.byType(SendView), findsOneWidget);
  });

  testWidgets('desktop width: tapping Receive swaps in ReceiveView',
      (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 1200);

    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();

    expect(find.byType(ReceiveView), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('desktop width: tapping Settings swaps in SettingsView',
      (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 1200);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsView), findsOneWidget);
  });

  testWidgets('Linux send-only: Receive shows the phone card, not the camera',
      (tester) async {
    await pumpShell(tester, linuxOnly: true, width: 1200);

    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();

    expect(find.text('Receive on your phone'), findsOneWidget);
    expect(
      find.textContaining('Open this app on Android and scan'),
      findsOneWidget,
    );
    expect(find.byType(ReceiveView), findsNothing);
  });

  testWidgets(
      'Linux send-only on phone: card renders, Settings still available',
      (tester) async {
    await pumpShell(tester, linuxOnly: true, width: 390);

    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();

    expect(find.text('Receive on your phone'), findsOneWidget);
    expect(find.byType(ReceiveView), findsNothing);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsView), findsOneWidget);
  });

  testWidgets('Send is the default destination on desktop', (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 1200);

    expect(find.byType(SendView), findsOneWidget);
    expect(find.byType(ReceiveView), findsNothing);
    expect(find.byType(SettingsView), findsNothing);
  });
}
