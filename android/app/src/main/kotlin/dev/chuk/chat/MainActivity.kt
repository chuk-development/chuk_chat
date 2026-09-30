package dev.chuk.chat

import android.content.Intent
import dev.chuk.chat.assist.AssistantHostActivity
import dev.chuk.chat.voice.VoiceCallBridge
import io.flutter.embedding.engine.FlutterEngine

/**
 * The launcher activity. It inherits the assistant MethodChannel from
 * [AssistantHostActivity], so the in-app assistant surface and the one the
 * system assist gesture opens talk to the same native handler.
 *
 * It also hosts the voice-call bridge (FEATURE_VOICE_CALL): the ongoing-call
 * notification, its buttons, and the unlock prompt after a call is accepted
 * on the lock screen ([VoiceCallBridge]). This activity is never shown over
 * the lock screen. With the flag, the manifest overlay (src/voiceCall/) makes
 * it `singleTask`, so the call screen and the notification reach this one
 * instance and never start a second Flutter engine.
 */
class MainActivity : AssistantHostActivity() {
  private var voiceCall: VoiceCallBridge? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val bridge = VoiceCallBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    voiceCall = bridge
    bridge.onIntent(intent)
  }

  override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    voiceCall?.dispose()
    voiceCall = null
    super.cleanUpFlutterEngine(flutterEngine)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    voiceCall?.onIntent(intent)
  }

  override fun onDestroy() {
    // The app is going away for good (swiped from recents, or finished): the
    // Flutter engine, and with it the call's LiveKit room, dies here. End the
    // callkit call and drop our notification, or a dead call stays behind in
    // the foreground service. Not on a configuration change: the engine
    // survives that.
    if (isFinishing && !isChangingConfigurations) {
      VoiceCallBridge.endAllCalls(applicationContext)
    }
    super.onDestroy()
  }
}
