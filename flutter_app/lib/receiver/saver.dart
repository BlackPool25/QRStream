/// Platform file save for the receive view (Wave 5 T4.7).
///
/// Android saves through the MediaStore (no permission needed on API 29+)
/// and opens the saved file with the default viewer via its content URI;
/// Linux uses the native file selector and reveals the file in the file
/// manager. All platform calls are injected as function handles
/// ([saveFn] / [openFn]), so widget tests drive the save flow with fakes and
/// never touch plugins. Filename sanitization lives in core
/// (`package:qr_transfer_core/receiver/save_logic.dart`).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_transfer_core/receiver/save_logic.dart';
import 'package:url_launcher/url_launcher.dart';

/// How the platform save was performed.
enum SaveMethod { mediaStore, fileSelector, download }

/// Outcome of a save: the actual saved [name], the [method], and the
/// platform handle needed to open it later — a content URI on Android, the
/// saved file path on Linux (see [Saver.openSavedFile]).
class SaveResult {
  const SaveResult({required this.name, required this.method, this.uri});

  final String name;
  final SaveMethod method;

  /// Android: content URI. Linux: absolute file path.
  final String? uri;
}

/// Typed save failure; the view surfaces [message] directly.
class SaveException implements Exception {
  const SaveException(this.message);

  final String message;

  @override
  String toString() => 'SaveException: $message';
}

/// Platform save function handle; injected in tests.
typedef SaveFileFn = Future<SaveResult> Function({
  required Uint8List bytes,
  required String filename,
  required String mime,
  SaveMethod? method,
});

/// Platform open function handle; injected in tests.
typedef OpenSavedFileFn = Future<void> Function(SaveResult result);

/// File saver whose platform implementations are replaceable via
/// [saveFn] / [openFn]; the defaults run on real devices.
class Saver {
  Saver({SaveFileFn? saveFn, OpenSavedFileFn? openFn, this.android = true})
    : _saveFn = saveFn ?? _defaultSave,
      _openFn = openFn ?? _defaultOpen;

  /// Host platform flag: picks the default save method (mediaStore vs
  /// fileSelector) when [Saver.saveFile] is called without one.
  final bool android;

  final SaveFileFn _saveFn;
  final OpenSavedFileFn _openFn;

  /// Saves [bytes] under [filename] (sanitized by the platform impl).
  /// [method] overrides the platform default.
  Future<SaveResult> saveFile({
    required Uint8List bytes,
    required String filename,
    required String mime,
    SaveMethod? method,
  }) {
    return _saveFn(
      bytes: bytes,
      filename: filename,
      mime: mime,
      method: method ??
          (android ? SaveMethod.mediaStore : SaveMethod.fileSelector),
    );
  }

  /// Opens a previously saved file (tap-to-open): the default viewer on
  /// Android, the file manager reveal on Linux.
  Future<void> openSavedFile(SaveResult result) => _openFn(result);
}

/// App subfolder for MediaStore downloads (must be non-empty per the plugin).
const String _mediaStoreAppFolder = 'QRTransfer';

Future<SaveResult> _defaultSave({
  required Uint8List bytes,
  required String filename,
  required String mime,
  SaveMethod? method,
}) {
  return switch (method ?? SaveMethod.mediaStore) {
    SaveMethod.mediaStore => _saveViaMediaStore(bytes, filename, mime),
    SaveMethod.fileSelector => _saveViaFileSelector(bytes, filename, mime),
    SaveMethod.download => Future.error(
      const SaveException('the download method is not available on this platform'),
    ),
  };
}

Future<SaveResult> _saveViaMediaStore(
  Uint8List bytes,
  String filename,
  String mime,
) async {
  final name = sanitizeFilename(filename);
  final dir = await getTemporaryDirectory();
  final tempFile = File('${dir.path}/$name');
  await tempFile.writeAsBytes(bytes, flush: true);
  await MediaStore.ensureInitialized();
  MediaStore.appFolder = _mediaStoreAppFolder;
  final info = await MediaStore().saveFile(
    tempFilePath: tempFile.path,
    dirType: DirType.download,
    dirName: DirName.download,
  );
  if (info == null) {
    throw SaveException('could not save "$name" to the downloads folder');
  }
  return SaveResult(
    name: info.name,
    method: SaveMethod.mediaStore,
    uri: info.uri.toString(),
  );
}

Future<SaveResult> _saveViaFileSelector(
  Uint8List bytes,
  String filename,
  String mime,
) async {
  final name = sanitizeFilename(filename);
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) {
    throw const SaveException('save dialog was cancelled');
  }
  final file = File(location.path);
  await file.writeAsBytes(bytes, flush: true);
  // Reveal the saved file in the file manager.
  await Process.run('xdg-open', <String>[file.parent.path]);
  final sep = Platform.pathSeparator;
  final savedName = location.path.substring(location.path.lastIndexOf(sep) + 1);
  return SaveResult(
    name: savedName,
    method: SaveMethod.fileSelector,
    uri: location.path,
  );
}

Future<void> _defaultOpen(SaveResult result) async {
  switch (result.method) {
    case SaveMethod.mediaStore:
      final uri = result.uri;
      if (uri == null) {
        return;
      }
      await launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication);
    case SaveMethod.fileSelector:
      final path = result.uri;
      if (path == null) {
        return;
      }
      await Process.run('xdg-open', <String>[path]);
    case SaveMethod.download:
      break;
  }
}
