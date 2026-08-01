package com.qrtransfer.qr_data_transfer

import android.Manifest
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// Hosts the `com.qrtransfer.qr_data_transfer/save` MethodChannel that
/// replaces the abandoned media_store_plus plugin: `saveToDownloads` inserts
/// received bytes straight into the Downloads folder via MediaStore (no temp
/// file) and `openFile` opens a saved content URI with the default viewer.
///
/// All channel work runs on a background [executor] so the platform main
/// thread is never blocked. On API < 29 the legacy `DATA`-column insert needs
/// the runtime `WRITE_EXTERNAL_STORAGE` permission (declared in the manifest
/// with `android:maxSdkVersion="28"`), which is requested on demand and the
/// pending save is resumed from the grant result.
class MainActivity : FlutterActivity() {

  private companion object {
    const val CHANNEL = "com.qrtransfer.qr_data_transfer/save"
    const val SAVE_TO_DOWNLOADS = "saveToDownloads"
    const val OPEN_FILE = "openFile"
    const val SUBFOLDER = "QRTransfer"
    const val REQUEST_WRITE_STORAGE = 5401
  }

  private val executor: ExecutorService = Executors.newSingleThreadExecutor()

  // Pending save for the legacy API < 29 path while WRITE_EXTERNAL_STORAGE
  // is being requested from the user.
  private var pendingBytes: ByteArray? = null
  private var pendingFilename: String? = null
  private var pendingMime: String? = null
  private var pendingResult: MethodChannel.Result? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      CHANNEL,
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        SAVE_TO_DOWNLOADS -> {
          val bytes = call.argument<ByteArray>("bytes")
          val filename = call.argument<String>("filename")
          if (bytes == null || filename == null) {
            result.error("save_failed", "missing bytes or filename", null)
            return@setMethodCallHandler
          }
          val mime = call.argument<String>("mime") ?: "application/octet-stream"
          executor.execute { saveToDownloads(bytes, filename, mime, result) }
        }
        OPEN_FILE -> {
          val uri = call.argument<String>("uri")
          executor.execute { openFile(uri, result) }
        }
        else -> result.notImplemented()
      }
    }
  }

  override fun onDestroy() {
    executor.shutdown()
    super.onDestroy()
  }

  // ------------------------------------------------------------------ save

  private fun saveToDownloads(
    bytes: ByteArray,
    filename: String,
    mime: String,
    result: MethodChannel.Result,
  ) {
    try {
      val displayName = filename.substringAfterLast('/').ifEmpty { filename }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        saveViaDownloadsCollection(bytes, displayName, mime, result)
      } else {
        saveViaLegacyData(bytes, displayName, mime, result)
      }
    } catch (e: Exception) {
      result.error(
        "save_failed",
        "could not save \"$filename\": ${e.message}",
        null,
      )
    }
  }

  /// API 29+: insert into MediaStore.Downloads with a RELATIVE_PATH under
  /// the Downloads/QRTransfer folder; no permission needed.
  private fun saveViaDownloadsCollection(
    bytes: ByteArray,
    displayName: String,
    mime: String,
    result: MethodChannel.Result,
  ) {
    val resolver: ContentResolver = contentResolver
    val values = ContentValues().apply {
      put(MediaStore.Downloads.DISPLAY_NAME, displayName)
      put(MediaStore.Downloads.MIME_TYPE, mime)
      put(
        MediaStore.Downloads.RELATIVE_PATH,
        Environment.DIRECTORY_DOWNLOADS + "/" + SUBFOLDER,
      )
    }
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
    if (uri == null) {
      result.error(
        "save_failed",
        "could not save \"$displayName\" to the downloads folder",
        null,
      )
      return
    }
    val out = resolver.openOutputStream(uri)
    if (out == null) {
      result.error(
        "save_failed",
        "could not open the output stream for \"$displayName\"",
        null,
      )
      return
    }
    out.use { it.write(bytes) }
    result.success(
      mapOf(
        "uri" to uri.toString(),
        // MediaStore may dedupe/rename; report the actual DISPLAY_NAME.
        "name" to (queryDisplayName(resolver, uri) ?: displayName),
      ),
    )
  }

  private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? =
    resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)
      ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

  /// API < 29: legacy `DATA`-column insert into MediaStore.Files. Requires
  /// the WRITE_EXTERNAL_STORAGE runtime permission on API 23+, which is
  /// requested here and the save resumed from onRequestPermissionsResult.
  @Suppress("DEPRECATION")
  private fun saveViaLegacyData(
    bytes: ByteArray,
    displayName: String,
    mime: String,
    result: MethodChannel.Result,
  ) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !hasWriteStorage()) {
      pendingBytes = bytes
      pendingFilename = displayName
      pendingMime = mime
      pendingResult = result
      runOnUiThread {
        ActivityCompat.requestPermissions(
          this,
          arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
          REQUEST_WRITE_STORAGE,
        )
      }
      return
    }
    writeLegacyFile(bytes, displayName, mime, result)
  }

  private fun hasWriteStorage(): Boolean =
    ActivityCompat.checkSelfPermission(
      this,
      Manifest.permission.WRITE_EXTERNAL_STORAGE,
    ) == PackageManager.PERMISSION_GRANTED

  @Suppress("DEPRECATION")
  private fun writeLegacyFile(
    bytes: ByteArray,
    displayName: String,
    mime: String,
    result: MethodChannel.Result,
  ) {
    val dir = File(
      Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
      SUBFOLDER,
    )
    if (!dir.exists() && !dir.mkdirs()) {
      result.error(
        "save_failed",
        "could not create the downloads folder for \"$displayName\"",
        null,
      )
      return
    }
    val file = File(dir, displayName)
    file.writeBytes(bytes)
    val values = ContentValues().apply {
      put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
      put(MediaStore.MediaColumns.MIME_TYPE, mime)
      put(MediaStore.MediaColumns.DATA, file.absolutePath)
    }
    val uri = contentResolver.insert(MediaStore.Files.getContentUri("external"), values)
    result.success(
      mapOf(
        "uri" to (uri?.toString() ?: Uri.fromFile(file).toString()),
        "name" to displayName,
      ),
    )
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode != REQUEST_WRITE_STORAGE) return
    val bytes = pendingBytes
    val filename = pendingFilename
    val mime = pendingMime
    val result = pendingResult
    pendingBytes = null
    pendingFilename = null
    pendingMime = null
    pendingResult = null
    if (result == null) return
    if (grantResults.isEmpty() || grantResults[0] != PackageManager.PERMISSION_GRANTED) {
      result.error("save_failed", "write permission denied for \"$filename\"", null)
      return
    }
    if (bytes != null && filename != null) {
      executor.execute {
        writeLegacyFile(bytes, filename, mime ?: "application/octet-stream", result)
      }
    }
  }

  // ------------------------------------------------------------------ open

  private fun openFile(uriString: String?, result: MethodChannel.Result) {
    if (uriString.isNullOrEmpty()) {
      result.error("no_viewer", "no file to open", null)
      return
    }
    try {
      val intent =
        Intent(Intent.ACTION_VIEW, Uri.parse(uriString))
          .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      val handlers = packageManager.queryIntentActivities(intent, 0)
      if (handlers.isEmpty()) {
        result.error("no_viewer", "no app on this device can open this file", null)
        return
      }
      val launch = if (handlers.size > 1) {
        Intent.createChooser(intent, "Open with")
      } else {
        intent
      }
      runOnUiThread {
        try {
          startActivity(launch)
          result.success(null)
        } catch (e: Exception) {
          result.error("no_viewer", "could not open this file: ${e.message}", null)
        }
      }
    } catch (e: Exception) {
      result.error("no_viewer", "could not open this file: ${e.message}", null)
    }
  }
}
