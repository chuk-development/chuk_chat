package dev.chuk.chat.assist

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Bitmap
import android.graphics.Rect
import android.hardware.HardwareBuffer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.ByteArrayOutputStream

class AssistAccessibilityService : AccessibilityService() {
  private companion object {
    const val VISION_MAX_EDGE = 1280
  }

  private val handler = Handler(Looper.getMainLooper())
  private var snapshotScheduled = false
  // The application id, not the Kotlin package: accessibility events carry the
  // former. A literal "…assist" here matched nothing, so the service captured
  // its own app's windows.
  private val ownPackageName: String by lazy { applicationContext.packageName }
  private val ignoredPackages: Set<String> by lazy {
    setOf(
      ownPackageName,
      "com.android.systemui",
      "com.google.android.inputmethod.latin",
      "com.android.inputmethod.latin",
    )
  }
  private val ignoredEventPackages: Set<String> by lazy {
    setOf(
      ownPackageName,
      "com.google.android.inputmethod.latin",
      "com.android.inputmethod.latin",
    )
  }

  override fun onServiceConnected() {
    super.onServiceConnected()
    AssistantRuntime.accessibilityService = this

    serviceInfo = serviceInfo.apply {
      flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
        AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
      eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
        AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
        AccessibilityEvent.TYPE_VIEW_FOCUSED
      feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
      notificationTimeout = 250
    }

    scheduleSnapshot()
  }

  override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    if (event == null) {
      return
    }

    val eventPackage = event.packageName?.toString().orEmpty()
    if (ignoredEventPackages.contains(eventPackage)) {
      return
    }

