// Saved-file preview shown after a transfer completes. Images (mime starts
// with image/) render an in-memory preview of the received bytes; anything
// else (video, audio, archives, documents) falls back to a type icon + name +
// type + saved location, since the app deliberately has no media-playing
// dependencies.
library;

import 'package:flutter/material.dart';
import 'package:qr_data_transfer/receiver/saver.dart';
import 'package:qr_transfer_core/receiver/reassembler.dart'
    show ReassemblyResult;

/// A readable label for a MIME type (e.g. "video/mp4" → "Video · MP4").
String describeMime(String mime) {
  final slash = mime.indexOf('/');
  if (slash <= 0) return mime;
  final kind = mime.substring(0, slash);
  final subtype = mime.substring(slash + 1).toUpperCase();
  final kindLabel = switch (kind) {
    'image' => 'Image',
    'video' => 'Video',
    'audio' => 'Audio',
    'text' => 'Text',
    'application' => 'File',
    _ => kind,
  };
  return '$kindLabel · $subtype';
}

/// The icon shown for a non-image file, by MIME kind.
IconData iconForMime(String mime) {
  final kind = mime.substring(0, mime.indexOf('/')).toLowerCase();
  return switch (kind) {
    'video' => Icons.movie_outlined,
    'audio' => Icons.audiotrack_outlined,
    'text' => Icons.description_outlined,
    'application' => Icons.insert_drive_file_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// Whether [mime] is renderable as an in-memory image preview.
bool isPreviewableImage(String mime) => mime.startsWith('image/');

/// Post-receive preview card. [result] carries the received bytes + MIME;
/// [saved] carries the platform handle (content URI on Android, path on
/// Linux) shown as the file's location.
class SavedFilePreview extends StatelessWidget {
  const SavedFilePreview({
    super.key,
    required this.result,
    required this.saved,
  });

  final ReassemblyResult result;
  final SaveResult saved;

  @override
  Widget build(BuildContext context) {
    final mime = result.mime;
    if (isPreviewableImage(mime)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: Image.memory(
                result.bytes,
                fit: BoxFit.contain,
                errorBuilder: (context, _, _) => _fallback(context),
                frameBuilder: (context, child, frame, wasSync) {
                  if (wasSync || frame != null) return child;
                  return const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(child: CircularProgressIndicator()),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          _meta(context, Icons.image_outlined),
        ],
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) {
    final t = Theme.of(context);
    final location = saved.uri;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(iconForMime(mime), size: 40, color: t.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.filename,
                    style: t.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    describeMime(result.mime),
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (location != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.folder_outlined,
                size: 16,
                color: t.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  location,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _meta(BuildContext context, IconData icon) {
    final t = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: t.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            describeMime(result.mime),
            style: t.textTheme.bodySmall?.copyWith(
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  String get mime => result.mime;
}
