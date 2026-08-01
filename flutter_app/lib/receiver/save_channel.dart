/// Android save platform channel wrapper (Wave 5 T4.7).
///
/// Talks to the MethodChannel registered in `MainActivity.kt`
/// (`com.qrtransfer.qr_data_transfer/save`): [SaveChannel.saveToDownloads]
/// hands bytes straight to the native MediaStore insert — no temp file on the
/// Dart side — and [SaveChannel.openSavedFile] opens a saved content URI with
/// the default viewer. Native `PlatformException`s surface as [SaveException]
/// (from saver.dart), keeping the message the platform replied with.
library;

import 'package:flutter/services.dart';
import 'package:qr_data_transfer/receiver/saver.dart';

/// Android save channel name, matching `MainActivity.kt`.
const String _channelName = 'com.qrtransfer.qr_data_transfer/save';

/// Dart-side handle for the Android save channel.
class SaveChannel {
  SaveChannel._();

  static const MethodChannel _channel = MethodChannel(_channelName);

  /// The save MethodChannel; tests mock it via the default binary messenger.
  static MethodChannel get channel => _channel;

  /// Saves [bytes] under [filename] (MIME [mime]) in the app's Downloads
  /// subfolder via the native MediaStore insert, returning the resulting
  /// content URI and the actual saved name.
  static Future<({String uri, String name})> saveToDownloads({
    required Uint8List bytes,
    required String filename,
    required String mime,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'saveToDownloads',
        <String, Object?>{'bytes': bytes, 'filename': filename, 'mime': mime},
      );
      return (uri: result!['uri'] as String, name: result['name'] as String);
    } on PlatformException catch (e) {
      final message = e.message;
      throw SaveException(
        message is String && message.isNotEmpty
            ? message
            : 'could not save "$filename"',
      );
    }
  }

  /// Opens a previously saved file identified by its content [uri] with the
  /// default viewer.
  static Future<void> openSavedFile(String uri) async {
    try {
      await _channel.invokeMethod<void>('openFile', <String, Object?>{'uri': uri});
    } on PlatformException catch (e) {
      final message = e.message;
      throw SaveException(
        message is String && message.isNotEmpty
            ? message
            : 'could not open "$uri"',
      );
    }
  }
}
