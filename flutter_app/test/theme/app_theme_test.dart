import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_data_transfer/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildAppTheme', () {
    test('light scheme pins the research-locked cocoa roles', () {
      final scheme = buildAppTheme(Brightness.light).colorScheme;

      expect(scheme.primary, const Color(0xFF53352B));
      expect(scheme.surface, const Color(0xFFFFF8F6));
      expect(scheme.primaryContainer, const Color(0xFF6D4C41));
      expect(scheme.onPrimaryContainer, const Color(0xFFEBBEB0));
      expect(scheme.tertiary, const Color(0xFF9A5B12));
    });

    test('dark scheme pins the research-locked espresso roles', () {
      final scheme = buildAppTheme(Brightness.dark).colorScheme;

      expect(scheme.primary, const Color(0xFFE9BDAE));
      expect(scheme.surface, const Color(0xFF161312));
      expect(scheme.tertiary, const Color(0xFFFFC46B));
      expect(scheme.onTertiary, const Color(0xFF462A00));
      expect(scheme.onPrimary, const Color(0xFF452920));
    });

    test('light surface is used as the scaffold background', () {
      final theme = buildAppTheme(Brightness.light);

      expect(theme.scaffoldBackgroundColor, const Color(0xFFFFF8F6));
    });

    test('display and headline tiers use Fraunces, body stays default', () {
      final textTheme = buildAppTheme(Brightness.light).textTheme;

      expect(textTheme.displayLarge?.fontFamily, contains('Fraunces'));
      expect(textTheme.displayMedium?.fontFamily, contains('Fraunces'));
      expect(textTheme.headlineLarge?.fontFamily, contains('Fraunces'));
      expect(textTheme.headlineSmall?.fontFamily, contains('Fraunces'));

      expect(textTheme.bodyLarge?.fontFamily, isNot(contains('Fraunces')));
      expect(textTheme.bodyMedium?.fontFamily, isNot(contains('Fraunces')));
    });
  });

  group('buildQrStageTheme', () {
    test('scaffold is always espresso, independent of the input brightness',
        () {
      expect(
        buildQrStageTheme(Brightness.light).scaffoldBackgroundColor,
        qrStageBackground,
      );
      expect(
        buildQrStageTheme(Brightness.dark).scaffoldBackgroundColor,
        qrStageBackground,
      );
      expect(buildQrStageTheme().scaffoldBackgroundColor, qrStageBackground);
    });
  });
}
