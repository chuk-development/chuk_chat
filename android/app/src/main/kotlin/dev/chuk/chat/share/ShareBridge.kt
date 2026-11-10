package dev.chuk.chat.share

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import dev.chuk.chat.MainActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Bridge for content shared into the app from the system share sheet, and for
 * the Direct Share contacts (one per agent) the sheet shows.
 *
 * Channel `chuk/share`:
 *  - Dart -> native `takeShare`: the pending share or null. The share is
 *    removed when it is taken.
 *  - Dart -> native `setShareTargets`: list of `{id, label, icon (PNG bytes)}`.
 *    Replaces every Direct Share contact this app published before.
 *  - native -> Dart `shareAvailable`: a share is ready; call `takeShare`.
 *
 * A share map: `{text, subject, target, files: [{path, name, mime}]}`.
 * `target` is the share-target id the user picked in the sheet, or null for
 * the plain app entry. Shared files are copied into `cacheDir/shared/`.
 */
class ShareBridge(private val context: Context, messenger: BinaryMessenger) {
  companion object {
    const val ACTION_SHARE = "dev.chuk.chat.action.SHARE"
    const val EXTRA_TEXT = "dev.chuk.chat.share.TEXT"
    const val EXTRA_SUBJECT = "dev.chuk.chat.share.SUBJECT"
    const val EXTRA_TARGET = "dev.chuk.chat.share.TARGET"
    const val EXTRA_URIS = "dev.chuk.chat.share.URIS"
    const val SHARE_CATEGORY = "dev.chuk.chat.category.SHARE_TARGET"
    private const val CHANNEL = "chuk/share"
    private const val ID_PREFIX = "share_"
    private const val MAX_FILE_BYTES = 200L * 1024 * 1024
  }

  private val channel = MethodChannel(messenger, CHANNEL)
  private val main = Handler(Looper.getMainLooper())
  private val io = Executors.newSingleThreadExecutor()
  private var pending: Map<String, Any?>? = null
  private var disposed = false

  init {
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "takeShare" -> {
          val share = pending
          pending = null
          result.success(share)
        }
        "setShareTargets" -> {
          val raw = call.argument<List<Map<String, Any?>>>("targets") ?: emptyList()
          io.execute {
            val ok = runCatching { publishTargets(raw) }.isSuccess
            main.post { result.success(ok) }
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  fun dispose() {
    disposed = true
    channel.setMethodCallHandler(null)
    io.shutdown()
  }

  /** Reads a share forwarded by [ShareReceiverActivity]. Returns true if [intent] was one. */
  fun onIntent(intent: Intent?): Boolean {
    if (intent?.action != ACTION_SHARE) return false
    val text = intent.getStringExtra(EXTRA_TEXT)
    val subject = intent.getStringExtra(EXTRA_SUBJECT)
    val target = intent.getStringExtra(EXTRA_TARGET)?.removePrefix(ID_PREFIX)
    @Suppress("DEPRECATION")
    val uris: List<Uri> = (
      if (Build.VERSION.SDK_INT >= 33) {
        intent.getParcelableArrayListExtra(EXTRA_URIS, Uri::class.java)
      } else {
        intent.getParcelableArrayListExtra<Uri>(EXTRA_URIS)
      }
    ) ?: emptyList()
    // Consume it: an activity re-creation must not deliver the share twice.
    intent.action = Intent.ACTION_MAIN
    io.execute {
      val files = uris.mapNotNull { copyToCache(it) }
      val share = mapOf(
        "text" to text,
        "subject" to subject,
        "target" to target,
        "files" to files,
      )
      main.post {
        if (disposed) return@post
        pending = share
        channel.invokeMethod("shareAvailable", null)
      }
    }
    return true
  }

  private fun copyToCache(uri: Uri): Map<String, Any?>? = runCatching {
    val resolver = context.contentResolver
    var name: String? = null
    var size = -1L
    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
      ?.use { c ->
        if (c.moveToFirst()) {
          val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
          val si = c.getColumnIndex(OpenableColumns.SIZE)
          if (ni >= 0) name = c.getString(ni)
          if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
        }
      }
    if (size > MAX_FILE_BYTES) return@runCatching null
    val safeName = (name ?: uri.lastPathSegment ?: "shared")
      .replace(Regex("[/\\\\\\u0000]"), "_")
      .take(120)
      .ifBlank { "shared" }
    val dir = File(context.cacheDir, "shared/${UUID.randomUUID()}").apply { mkdirs() }
    val out = File(dir, safeName)
    var copied = 0L
    resolver.openInputStream(uri)?.use { input ->
      out.outputStream().use { output ->
        val buf = ByteArray(64 * 1024)
        while (true) {
          val n = input.read(buf)
          if (n < 0) break
          copied += n
          if (copied > MAX_FILE_BYTES) throw IllegalStateException("too large")
          output.write(buf, 0, n)
        }
      }
    } ?: return@runCatching null
    mapOf(
      "path" to out.absolutePath,
      "name" to safeName,
      "mime" to resolver.getType(uri),
    )
  }.getOrNull()

  private fun publishTargets(raw: List<Map<String, Any?>>) {
    val max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context).coerceAtMost(8)
    val launch = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_DEFAULT)
    val shortcuts = raw.take(max).mapIndexedNotNull { rank, t ->
      val id = (t["id"] as? String)?.takeIf { it.isNotBlank() } ?: return@mapIndexedNotNull null
      val label = (t["label"] as? String)?.takeIf { it.isNotBlank() } ?: return@mapIndexedNotNull null
      val png = t["icon"] as? ByteArray
      val sid = ID_PREFIX + id
      val builder = ShortcutInfoCompat.Builder(context, sid)
        .setShortLabel(label)
        .setLongLabel(label)
        .setLongLived(true)
        .setRank(rank)
        .setIntent(launch)
        .setCategories(setOf(SHARE_CATEGORY))
        .setPerson(Person.Builder().setName(label).setKey(sid).setBot(true).build())
      png?.let { adaptiveIcon(it) }?.let { builder.setIcon(it) }
      builder.build()
    }
    val keep = shortcuts.map { it.id }.toSet()
    val stale = ShortcutManagerCompat.getDynamicShortcuts(context)
      .map { it.id }
      .filter { it.startsWith(ID_PREFIX) && it !in keep }
    if (stale.isNotEmpty()) ShortcutManagerCompat.removeLongLivedShortcuts(context, stale)
    if (stale.isNotEmpty()) ShortcutManagerCompat.removeDynamicShortcuts(context, stale)
    shortcuts.forEach { ShortcutManagerCompat.pushDynamicShortcut(context, it) }
  }

  /**
   * The PNG comes from Dart already laid out for an adaptive icon: a full
   * background, the face inside the middle 72/108 that the launcher mask
   * shows. Used as it is.
   */
  private fun adaptiveIcon(png: ByteArray): IconCompat? {
    val bmp = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return null
    return IconCompat.createWithAdaptiveBitmap(bmp)
  }
}
