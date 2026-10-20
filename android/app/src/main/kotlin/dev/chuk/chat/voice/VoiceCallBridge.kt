package dev.chuk.chat.voice

import android.app.Activity
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Person
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.CallkitNotificationService
import com.hiennv.flutter_callkit_incoming.getDataActiveCalls
import com.hiennv.flutter_callkit_incoming.removeAllCalls
import dev.chuk.chat.MainActivity
import dev.chuk.chat.R
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The native half of lib/voice/incoming/ongoing_call_notification.dart
 * (FEATURE_VOICE_CALL): the native ongoing-call notification with two actions,
 * Mute/Unmute and Hang up; the unlock prompt
 * after a call is accepted on the lock screen; and the clean-up when the app
 * dies during a call.
 *
 * MainActivity is never shown over the lock screen. The ring there is
 * flutter_callkit_incoming's own CallkitIncomingActivity; an accepted call
 * runs its audio in the callkit foreground service with this notification,
 * and the app itself appears only once the user has unlocked.
 *
 * The notification is posted under the notification id of
 * flutter_callkit_incoming's own ongoing call (`callKey.hashCode()`, the id
 * that plugin derives from the call id). It therefore replaces that
 * notification and keeps its phoneCall + microphone foreground service: one
 * notification per call, not two.
 *
 * Volume up/down are handled here and never reach Dart: they move
 * STREAM_VOICE_CALL, the stream WebRTC plays a call on. Hang up, Mute and
 * Speaker go to Dart over the event channel, because the LiveKit room lives
 * there. A tap on the notification opens the app on the call ("open").
 *
 * Privacy: the notification carries the coworker's name and a status line,
 * never the call's reason or a transcript.
 */
class VoiceCallBridge(private val activity: Activity, messenger: BinaryMessenger) {

  companion object {
    private const val TAG = "VoiceCallBridge"
    private const val METHOD_CHANNEL = "chuk/voice_call"
    private const val EVENT_CHANNEL = "chuk/voice_call_actions"
    private const val NOTIFICATION_CHANNEL_ID = "voice_call_ongoing"

    const val EXTRA_OPEN_CALL = "dev.chuk.chat.voice.OPEN_CALL"
    const val EXTRA_BUTTON = "dev.chuk.chat.voice.BUTTON"
    private const val ACTION_OPEN_CALL = "dev.chuk.chat.voice.action.OPEN_CALL"
    private const val ACTION_BUTTON_PREFIX = "dev.chuk.chat.voice.action.BUTTON."

    const val BUTTON_HANGUP = "hangup"
    const val BUTTON_MUTE = "mute"
    const val BUTTON_SPEAKER = "speaker"
    const val BUTTON_VOLUME_UP = "volume_up"
    const val BUTTON_VOLUME_DOWN = "volume_down"
    private const val EVENT_OPEN = "open"

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    /** The ongoing-call notifications posted and not cancelled yet. */
    private val shownIds = mutableSetOf<Int>()

    /**
     * Actions that arrived while no Dart listener was attached, oldest
     * first. Only touched on the main thread. A later action never replaces
     * an earlier one (a Hang up stays); at most [MAX_PENDING] are kept, and
     * when full the oldest action that is not a Hang up goes first.
     */
    private val pending = ArrayDeque<String>()
    private const val MAX_PENDING = 16

    /** Hands [action] to Dart, or queues it until Dart listens. */
    fun emit(action: String) {
      main.post {
        val s = sink
        if (s != null) {
          s.success(action)
          return@post
        }
        if (pending.size >= MAX_PENDING) {
          val drop = pending.indexOfFirst { it != BUTTON_HANGUP }
          if (drop >= 0) pending.removeAt(drop) else pending.removeFirst()
        }
        pending.addLast(action)
      }
    }

    /** Hands every queued action to [s], in arrival order. */
    private fun drain(s: EventChannel.EventSink) {
      while (pending.isNotEmpty()) s.success(pending.removeFirst())
    }

    /**
     * The Flutter engine is going away for good (the app was swiped away or
     * finished) while a call may still run: the LiveKit room died with the
     * engine, so the callkit call, its foreground service and our
     * notification must go too, or they stay behind as a stuck call. Ends
     * every callkit call the way the plugin's `endAllCalls` does.
     */
    fun endAllCalls(context: Context) {
      val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
      for (id in shownIds) manager?.cancel(id)
      shownIds.clear()
      try {
        val calls = getDataActiveCalls(context)
        if (calls.isEmpty()) return
        for (call in calls) {
          val bundle = call.toBundle()
          context.sendBroadcast(
            if (call.isAccepted) {
              CallkitIncomingBroadcastReceiver.getIntentEnded(context, bundle)
            } else {
              CallkitIncomingBroadcastReceiver.getIntentDecline(context, bundle)
            },
          )
        }
        removeAllCalls(context)
        CallkitNotificationService.stopService(context)
      } catch (e: Exception) {
        Log.w(TAG, "ending calls failed: ${e.javaClass.simpleName}")
      }
    }

    /** Moves the call stream one step up (+1) or down (-1). */
    fun adjustCallVolume(context: Context, direction: Int) {
      val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
      try {
        audio.adjustStreamVolume(
          AudioManager.STREAM_VOICE_CALL,
          if (direction > 0) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
          AudioManager.FLAG_SHOW_UI,
        )
      } catch (e: SecurityException) {
        // Do-not-disturb can refuse a volume change; nothing else to do.
        Log.w(TAG, "volume change refused")
      }
    }
  }

