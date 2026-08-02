// SavedFilePreview widget tests: image MIME renders an in-memory preview;
// non-image MIME falls back to a type icon + name + type + location.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_data_transfer/ui/saved_file_preview.dart';
import 'package:qr_transfer_core/receiver/reassembler.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  ReassemblyResult result({
    required String mime,
    required String filename,
    Uint8List? bytes,
  }) => ReassemblyResult(
    bytes: bytes ?? Uint8List(8),
    sha256: '0' * 64,
    verified: true,
    mime: mime,
    filename: filename,
  );

  SaveResult saved(String uri) =>
      SaveResult(name: 'file.bin', method: SaveMethod.mediaStore, uri: uri);

  group('describeMime', () {
    test('labels image/video/audio/text/application kinds', () {
      expect(describeMime('image/png'), 'Image · PNG');
      expect(describeMime('video/mp4'), 'Video · MP4');
      expect(describeMime('audio/mpeg'), 'Audio · MPEG');
      expect(describeMime('text/plain'), 'Text · PLAIN');
      expect(describeMime('application/zip'), 'File · ZIP');
    });
  });

  group('isPreviewableImage', () {
    test('true for image/*, false otherwise', () {
      expect(isPreviewableImage('image/jpeg'), isTrue);
      expect(isPreviewableImage('image/png'), isTrue);
      expect(isPreviewableImage('video/mp4'), isFalse);
      expect(isPreviewableImage('application/pdf'), isFalse);
    });
  });

  testWidgets('image MIME renders an in-memory Image preview', (tester) async {
    // A 1x1 PNG so Image.memory decodes without a real file.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    await tester.pumpWidget(
      wrap(
        SavedFilePreview(
          result: result(mime: 'image/png', filename: 'photo.png', bytes: png),
          saved: saved('content://media/downloads/1'),
        ),
      ),
    );
    // Image decode is real async; let it complete, then pump one frame.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Image · PNG'), findsOneWidget);
  });

  testWidgets('video MIME falls back to icon + name + type + location', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SavedFilePreview(
          result: result(mime: 'video/mp4', filename: 'clip.mp4'),
          saved: saved('content://media/downloads/7'),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.text('Video · MP4'), findsOneWidget);
    expect(find.text('content://media/downloads/7'), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
  });

  testWidgets('application MIME falls back with location', (tester) async {
    await tester.pumpWidget(
      wrap(
        SavedFilePreview(
          result: result(mime: 'application/zip', filename: 'backup.zip'),
          saved: saved('/home/user/Downloads/QRTransfer/backup.zip'),
        ),
      ),
    );
    expect(find.text('backup.zip'), findsOneWidget);
    expect(find.text('File · ZIP'), findsOneWidget);
    expect(
      find.text('/home/user/Downloads/QRTransfer/backup.zip'),
      findsOneWidget,
    );
  });

  testWidgets('a null saved uri hides the location row', (tester) async {
    await tester.pumpWidget(
      wrap(
        SavedFilePreview(
          result: result(mime: 'application/pdf', filename: 'doc.pdf'),
          saved: const SaveResult(name: 'doc.pdf', method: SaveMethod.download),
        ),
      ),
    );
    expect(find.text('doc.pdf'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsNothing);
  });
}
