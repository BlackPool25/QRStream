/// Pure filename/MIME helpers for the receiver save path — the Dart port of
/// the PWA's `sanitizeFilename` + `mimeFromFilename` (src/receiver/save.ts),
/// with exact parity. Kept in core so they are testable under plain
/// `dart test` without any platform plugin.
library;

/// Largest sanitized name length; the extension survives truncation.
const int maxFilenameLen = 180;

/// Conservative fallback when sanitization empties the input.
const String fallbackFilename = 'file';

/// Sanitizes a received file name: strips control characters, drops leading
/// dots (hidden-file / traversal protection), replaces path separators with
/// underscores, and truncates to at most [maxFilenameLen] characters while
/// keeping the extension. Never throws.
String sanitizeFilename(String name) {
  // Deliberate control-character class: strips C0/C1/DEL from untrusted names.
  final cleaned = name.replaceAll(RegExp('[\u0000-\u001f\u007f-\u009f]'), '');
  // Leading dots first, so a traversal-ish "../evil.txt" becomes "_evil.txt"
  // instead of surviving separator replacement as ".._evil.txt".
  final dotless = cleaned.replaceFirst(RegExp(r'^\.+'), '');
  final separated = dotless.replaceAll(RegExp(r'[\\/]'), '_');
  if (separated.isEmpty) {
    return fallbackFilename;
  }
  return _truncateKeepingExtension(separated, maxFilenameLen);
}

/// Truncates [name] to [max] characters, keeping the final extension intact
/// when it fits.
String _truncateKeepingExtension(String name, int max) {
  if (name.length <= max) {
    return name;
  }
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    final ext = name.substring(dot);
    if (ext.length < max) {
      return name.substring(0, max - ext.length) + ext;
    }
  }
  return name.substring(0, max);
}

/// Extension (lowercase, no dot) → MIME type map for [mimeFromFilename].
const Map<String, String> extensionToMime = <String, String>{
  'txt': 'text/plain',
  'json': 'application/json',
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'mp4': 'video/mp4',
  'mp3': 'audio/mpeg',
  'zip': 'application/zip',
  'csv': 'text/csv',
  'md': 'text/markdown',
  'html': 'text/html',
  'htm': 'text/html',
  'js': 'text/javascript',
  'ts': 'application/typescript',
  'svg': 'image/svg+xml',
  'bin': 'application/octet-stream',
};

/// Best-effort MIME type from a file name's extension (case-insensitive).
/// Unknown or missing extensions default to application/octet-stream.
String mimeFromFilename(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) {
    return 'application/octet-stream';
  }
  final ext = name.substring(dot + 1).toLowerCase();
  return extensionToMime[ext] ?? 'application/octet-stream';
}