  private val context: Context = activity.applicationContext
  private val methods = MethodChannel(messenger, METHOD_CHANNEL)
  private val events = EventChannel(messenger, EVENT_CHANNEL)
  private var requestedAudioRoute = false

  init {
    methods.setMethodCallHandler(::onMethodCall)
    events.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
          sink = eventSink
          if (eventSink != null) drain(eventSink)
        }

        override fun onCancel(arguments: Any?) {
          sink = null
        }
      },
    )
  }

  /** A tap on the ongoing-call notification (cold start or onNewIntent). */
  fun onIntent(intent: Intent?) {
    if (intent?.getBooleanExtra(EXTRA_OPEN_CALL, false) != true) return
    intent.removeExtra(EXTRA_OPEN_CALL)
    emit(EVENT_OPEN)
  }

  fun dispose() {
    methods.setMethodCallHandler(null)
    events.setStreamHandler(null)
    sink = null
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "showOngoingCall" -> {
          showOngoingCall(call)
          result.success(null)
        }
        "cancelOngoingCall" -> {
          val key = call.argument<String>("callKey")
          if (key != null) {
            notificationManager()?.cancel(key.hashCode())
            shownIds.remove(key.hashCode())
          }
          result.success(null)
        }
        "requestUnlock" -> {
          requestUnlock()
          result.success(null)
        }
        "showNotice" -> {
          val text = call.argument<String>("text")
          if (!text.isNullOrEmpty()) Toast.makeText(context, text, Toast.LENGTH_LONG).show()
          result.success(null)
        }
        "adjustCallVolume" -> {
          adjustCallVolume(context, call.argument<Int>("direction") ?: 1)
          result.success(null)
        }
        "getCallVolume" -> {
          val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
          val max = audio.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL).coerceAtLeast(1)
          result.success(audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL).toDouble() / max)
        }
        "setCallVolume" -> {
          val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
          val max = audio.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL).coerceAtLeast(1)
          val volume = (call.argument<Number>("volume")?.toDouble() ?: 1.0).coerceIn(0.0, 1.0)
          audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, kotlin.math.round(volume * max).toInt(), 0)
          result.success(audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL).toDouble() / max)
        }
        "getCallAudioRoute" -> result.success(callAudioRoute())
        "setCallSpeaker" -> {
          setCallSpeaker(call.argument<Boolean>("speaker") == true, result)
        }
        "setCallVolumeControls" -> {
          val active = call.argument<Boolean>("active") == true
          activity.volumeControlStream = if (active)
            AudioManager.STREAM_VOICE_CALL else AudioManager.USE_DEFAULT_STREAM_TYPE
          if (!active && requestedAudioRoute && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).clearCommunicationDevice()
            requestedAudioRoute = false
          }
          result.success(null)
        }
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.w(TAG, "${call.method} failed: ${e.javaClass.simpleName}")
      result.error("voice_call", e.javaClass.simpleName, null)
    }
  }

  // ── Call audio routing ───────────────────────────────────────────────

  /** The real communication output, rather than the UI's requested preference. */
  @Suppress("DEPRECATION")
  private fun callAudioRoute(): String {
    val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      return when (audio.communicationDevice?.type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "wired"
        else -> "unknown"
      }
    }
    return when {
      audio.isBluetoothScoOn -> "bluetooth"
      audio.isSpeakerphoneOn -> "speaker"
      audio.isWiredHeadsetOn -> "wired"
      else -> "earpiece"
    }
  }

  /**
   * LiveKit owns audio focus and call-mode lifetime. Select the actual output
   * after changing its speaker preference, then wait for Android to confirm it.
   * A successful preference write alone does not mean that routing changed.
   */
  @Suppress("DEPRECATION")
  private fun setCallSpeaker(speaker: Boolean, result: MethodChannel.Result) {
    val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val wanted = if (speaker) "speaker" else "earpiece"
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      val deviceType = if (speaker) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
      val device = audio.availableCommunicationDevices.firstOrNull { it.type == deviceType }
      if (device == null) {
        result.error("voice_audio_route", "Requested audio output is unavailable", null)
        return
      }
      if (!audio.setCommunicationDevice(device)) {
        result.error("voice_audio_route", "Android refused the audio output change", null)
        return
      }
      requestedAudioRoute = true
    } else {
      audio.isSpeakerphoneOn = speaker
    }
    // The platform changes communication devices asynchronously. Poll only for
    // this bounded request; no persistent handler or microphone session is added.
    val deadline = android.os.SystemClock.uptimeMillis() + 1500L
    fun confirm() {
      try {
        val actual = callAudioRoute()
        if (actual == wanted) {
          result.success(actual)
        } else if (android.os.SystemClock.uptimeMillis() >= deadline) {
          // LiveKit may already have switched even if communicationDevice
          // still reports the previous route. Hand the actual route back
          // instead of failing the call — this is a local output change.
          result.success(if (actual == "unknown") wanted else actual)
        } else {
          main.postDelayed({ confirm() }, 50L)
        }
      } catch (e: Exception) {
        result.error("voice_audio_route", e.javaClass.simpleName, null)
      }
    }
    confirm()
  }

  // ── Lock screen ──────────────────────────────────────────────────────

  /**
   * After a call is accepted on the lock screen: ask the user to unlock. The
   * app never shows over the lock screen itself; the call's audio runs in the
   * callkit foreground service until then. (The callkit ring screen asks as
   * well when its Accept is pressed; this covers the other ways in.)
   */
  private fun requestUnlock() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager ?: return
    if (!keyguard.isKeyguardLocked) return
    keyguard.requestDismissKeyguard(activity, null)
  }

  // ── The notification ─────────────────────────────────────────────────

  private fun notificationManager(): NotificationManager? =
    context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

  private fun ensureChannel(manager: NotificationManager) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return
    val channel = NotificationChannel(
      NOTIFICATION_CHANNEL_ID,
      context.getString(R.string.voice_call_channel_name),
      NotificationManager.IMPORTANCE_DEFAULT,
    ).apply {
      description = context.getString(R.string.voice_call_channel_description)
      setSound(null, null)
      enableVibration(false)
      setShowBadge(false)
      lockscreenVisibility = Notification.VISIBILITY_PUBLIC
    }
    manager.createNotificationChannel(channel)
  }

  @Suppress("DEPRECATION")
  private fun showOngoingCall(call: MethodCall) {
    val key = call.argument<String>("callKey") ?: return
    val title = call.argument<String>("title") ?: context.getString(R.string.voice_call_default_title)
    val status = call.argument<String>("status") ?: ""
    val muted = call.argument<Boolean>("muted") == true
    val connectedAtMs = (call.argument<Any>("connectedAtMs") as? Number)?.toLong() ?: 0L

    val manager = notificationManager() ?: return
    ensureChannel(manager)
    val id = key.hashCode()

    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
    } else {
      Notification.Builder(context)
    }
    builder
      .setSmallIcon(R.drawable.ic_notification)
      .setContentTitle(title)
      .setContentText(status)
      .setContentIntent(openIntent(id))
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setAutoCancel(false)
      .setCategory(Notification.CATEGORY_CALL)
      .setVisibility(Notification.VISIBILITY_PUBLIC)
      .setColor(context.getColor(R.color.voice_call_accent))
    val mute = Notification.Action.Builder(
      if (muted) R.drawable.ic_voice_call_mic_off else R.drawable.ic_voice_call_mic,
      context.getString(if (muted) R.string.voice_call_unmute else R.string.voice_call_mute),
      buttonIntent(id, BUTTON_MUTE),
    ).build()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Android supplies the compact call template and full-width pill actions.
      // Reuse callkit's notification id: its foreground microphone service stays
      // the owner, and notification taps/actions retain the existing Dart path.
      val person = Person.Builder().setName(title.ifBlank {
        context.getString(R.string.voice_call_default_title)
      }).setImportant(true).build()
      builder.setStyle(
        Notification.CallStyle.forOngoingCall(person, buttonIntent(id, BUTTON_HANGUP))
          .setDeclineButtonColorHint(context.getColor(R.color.voice_call_hangup)),
      ).addAction(mute)
    } else {
      // Standard actions on older Android also avoid nested custom-view padding
      // and duplicate title/status rows. Mute toggles capture; it is not Pause.
      builder.addAction(Notification.Action.Builder(
        R.drawable.ic_voice_call_end,
        context.getString(R.string.voice_call_hang_up),
        buttonIntent(id, BUTTON_HANGUP),
      ).build()).addAction(mute)
    }
    if (connectedAtMs > 0) {
      builder.setWhen(connectedAtMs).setShowWhen(true).setUsesChronometer(true)
    } else {
      builder.setShowWhen(false)
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
    }
    manager.notify(id, builder.build())
    shownIds.add(id)
  }

  private fun buttonIntent(id: Int, button: String): PendingIntent {
    val intent = Intent(context, VoiceCallActionReceiver::class.java)
      .setAction(ACTION_BUTTON_PREFIX + button)
      .putExtra(EXTRA_BUTTON, button)
    return PendingIntent.getBroadcast(
      context,
      // One code per call; the action names the button, so each button gets
      // its own PendingIntent.
      id,
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
  }

  private fun openIntent(id: Int): PendingIntent {
    // MainActivity is singleTask: this reaches the running instance through
    // onNewIntent instead of starting a second Flutter engine.
    val intent = Intent(context, MainActivity::class.java)
      .setAction(ACTION_OPEN_CALL)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
      .putExtra(EXTRA_OPEN_CALL, true)
    return PendingIntent.getActivity(
      context,
      id,
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
  }
}

/** The buttons of the ongoing-call notification. */
class VoiceCallActionReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    when (val button = intent.getStringExtra(VoiceCallBridge.EXTRA_BUTTON)) {
      VoiceCallBridge.BUTTON_VOLUME_UP -> VoiceCallBridge.adjustCallVolume(context, 1)
      VoiceCallBridge.BUTTON_VOLUME_DOWN -> VoiceCallBridge.adjustCallVolume(context, -1)
      VoiceCallBridge.BUTTON_HANGUP,
      VoiceCallBridge.BUTTON_MUTE,
      VoiceCallBridge.BUTTON_SPEAKER -> VoiceCallBridge.emit(button)
      else -> Unit
    }
  }
}
