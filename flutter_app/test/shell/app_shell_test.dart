// Widget tests for the adaptive app shell: phone vs desktop chrome and the
// Linux send-only Receive destination. Every test pins [linuxOnly] explicitly
// so the host platform never leaks into the assertions.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qr_data_transfer/receiver/receive_controller.dart';
import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_data_transfer/shell/app_shell.dart';
import 'package:qr_data_transfer/ui/receive_view.dart';
import 'package:qr_data_transfer/ui/send_view.dart';
import 'package:qr_data_transfer/ui/settings_panel.dart';

void main() {
  Future<void> pumpShell(
    WidgetTester tester, {
    required bool linuxOnly,
    required double width,
    ReceiveSessionController? receiveController,
  }) async {
    // SettingsView loads its defaults from SharedPreferences on mount; give
    // it an empty mock store so the editor renders instead of a spinner.
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          linuxOnly: linuxOnly,
          receiveController: receiveController,
        ),
      ),
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

  testWidgets('brand header shows the QRStream logo + name by default',
      (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 1200);

    expect(find.text('QRStream'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == 'assets/logo.png',
      ),
      findsOneWidget,
    );
  });

  testWidgets('brand header shows on Settings too', (tester) async {
    await pumpShell(tester, linuxOnly: false, width: 1200);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.text('QRStream'), findsOneWidget);
    expect(find.byType(SettingsView), findsOneWidget);
  });

  testWidgets(
      'Receive → Send → Receive preserves the completed receive state',
      (tester) async {
    // A completed session on the shell-owned controller (as if the transfer
    // just finished before the first tab switch).
    final controller = ReceiveSessionController()
      ..setSaved(
        SaveResult(
          name: 'notes.txt',
          method: SaveMethod.mediaStore,
          uri: 'content://media/downloads/1',
        ),
      );
    await pumpShell(
      tester,
      linuxOnly: false,
      width: 390,
      receiveController: controller,
    );

    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();
    expect(find.textContaining('File saved'), findsOneWidget);
    expect(find.textContaining('notes.txt'), findsOneWidget);

    // Switch to Send (disposes the ReceiveView State) and back.
    await tester.tap(find.byIcon(Icons.qr_code_2));
    await tester.pumpAndSettle();
    expect(find.byType(ReceiveView), findsNothing);

    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();

    // The shell kept the controller alive across the tab switch.
    expect(find.byType(ReceiveView), findsOneWidget);
    expect(find.textContaining('File saved'), findsOneWidget);
    expect(find.textContaining('notes.txt'), findsOneWidget);
  });

  testWidgets('rotation across the 600dp breakpoint preserves the SendView State',
      (tester) async {
    // Regression: crossing the compact/wide breakpoint must NOT recreate the
    // destination State — the shell keeps the body at a stable element path
    // (rail slot at index 0, destination at index 1) so Flutter reuses the
    // existing SendView State instead of resetting it to the home screen.
    await pumpShell(tester, linuxOnly: false, width: 390); // portrait phone
    expect(find.byType(SendView), findsOneWidget);
    final before =
        tester.state<State<SendView>>(find.byType(SendView)).hashCode;

    // Rotate to landscape: crosses 600dp → the wide (rail) layout branch.
    tester.view.physicalSize = const Size(800, 390);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(SendView), findsOneWidget);
    final after =
        tester.state<State<SendView>>(find.byType(SendView)).hashCode;
    expect(
      after,
      before,
      reason: 'SendView State must survive the breakpoint swap (rotation)',
    );

    // Rotate back to portrait: same State still alive.
    tester.view.physicalSize = const Size(390, 800);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    final rotatedBack =
        tester.state<State<SendView>>(find.byType(SendView)).hashCode;
    expect(
      rotatedBack,
      before,
      reason: 'SendView State must survive rotation in both directions',
    );
  });
}