    when (event.eventType) {
      AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
      AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
      AccessibilityEvent.TYPE_VIEW_FOCUSED -> scheduleSnapshot()
    }
  }

  override fun onInterrupt() {
  }

  override fun onDestroy() {
    AssistantRuntime.accessibilityService = null
    super.onDestroy()
  }

  fun clickByText(text: String): Boolean {
    val root = targetRoot() ?: return false
    val candidates = root.findAccessibilityNodeInfosByText(text)
    if (candidates.isNullOrEmpty()) {
      return false
    }

    for (node in candidates) {
      var current: AccessibilityNodeInfo? = node
      while (current != null) {
        if (current.isClickable) {
          return current.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
        current = current.parent
      }
    }

    return false
  }

  fun performGlobalActionByName(name: String): Boolean {
    val action = when (name.lowercase()) {
      "back" -> GLOBAL_ACTION_BACK
      "home" -> GLOBAL_ACTION_HOME
      "recents" -> GLOBAL_ACTION_RECENTS
      "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
      "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
      else -> return false
    }
    return performGlobalAction(action)
  }

  fun collectScrollableContext(
    query: String,
    maxScrolls: Int,
    restoreScroll: Boolean,
    callback: (Map<String, Any?>) -> Unit,
  ) {
    val normalizedMaxScrolls = maxScrolls.coerceIn(0, 8)
    val queryTerms = query
      .lowercase()
      .split(Regex("\\s+"))
      .map { it.trim() }
      .filter { it.length >= 4 }
      .take(8)

    val screens = ArrayList<Map<String, Any?>>()
    val seenLines = LinkedHashSet<String>()
    var scrollsPerformed = 0

    fun captureScreen(label: String) {
      val root = targetRoot()
      if (root == null) {
        val cachedText = AssistantRuntime.lastContext["visibleText"]?.toString().orEmpty()
        if (cachedText.isNotBlank()) {
          for (line in cachedText.lines().map { it.trim() }.filter { it.isNotEmpty() }) {
            seenLines.add(line)
          }
          screens.add(
            mapOf(
              "label" to label,
              "packageName" to (AssistantRuntime.lastContext["packageName"] ?: ""),
              "className" to (AssistantRuntime.lastContext["className"] ?: ""),
              "text" to cachedText,
              "newLines" to cachedText.lines().size,
              "source" to "cached_before_overlay",
            ),
          )
        }
        return
      }
      val text = collectText(root, 1200, 16000)
      val lines = text
        .lines()
        .map { it.trim() }
        .filter { it.isNotEmpty() }

      var newLines = 0
      for (line in lines) {
        if (seenLines.add(line)) {
          newLines += 1
        }
      }

      screens.add(
        mapOf(
          "label" to label,
          "packageName" to (root.packageName?.toString() ?: ""),
          "className" to (root.className?.toString() ?: ""),
          "text" to text,
          "newLines" to newLines,
        ),
      )
    }

    fun containsQueryTerms(): Boolean {
      if (queryTerms.isEmpty()) {
        return false
      }
      val haystack = seenLines.joinToString("\n").lowercase()
      return queryTerms.any { haystack.contains(it) }
    }

    fun finish(reason: String) {
      val merged = seenLines.joinToString("\n").let {
        if (it.length > 32000) it.substring(0, 32000) else it
      }
      val target = targetRoot()
      val fallbackPackage = AssistantRuntime.lastContext["packageName"]?.toString().orEmpty()
      val fallbackClass = AssistantRuntime.lastContext["className"]?.toString().orEmpty()

      callback(
        mapOf(
          "packageName" to (target?.packageName?.toString() ?: fallbackPackage),
          "className" to (target?.className?.toString() ?: fallbackClass),
          "visibleText" to merged,
          "screens" to screens,
          "scrollsPerformed" to scrollsPerformed,
          "restoreScrollRequested" to restoreScroll,
          "reason" to reason,
          "timestamp" to System.currentTimeMillis(),
        ),
      )
    }

    fun restoreThenFinish(reason: String) {
      if (!restoreScroll || scrollsPerformed <= 0) {
        finish(reason)
        return
      }

      var remaining = scrollsPerformed
      fun restoreStep() {
        val scrollNode = findScrollableNode(targetRoot())
        if (scrollNode == null || remaining <= 0) {
          finish("${reason}_restored_${scrollsPerformed - remaining}")
          return
        }

        scrollNode.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
        remaining -= 1
        handler.postDelayed({ restoreStep() }, 100)
      }

      restoreStep()
    }

    fun step() {
      captureScreen("screen_${screens.size + 1}")

      if (containsQueryTerms() && scrollsPerformed > 0) {
        restoreThenFinish("query_terms_found")
        return
      }

      if (scrollsPerformed >= normalizedMaxScrolls) {
        restoreThenFinish("max_scrolls_reached")
        return
      }

      val scrollNode = findScrollableNode(targetRoot())
      if (scrollNode == null || !scrollNode.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) {
        restoreThenFinish("cannot_scroll_forward")
        return
      }

      scrollsPerformed += 1
      handler.postDelayed({ step() }, 260)
    }

    handler.post { step() }
  }

  fun takeScreenshotBase64(callback: (String?) -> Unit) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
      callback(null)
      return
    }

    takeScreenshot(
      Display.DEFAULT_DISPLAY,
      mainExecutor,
      object : TakeScreenshotCallback {
        override fun onSuccess(screenshot: ScreenshotResult) {
          val hardwareBuffer: HardwareBuffer = screenshot.hardwareBuffer
          val bitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, screenshot.colorSpace)
          hardwareBuffer.close()

          if (bitmap == null) {
            callback(null)
            return
          }

          // Vision models take a data URI. A full-resolution PNG of a modern
          // phone screen is several megabytes in base64, so scale the long
          // edge down and encode as JPEG before handing it over.
          val scaled = scaleForVision(bitmap)
          val out = ByteArrayOutputStream()
          scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
          if (scaled !== bitmap) {
            scaled.recycle()
          }
          val encoded = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
          callback(encoded)
        }

        override fun onFailure(errorCode: Int) {
          callback(null)
        }
      },
    )
  }

  private fun scaleForVision(bitmap: Bitmap): Bitmap {
    val longEdge = maxOf(bitmap.width, bitmap.height)
    if (longEdge <= VISION_MAX_EDGE) {
      return bitmap
    }
    val factor = VISION_MAX_EDGE.toFloat() / longEdge
    val width = (bitmap.width * factor).toInt().coerceAtLeast(1)
    val height = (bitmap.height * factor).toInt().coerceAtLeast(1)

    // takeScreenshot hands over a HARDWARE bitmap. Scaling draws through a
    // software canvas, which refuses hardware bitmaps, so copy first.
    val source = if (bitmap.config == Bitmap.Config.HARDWARE) {
      bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return bitmap
    } else {
      bitmap
    }

    return try {
      Bitmap.createScaledBitmap(source, width, height, true)
    } catch (error: RuntimeException) {
      Log.w("ChukAssistantA11y", "screenshot scaling failed", error)
      bitmap
    } finally {
      if (source !== bitmap) {
        source.recycle()
      }
    }
  }

  private fun scheduleSnapshot() {
    if (snapshotScheduled) {
      return
    }

    snapshotScheduled = true
    handler.postDelayed({
      snapshotScheduled = false
      updateSnapshot()
    }, 220)
  }

  private fun updateSnapshot() {
    val root = rootInActiveWindow ?: return
    if (isIgnoredNode(root)) {
      val target = targetRoot() ?: return
      updateSnapshotFromRoot(target)
      return
    }

    updateSnapshotFromRoot(root)
  }

  private fun updateSnapshotFromRoot(root: AccessibilityNodeInfo) {
    // No assistant on screen, nothing to capture for.
    if (!AssistantRuntime.sessionActive) {
      return
    }
    val packageName = root.packageName?.toString() ?: ""
    val className = root.className?.toString() ?: ""
    val visibleText = collectText(root, 500, 8000)

    AssistantRuntime.lastContext = mapOf(
      "packageName" to packageName,
      "className" to className,
      "visibleText" to visibleText,
      "timestamp" to System.currentTimeMillis(),
    )
  }

  private fun targetRoot(): AccessibilityNodeInfo? {
    val active = rootInActiveWindow
    if (active != null && !isIgnoredNode(active)) {
      return active
    }

    val orderedWindows = windows
      ?.sortedByDescending { it.layer }
      .orEmpty()

    var systemUiFallback: AccessibilityNodeInfo? = null
    for (window in orderedWindows) {
      val root = window.root ?: continue
      val pkg = root.packageName?.toString().orEmpty()
      if (!isIgnoredNode(root)) {
        return root
      }
      if (pkg == "com.android.systemui" && systemUiFallback == null) {
        systemUiFallback = root
      }
    }

    return systemUiFallback
  }

  private fun isIgnoredNode(node: AccessibilityNodeInfo): Boolean {
    val pkg = node.packageName?.toString() ?: return false
    return ignoredPackages.contains(pkg)
  }

  private fun findScrollableNode(root: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
    if (root == null) {
      return null
    }

    val queue = ArrayDeque<AccessibilityNodeInfo>()
    queue.add(root)

    var visited = 0
    var bestNode: AccessibilityNodeInfo? = null
    var bestArea = 0

    while (queue.isNotEmpty() && visited < 800) {
      val node = queue.removeFirst()
      visited += 1

      if (node.isScrollable) {
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val area = bounds.width().coerceAtLeast(0) * bounds.height().coerceAtLeast(0)
        if (area > bestArea) {
          bestArea = area
          bestNode = node
        }
      }

      for (i in 0 until node.childCount) {
        node.getChild(i)?.let { queue.add(it) }
      }
    }

    return bestNode
  }

  private fun collectText(
    root: AccessibilityNodeInfo,
    maxNodes: Int,
    maxChars: Int,
  ): String {
    val queue = ArrayDeque<AccessibilityNodeInfo>()
    val parts = ArrayList<String>()
    queue.add(root)

    var visited = 0
    while (queue.isNotEmpty() && visited < maxNodes) {
      val node = queue.removeFirst()
      visited += 1

      val text = node.text?.toString()?.trim().orEmpty()
      if (text.isNotEmpty()) {
        parts.add(text)
      }

      val desc = node.contentDescription?.toString()?.trim().orEmpty()
      if (desc.isNotEmpty()) {
        parts.add(desc)
      }

      for (i in 0 until node.childCount) {
        node.getChild(i)?.let { queue.add(it) }
      }
    }

    val merged = parts
      .distinct()
      .joinToString("\n")

    return if (merged.length > maxChars) merged.substring(0, maxChars) else merged
  }
}
