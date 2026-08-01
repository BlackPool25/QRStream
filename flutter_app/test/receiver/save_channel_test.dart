/// Tests for the Android save platform channel wrapper (Wave 5 T4.7).
///
/// The MethodChannel is mocked via
/// [TestDefaultBinaryMessengerBinding], so no native code runs — these tests
/// lock the channel contract (method names + argument maps) that
/// `MainActivity.kt` implements, plus the [SaveException] mapping.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_data_transfer/receiver/save_channel.dart';
import 'package:qr_data_transfer/receiver/saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(SaveChannel.channel, null);
  });

  test('saveToDownloads sends the method name and args and parses the reply',
      () async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    late MethodCall seen;
    messenger.setMockMethodCallHandler(SaveChannel.channel, (call) async {
      seen = call;
      return <String, Object?>{
        'uri': 'content://media/downloads/123',
        'name': 'file.bin',
      };
    });

    final result = await SaveChannel.saveToDownloads(
      bytes: bytes,
      filename: 'file.bin',
      mime: 'application/octet-stream',
    );

    expect(seen.method, 'saveToDownloads');
    expect(seen.arguments['filename'], 'file.bin');
    expect(seen.arguments['mime'], 'application/octet-stream');
    expect(seen.arguments['bytes'], isA<Uint8List>());
    expect((seen.arguments['bytes'] as Uint8List), equals(bytes));
    expect(result.uri, 'content://media/downloads/123');
    expect(result.name, 'file.bin');
  });

  test('a PlatformException reply surfaces as SaveException with its message',
      () async {
    messenger.setMockMethodCallHandler(SaveChannel.channel, (call) async {
      throw PlatformException(
        code: 'save_failed',
        message: 'could not save "x.bin"',
      );
    });

    await expectLater(
      SaveChannel.saveToDownloads(
        bytes: Uint8List(0),
        filename: 'x.bin',
        mime: 'application/octet-stream',
      ),
      throwsA(
        isA<SaveException>().having(
          (e) => e.message,
          'message',
          contains('could not save "x.bin"'),
        ),
      ),
    );
  });

  test('openSavedFile sends openFile with the uri argument', () async {
    late MethodCall seen;
    messenger.setMockMethodCallHandler(SaveChannel.channel, (call) async {
      seen = call;
      return null;
    });

    await SaveChannel.openSavedFile('content://media/downloads/123');

    expect(seen.method, 'openFile');
    expect(seen.arguments['uri'], 'content://media/downloads/123');
  });
}
