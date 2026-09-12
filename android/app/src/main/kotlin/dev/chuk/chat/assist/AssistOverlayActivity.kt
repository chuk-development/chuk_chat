package dev.chuk.chat.assist

import android.os.Bundle
import android.view.View
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.RenderMode

class AssistOverlayActivity : AssistantHostActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    AssistantRuntime.overlayActivity = this
    AssistantRuntime.reset()
    AssistantRuntime.sessionActive = true
  }

  override fun onDestroy() {
    if (AssistantRuntime.overlayActivity === this) {
      AssistantRuntime.overlayActivity = null
    }
    // The captured screen text must not outlive the surface that asked for it.
    AssistantRuntime.sessionActive = false
    AssistantRuntime.reset()
    super.onDestroy()
  }

  fun hideForScreenshot(capture: () -> Unit) {
    val root = window.decorView
    root.alpha = 0f
    root.visibility = View.INVISIBLE
    root.postDelayed({
      capture()
    }, 180)
  }

  fun showAfterScreenshot() {
    val root = window.decorView
    root.visibility = View.VISIBLE
    root.alpha = 1f
  }

  override fun getRenderMode(): RenderMode {
    return RenderMode.texture
  }

  override fun getBackgroundMode(): BackgroundMode {
    return BackgroundMode.transparent
  }

  override fun getInitialRoute(): String {
    return "/assistant-overlay"
  }
}
