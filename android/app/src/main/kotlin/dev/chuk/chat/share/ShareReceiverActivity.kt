package dev.chuk.chat.share

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.content.pm.ShortcutManagerCompat
import dev.chuk.chat.MainActivity

/**
 * Entry point of the system share sheet (ACTION_SEND / ACTION_SEND_MULTIPLE),
 * for the plain "Chuk Chat" app entry and for every agent Direct Share
 * contact ([ShareBridge.publishTargets]).
 *
 * It has no UI. It forwards the shared text and content URIs, with their read
 * grants, to [MainActivity] in the app's own task and finishes. So a share
 * never starts a second Flutter engine inside the sharing app's task.
 */
class ShareReceiverActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val src = intent
    if (src != null && (src.action == Intent.ACTION_SEND || src.action == Intent.ACTION_SEND_MULTIPLE)) {
      forward(src)
    }
    finish()
  }

  private fun forward(src: Intent) {
    val uris = sharedUris(src)
    val out = Intent(this, MainActivity::class.java).apply {
      action = ShareBridge.ACTION_SHARE
      addFlags(
        Intent.FLAG_ACTIVITY_NEW_TASK or
          Intent.FLAG_ACTIVITY_SINGLE_TOP or
          Intent.FLAG_ACTIVITY_CLEAR_TOP,
      )
      src.getCharSequenceExtra(Intent.EXTRA_TEXT)?.let {
        putExtra(ShareBridge.EXTRA_TEXT, it.toString())
      }
      src.getStringExtra(Intent.EXTRA_SUBJECT)?.let {
        putExtra(ShareBridge.EXTRA_SUBJECT, it)
      }
      src.getStringExtra(ShortcutManagerCompat.EXTRA_SHORTCUT_ID)?.let {
        putExtra(ShareBridge.EXTRA_TARGET, it)
      }
      if (uris.isNotEmpty()) {
        // ClipData carries the read grant on to MainActivity.
        val clip = ClipData.newRawUri(null, uris.first())
        uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
        clipData = clip
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        putParcelableArrayListExtra(ShareBridge.EXTRA_URIS, ArrayList(uris))
      }
    }
    startActivity(out)
  }

  @Suppress("DEPRECATION")
  private fun sharedUris(src: Intent): List<Uri> {
    val found = LinkedHashSet<Uri>()
    if (src.action == Intent.ACTION_SEND_MULTIPLE) {
      val list = if (Build.VERSION.SDK_INT >= 33) {
        src.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
      } else {
        src.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
      }
      list?.let { found.addAll(it) }
    } else {
      val one = if (Build.VERSION.SDK_INT >= 33) {
        src.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
      } else {
        src.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
      }
      one?.let { found.add(it) }
    }
    src.clipData?.let { clip ->
      for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { found.add(it) }
    }
    // Only content:// URIs. A file:// URI from another app could point at
    // this app's own private files.
    return found.filter { it.scheme == "content" }
  }
}
