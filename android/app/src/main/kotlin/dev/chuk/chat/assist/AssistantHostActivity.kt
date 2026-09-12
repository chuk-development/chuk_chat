package dev.chuk.chat.assist

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import android.util.Log
import android.provider.ContactsContract
import android.provider.Settings
import android.view.KeyEvent
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class AssistantHostActivity : FlutterActivity() {
  private val channelName = "chuk/assistant"
  private var pendingAssistantRoleResult: MethodChannel.Result? = null
  private var pendingPermissionResult: MethodChannel.Result? = null

  companion object {
    private const val REQUEST_ASSISTANT_ROLE = 9821
    private const val REQUEST_CONTACTS_PERMISSION = 9822
    private const val REQUEST_LOCATION_PERMISSION = 9823

    // Companion clock app integration.
    private const val CLOCK_APP_PACKAGE = "com.example.uhr_app"
    private const val CLOCK_RECEIVER = "com.example.uhr_app.clock.ClockCommandReceiver"
    private const val CLOCK_ACTION_COMMAND = "com.example.uhr_app.action.CLOCK_COMMAND"
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "beginAssistantSession" -> {
            AssistantRuntime.reset()
            AssistantRuntime.sessionActive = true
            result.success(true)
          }

          "endAssistantSession" -> {
            AssistantRuntime.sessionActive = false
            AssistantRuntime.reset()
            result.success(true)
          }

          "startVoiceService" -> {
            val intent = Intent(this, VoiceForegroundService::class.java)
              .setAction(VoiceForegroundService.ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
              startForegroundService(intent)
            } else {
              startService(intent)
            }
            result.success(true)
          }

          "stopVoiceService" -> {
            val intent = Intent(this, VoiceForegroundService::class.java)
              .setAction(VoiceForegroundService.ACTION_STOP)
            startService(intent)
            result.success(true)
          }

          "openAccessibilitySettings" -> {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            result.success(null)
          }

          "openNotificationAccessSettings" -> {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            result.success(null)
          }

          "openOverlaySettings" -> {
            val intent = Intent(
              Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
              Uri.parse("package:$packageName"),
            )
            startActivity(intent)
            result.success(null)
          }

          "openAssistantSettings" -> {
            openAssistantSettings()
            result.success(null)
          }

          "openAppDetailsSettings" -> {
            val intent = Intent(
              Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
              Uri.parse("package:$packageName"),
            )
            startActivity(intent)
            result.success(null)
          }

          "requestAssistantRole" -> {
            requestAssistantRole(result)
          }

          "isAccessibilityEnabled" -> {
            result.success(isAccessibilityServiceEnabled())
          }

          "getPermissionStatuses" -> {
            result.success(
              mapOf(
                "accessibility" to isAccessibilityServiceEnabled(),
                "assistant" to isAssistantRoleHeld(),
                "notificationAccess" to isNotificationListenerEnabled(),
                "overlay" to canDrawOverlays(),
                "contacts" to hasPermission(Manifest.permission.READ_CONTACTS),
                "location" to (
                  hasPermission(Manifest.permission.ACCESS_FINE_LOCATION) ||
                    hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                  ),
              ),
            )
          }

          "requestContactsPermission" -> {
            requestSinglePermission(Manifest.permission.READ_CONTACTS, REQUEST_CONTACTS_PERMISSION, result)
          }

          "requestLocationPermission" -> {
            requestPermissionsCompat(
              arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
              ),
              REQUEST_LOCATION_PERMISSION,
              result,
            )
          }

          "getCurrentContext" -> {
            result.success(AssistantRuntime.lastContext)
          }

          "collectScrollableContext" -> {
            val service = AssistantRuntime.accessibilityService
            if (service == null) {
              result.success(AssistantRuntime.lastContext)
              return@setMethodCallHandler
            }

            val query = call.argument<String>("query").orEmpty()
            val maxScrolls = call.argument<Int>("maxScrolls") ?: 4
            val restoreScroll = call.argument<Boolean>("restoreScroll") ?: true
            service.collectScrollableContext(query, maxScrolls, restoreScroll) { context ->
              runOnUiThread { result.success(context) }
            }
          }

          "getRecentNotifications" -> {
            result.success(AssistantRuntime.readNotifications())
          }

          "findContact" -> {
            val name = call.argument<String>("name").orEmpty()
            result.success(findContact(name))
          }

          "openDialerForContact" -> {
            val name = call.argument<String>("name").orEmpty()
            val contact = findContact(name)
            val phone = contact["phone"]?.toString().orEmpty()
            if (phone.isEmpty()) {
              result.success(false)
              return@setMethodCallHandler
            }
            val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(phone)}"))
            startActivity(intent)
            result.success(true)
          }

          "callContactDirect" -> {
            val phone = call.argument<String>("phone").orEmpty()
            if (phone.isEmpty()) {
              result.success(false)
              return@setMethodCallHandler
            }
            val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(phone)}"))
              .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(true)
          }

          "openApp" -> {
            val name = call.argument<String>("name").orEmpty()
            result.success(openAppByName(name))
          }

          "openMaps" -> {
            // Geocoding hits the network, so it never runs on the platform
            // thread. The reply goes back on the main thread.
            val query = call.argument<String>("query").orEmpty()
            val latitude = call.argument<Double>("latitude")
            val longitude = call.argument<Double>("longitude")
            val navigate = call.argument<Boolean>("navigate") ?: false
            Thread {
              val outcome = openMaps(query, latitude, longitude, navigate)
              runOnUiThread { result.success(outcome) }
            }.start()
          }

          "listInstalledApps" -> {
            result.success(listLauncherApps())
          }

          "composeSmsForContact" -> {
            val name = call.argument<String>("name").orEmpty()
            val message = call.argument<String>("message").orEmpty()
            val contact = findContact(name)
            val phone = contact["phone"]?.toString().orEmpty()
            if (phone.isEmpty()) {
              result.success(false)
              return@setMethodCallHandler
            }
            val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${Uri.encode(phone)}"))
            intent.putExtra("sms_body", message)
            startActivity(intent)
            result.success(true)
          }

          "setTimer" -> {
            val seconds = call.argument<Int>("seconds") ?: 0
            val message = call.argument<String>("message").orEmpty()
            result.success(setTimer(seconds, message))
          }

          "isClockAppInstalled" -> {
            result.success(isClockAppInstalled())
          }

          "clockCommand" -> {
            val command = call.argument<String>("command").orEmpty()
            result.success(
              sendClockCommand(
                command = command,
                seconds = call.argument<Int>("seconds"),
                deltaSeconds = call.argument<Int>("deltaSeconds"),
                timerId = call.argument<Int>("timerId"),
                label = call.argument<String>("label"),
              ),
            )
          }

          "setAlarm" -> {
            val hour = call.argument<Int>("hour") ?: -1
            val minutes = call.argument<Int>("minutes") ?: -1
            val message = call.argument<String>("message").orEmpty()
            result.success(setAlarm(hour, minutes, message))
          }

          "dismissTimer" -> {
            result.success(dismissTimer())
          }

          "cancelTimerNotifications" -> {
            result.success(
              AssistantRuntime.notificationListener?.cancelTimerNotifications() ?: false,
            )
          }

          "mediaCommand" -> {
            val cmd = call.argument<String>("command").orEmpty()
            result.success(mediaCommand(cmd))
          }

          "getNowPlaying" -> {
            val filterPkg = call.argument<String>("packageName")
            result.success(getNowPlaying(filterPkg))
          }

          "volumeAdjust" -> {
            val direction = call.argument<String>("direction").orEmpty()
            val showUi = call.argument<Boolean>("showUi") ?: true
            result.success(volumeAdjust(direction, showUi))
          }

          "volumeSet" -> {
            val percent = call.argument<Int>("percent") ?: -1
            val showUi = call.argument<Boolean>("showUi") ?: true
            result.success(volumeSet(percent, showUi))
          }

          "volumeGet" -> {
            result.success(volumeGet())
          }

          "spotifySearch" -> {
            val query = call.argument<String>("query").orEmpty()
            result.success(spotifySearch(query))
          }

          "dismissAlarm" -> {
            result.success(dismissAlarm())
          }

          "showTimers" -> {
            result.success(showTimers())
          }

          "showAlarms" -> {
            result.success(showAlarms())
          }

          "getLastKnownLocation" -> {
            result.success(getLastKnownLocationMap())
          }

          "performGlobalAction" -> {
            val action = call.argument<String>("action").orEmpty()
            val ok = AssistantRuntime.accessibilityService?.performGlobalActionByName(action) ?: false
            result.success(ok)
          }

          "clickByText" -> {
            val text = call.argument<String>("text").orEmpty()
            val ok = AssistantRuntime.accessibilityService?.clickByText(text) ?: false
            result.success(ok)
          }

          "captureScreenshotBase64" -> {
            val service = AssistantRuntime.accessibilityService
            if (service == null) {
              result.success(null)
              return@setMethodCallHandler
            }

            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
              result.success(null)
              return@setMethodCallHandler
            }

            val completed = java.util.concurrent.atomic.AtomicBoolean(false)
            val timeoutHandler = Handler(Looper.getMainLooper())
            fun completeScreenshot(overlay: AssistOverlayActivity?, encoded: String?) {
              if (!completed.compareAndSet(false, true)) {
                return
              }

              runOnUiThread {
                overlay?.showAfterScreenshot()
                result.success(encoded)
              }
            }

            val overlay = AssistantRuntime.overlayActivity
            timeoutHandler.postDelayed({
              completeScreenshot(overlay, null)
            }, 3500)

            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.hideSoftInputFromWindow(window.decorView.windowToken, 0)

            if (overlay != null) {
              overlay.hideForScreenshot {
                service.takeScreenshotBase64 { encoded ->
                  completeScreenshot(overlay, encoded)
                }
              }
            } else {
              service.takeScreenshotBase64 { encoded ->
                completeScreenshot(null, encoded)
              }
            }
          }

          else -> result.notImplemented()
        }
      }
  }

  @Deprecated("Deprecated in Java")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)

    if (requestCode == REQUEST_ASSISTANT_ROLE) {
      val granted = resultCode == Activity.RESULT_OK
      pendingAssistantRoleResult?.success(granted)
      pendingAssistantRoleResult = null
    }
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)

    if (requestCode == REQUEST_CONTACTS_PERMISSION || requestCode == REQUEST_LOCATION_PERMISSION) {
      val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
      pendingPermissionResult?.success(granted)
      pendingPermissionResult = null
    }
  }

  private fun requestAssistantRole(result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      result.success(false)
      return
    }

    val roleManager = getSystemService(RoleManager::class.java)
    if (roleManager == null || !roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
      result.success(false)
      return
    }

    if (roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)) {
      result.success(true)
      return
    }

    if (pendingAssistantRoleResult != null) {
      result.error("assistant_role_busy", "Assistant role request already in progress", null)
      return
    }

    pendingAssistantRoleResult = result
    startActivityForResult(
      roleManager.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT),
      REQUEST_ASSISTANT_ROLE,
    )
  }

  private fun openAssistantSettings() {
    val intents = listOf(
      Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
      Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
      Intent(Settings.ACTION_SETTINGS),
    )

    val intent = intents.firstOrNull { it.resolveActivity(packageManager) != null }
      ?: Intent(Settings.ACTION_SETTINGS)
    startActivity(intent)
  }

  private fun hasPermission(permission: String): Boolean {
    return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
      checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
  }

  private fun requestSinglePermission(permission: String, requestCode: Int, result: MethodChannel.Result) {
    requestPermissionsCompat(arrayOf(permission), requestCode, result)
  }

  private fun requestPermissionsCompat(
    permissions: Array<String>,
    requestCode: Int,
    result: MethodChannel.Result,
  ) {
    if (permissions.any { hasPermission(it) }) {
      result.success(true)
      return
    }

    if (pendingPermissionResult != null) {
      result.error("permission_busy", "Permission request already in progress", null)
      return
    }

    pendingPermissionResult = result
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      requestPermissions(permissions, requestCode)
    } else {
      result.success(true)
      pendingPermissionResult = null
    }
  }

  private fun findContact(name: String): Map<String, Any?> {
    if (name.isBlank()) {
      return mapOf("found" to false, "reason" to "empty")
    }
    if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
      return mapOf("found" to false, "reason" to "permission_missing")
    }

    val projection = arrayOf(
      ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
      ContactsContract.CommonDataKinds.Phone.NUMBER,
    )

    val tokens = name.trim()
      .split(Regex("[\\s,\\.]+"))
      .map { it.trim() }
      .filter { it.length >= 2 }

    fun queryOnce(where: String, args: Array<String>): Triple<String, String, Int> {
      var total = 0
      val cursor: Cursor? = contentResolver.query(
        ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
        projection,
        where,
        args,
        "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
      )
      cursor.use {
        if (it == null) return Triple("", "", 0)
        total = it.count
        if (!it.moveToFirst()) return Triple("", "", 0)
        return Triple(it.getString(0) ?: "", it.getString(1) ?: "", total)
      }
    }

    // Strategy 1: full-string match
    val whole = queryOnce(
      "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
      arrayOf("%${name.trim()}%"),
    )
    if (whole.second.isNotBlank()) {
      return mapOf("found" to true, "name" to whole.first, "phone" to whole.second, "matches" to whole.third)
    }

    // Strategy 2: AND of all tokens (handles "Dietrich Müller" -> "%Dietrich%Müller%")
    if (tokens.size >= 2) {
      val and = queryOnce(
        "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
        arrayOf("%${tokens.joinToString("%")}%"),
      )
      if (and.second.isNotBlank()) {
        return mapOf("found" to true, "name" to and.first, "phone" to and.second, "matches" to and.third)
      }
    }

    // Strategy 3: OR of any token (first matching contact wins).
    if (tokens.isNotEmpty()) {
      val where = tokens.joinToString(" OR ") {
        "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?"
      }
      val args = tokens.map { "%$it%" }.toTypedArray()
      val any = queryOnce(where, args)
      if (any.second.isNotBlank()) {
        return mapOf("found" to true, "name" to any.first, "phone" to any.second, "matches" to any.third)
      }
    }

    return mapOf("found" to false, "reason" to "no_match")
  }

  private fun setTimer(seconds: Int, message: String): Boolean {
    if (seconds !in 1..86400) {
      return false
    }

    val intent = Intent(AlarmClock.ACTION_SET_TIMER)
      .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
      .putExtra(AlarmClock.EXTRA_MESSAGE, message.ifBlank { "Chuk Chat Timer" })
      .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    return startResolvableActivity(intent)
  }

  private fun isClockAppInstalled(): Boolean {
    return try {
      packageManager.getPackageInfo(CLOCK_APP_PACKAGE, 0)
      true
    } catch (_: PackageManager.NameNotFoundException) {
      false
    }
  }

  /**
   * Drives the companion clock app (com.example.uhr_app) via an explicit broadcast to its
   * ClockCommandReceiver. Unlike the system [AlarmClock] intents, this can pause/resume/reset/stop
   * timers and control the stopwatch. Returns a result map for the Dart layer.
   */
  private fun sendClockCommand(
    command: String,
    seconds: Int?,
    deltaSeconds: Int?,
    timerId: Int?,
    label: String?,
  ): Map<String, Any?> {
    if (command.isBlank()) {
      return mapOf("handled" to false, "via" to "none", "reason" to "empty_command")
    }
    if (!isClockAppInstalled()) {
      return mapOf("handled" to false, "via" to "none", "reason" to "uhr_not_installed")
    }

    return try {
      val intent = Intent(CLOCK_ACTION_COMMAND).apply {
        setClassName(CLOCK_APP_PACKAGE, CLOCK_RECEIVER)
        putExtra("command", command)
        seconds?.let { putExtra("seconds", it) }
        deltaSeconds?.let { putExtra("deltaSeconds", it) }
        timerId?.let { putExtra("timerId", it) }
        label?.let { putExtra("label", it) }
      }
      sendBroadcast(intent)
      mapOf("handled" to true, "via" to "uhr_app", "command" to command)
    } catch (e: Exception) {
      Log.w("ChukAssistant", "sendClockCommand failed", e)
      mapOf("handled" to false, "via" to "none", "reason" to (e.message ?: "broadcast_failed"))
    }
  }

  private fun setAlarm(hour: Int, minutes: Int, message: String): Boolean {
    if (hour !in 0..23 || minutes !in 0..59) {
      return false
    }

    val intent = Intent(AlarmClock.ACTION_SET_ALARM)
      .putExtra(AlarmClock.EXTRA_HOUR, hour)
      .putExtra(AlarmClock.EXTRA_MINUTES, minutes)
      .putExtra(AlarmClock.EXTRA_MESSAGE, message.ifBlank { "Chuk Chat Wecker" })
      .putExtra(AlarmClock.EXTRA_SKIP_UI, false)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    return startResolvableActivity(intent)
  }

  private fun dismissTimer(): Boolean {
    // 1) Best path: fire Stop/Reset action on the clock app's timer notification.
    val listener = AssistantRuntime.notificationListener
    if (listener != null && listener.fireTimerDismissAction()) {
      return true
    }

    // 2) Android API ACTION_DISMISS_TIMER (only works for *firing* timers on most clock apps).
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      val intent = Intent(AlarmClock.ACTION_DISMISS_TIMER)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      if (startResolvableActivity(intent)) {
        return true
      }
    }

    // 3) Last resort: hard-cancel the timer notification (does not stop the clock app's
    //    internal countdown, but kills the persistent notification).
    if (listener?.cancelTimerNotifications() == true) {
      return true
    }

    return showTimers()
  }

  private fun mediaCommand(command: String): Boolean {
    if (command.isEmpty()) return false
    val msm = getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
      ?: return false
    val component = ComponentName(this, AssistNotificationListenerService::class.java)
    val controllers: List<MediaController> = try {
      msm.getActiveSessions(component) ?: emptyList()
    } catch (e: SecurityException) {
      Log.w("ChukAssistant", "mediaCommand: no notification listener access", e)
      return mediaCommandFallbackBroadcast(command)
    }
    if (controllers.isEmpty()) {
      // Nothing currently has an active session — try broadcast key event fallback so an
      // idle player (e.g. Spotify after a long pause) can still resume.
      return mediaCommandFallbackBroadcast(command)
    }

    // Prefer the controller that is currently playing; otherwise the most recent one.
    val target = controllers.firstOrNull {
      it.playbackState?.state == PlaybackState.STATE_PLAYING
    } ?: controllers.first()

    val tc = target.transportControls ?: return false
    return try {
      when (command) {
        "play" -> tc.play()
        "pause" -> tc.pause()
        "toggle" -> {
          if (target.playbackState?.state == PlaybackState.STATE_PLAYING) tc.pause() else tc.play()
        }
        "next" -> tc.skipToNext()
        "previous" -> tc.skipToPrevious()
        "stop" -> tc.stop()
        else -> return false
      }
      true
    } catch (e: Exception) {
      Log.w("ChukAssistant", "mediaCommand failed", e)
      false
    }
  }

  private fun getNowPlaying(filterPackage: String?): Map<String, Any?> {
    val msm = getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
      ?: return mapOf("available" to false, "reason" to "no_service")
    val component = ComponentName(this, AssistNotificationListenerService::class.java)
    val controllers: List<MediaController> = try {
      msm.getActiveSessions(component) ?: emptyList()
    } catch (e: SecurityException) {
      return mapOf("available" to false, "reason" to "no_notification_access")
    }

    if (controllers.isEmpty()) {
      return mapOf("available" to false, "reason" to "no_session")
    }

    val filtered = if (!filterPackage.isNullOrBlank()) {
      controllers.filter { it.packageName.equals(filterPackage, ignoreCase = true) }
    } else controllers

    if (filtered.isEmpty()) {
      return mapOf(
        "available" to false,
        "reason" to "no_session_for_package",
        "filter" to (filterPackage ?: ""),
      )
    }

    val target = filtered.firstOrNull {
      it.playbackState?.state == PlaybackState.STATE_PLAYING
    } ?: filtered.first()

    val state = target.playbackState?.state ?: PlaybackState.STATE_NONE
    val isPlaying = state == PlaybackState.STATE_PLAYING
    val md = target.metadata

    fun s(key: String): String? = md?.getString(key)?.takeIf { it.isNotBlank() }

    val title = s(MediaMetadata.METADATA_KEY_TITLE)
      ?: s(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
    val artist = s(MediaMetadata.METADATA_KEY_ARTIST)
      ?: s(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
      ?: s(MediaMetadata.METADATA_KEY_AUTHOR)
      ?: s(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
    val album = s(MediaMetadata.METADATA_KEY_ALBUM)
    val durationMs = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
    val positionMs = target.playbackState?.position ?: 0L

    return mapOf(
      "available" to (title != null || artist != null),
      "isPlaying" to isPlaying,
      "playbackState" to state,
      "title" to title,
      "artist" to artist,
      "album" to album,
      "durationMs" to durationMs,
      "positionMs" to positionMs,
      "packageName" to target.packageName,
      "sessionCount" to controllers.size,
    )
  }

  private fun mediaCommandFallbackBroadcast(command: String): Boolean {
    val keyCode = when (command) {
      "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
      "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
      "toggle" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
      "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
      "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
      "stop" -> KeyEvent.KEYCODE_MEDIA_STOP
      else -> return false
    }
    val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
    return try {
      am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
      am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
      true
    } catch (e: Exception) {
      Log.w("ChukAssistant", "media broadcast fallback failed", e)
      false
    }
  }

  private fun volumeAdjust(direction: String, showUi: Boolean): Boolean {
    val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
    val adjust = when (direction.lowercase()) {
      "up", "raise", "louder", "lauter" -> AudioManager.ADJUST_RAISE
      "down", "lower", "leiser" -> AudioManager.ADJUST_LOWER
      "mute" -> AudioManager.ADJUST_MUTE
      "unmute" -> AudioManager.ADJUST_UNMUTE
      "toggle_mute" -> AudioManager.ADJUST_TOGGLE_MUTE
      else -> return false
    }
    val flags = if (showUi) AudioManager.FLAG_SHOW_UI else 0
    return try {
      am.adjustStreamVolume(AudioManager.STREAM_MUSIC, adjust, flags)
      true
    } catch (e: SecurityException) {
      Log.w("ChukAssistant", "volumeAdjust: blocked (DND policy?)", e)
      false
    }
  }

  private fun volumeSet(percent: Int, showUi: Boolean): Boolean {
    if (percent !in 0..100) return false
    val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    val target = (max * percent / 100).coerceIn(0, max)
    val flags = if (showUi) AudioManager.FLAG_SHOW_UI else 0
    return try {
      am.setStreamVolume(AudioManager.STREAM_MUSIC, target, flags)
      true
    } catch (e: SecurityException) {
      Log.w("ChukAssistant", "volumeSet: blocked (DND policy?)", e)
      false
    }
  }

  private fun volumeGet(): Map<String, Any?> {
    val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
      ?: return mapOf("available" to false)
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC)
    val percent = if (max > 0) (cur * 100 / max) else 0
    return mapOf(
      "available" to true,
      "current" to cur,
      "max" to max,
      "percent" to percent,
    )
  }

  private fun spotifySearch(query: String): Map<String, Any?> {
    val trimmed = query.trim()
    if (trimmed.isEmpty()) {
      return mapOf("launched" to false, "reason" to "empty_query")
    }

    // Require the Spotify app to be installed — never fall back to a browser.
    val spotifyPkg = "com.spotify.music"
    val installed = try {
      packageManager.getPackageInfo(spotifyPkg, 0)
      true
    } catch (_: PackageManager.NameNotFoundException) {
      false
    }
    if (!installed) {
      return mapOf("launched" to false, "reason" to "spotify_not_installed")
    }

    val encoded = Uri.encode(trimmed)
    val attempts = listOf(
      // Native scheme into the Spotify app.
      Intent(Intent.ACTION_VIEW, Uri.parse("spotify:search:$encoded"))
        .setPackage(spotifyPkg),
      // open.spotify.com link locked to the Spotify app (no browser).
      Intent(Intent.ACTION_VIEW, Uri.parse("https://open.spotify.com/search/$encoded"))
        .setPackage(spotifyPkg),
    )

    for (intent in attempts) {
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      if (intent.resolveActivity(packageManager) != null) {
        try {
          startActivity(intent)
          val scheme = intent.data?.scheme ?: ""
          return mapOf(
            "launched" to true,
            "via" to if (scheme == "spotify") "spotify_app" else "spotify_app_https",
          )
        } catch (e: Exception) {
          Log.w("ChukAssistant", "spotifySearch attempt failed", e)
        }
      }
    }
    return mapOf("launched" to false, "reason" to "no_spotify_handler")
  }

  private fun dismissAlarm(): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val intent = Intent(AlarmClock.ACTION_DISMISS_ALARM)
        .putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_NEXT)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      if (startResolvableActivity(intent)) {
        return true
      }
    }

    return showAlarms()
  }

  private fun showTimers(): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val intent = Intent(AlarmClock.ACTION_SHOW_TIMERS)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      if (startResolvableActivity(intent)) {
        return true
      }
    }

    return showAlarms()
  }

  private fun showAlarms(): Boolean {
    val intent = Intent(AlarmClock.ACTION_SHOW_ALARMS)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    return startResolvableActivity(intent)
  }

  private fun startResolvableActivity(intent: Intent): Boolean {
    return try {
      if (intent.resolveActivity(packageManager) == null) {
        false
      } else {
        startActivity(intent)
        true
      }
    } catch (_: Exception) {
      false
    }
  }

  private fun getLastKnownLocationMap(): Map<String, Any?> {
    val hasFine = hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
    val hasCoarse = hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
    if (!hasFine && !hasCoarse) {
      return mapOf("available" to false, "reason" to "permission_missing")
    }

    val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
    val providers = locationManager.getProviders(true)
    var best: Location? = null

    for (provider in providers) {
      val location = try {
        locationManager.getLastKnownLocation(provider)
      } catch (_: SecurityException) {
        null
      } ?: continue

      if (best == null || location.time > best!!.time) {
        best = location
      }
    }

    val location = best ?: return mapOf("available" to false, "reason" to "no_last_location")
    return mapOf(
      "available" to true,
      "latitude" to location.latitude,
      "longitude" to location.longitude,
      "accuracyMeters" to location.accuracy,
      "provider" to location.provider,
      "timestamp" to location.time,
    )
  }

  private fun isAssistantRoleHeld(): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      val roleManager = getSystemService(RoleManager::class.java)
      if (roleManager != null && roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
        return roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)
      }
    }

    val assistant = Settings.Secure.getString(contentResolver, "assistant") ?: return false
    return assistant.contains(packageName, ignoreCase = true)
  }

  private fun canDrawOverlays(): Boolean {
    return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
  }

  private fun isNotificationListenerEnabled(): Boolean {
    val expectedComponent = ComponentName(this, AssistNotificationListenerService::class.java).flattenToString()
    val enabledListeners = Settings.Secure.getString(
      contentResolver,
      "enabled_notification_listeners",
    ) ?: return false

    return enabledListeners
      .split(':')
      .map { it.trim() }
      .any {
        it.equals(expectedComponent, ignoreCase = true) ||
          it.contains(packageName, ignoreCase = true)
      }
  }

  private data class AppEntry(val label: String, val packageName: String)

  private fun listLauncherApps(): List<Map<String, String>> {
    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    val pm = packageManager
    val activities = pm.queryIntentActivities(intent, 0)
    val seen = HashSet<String>()
    val out = ArrayList<Map<String, String>>(activities.size)
    for (info in activities) {
      val pkg = info.activityInfo.packageName ?: continue
      if (!seen.add(pkg)) continue
      val label = info.loadLabel(pm).toString()
      out.add(mapOf("label" to label, "packageName" to pkg))
    }
    return out
  }

  private fun openAppByName(name: String): Map<String, Any?> {
    val query = name.trim()
    if (query.isEmpty()) {
      return mapOf("found" to false, "launched" to false, "reason" to "empty_name")
    }

    val pm = packageManager
    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    val activities = pm.queryIntentActivities(intent, 0)
    val entries = ArrayList<AppEntry>(activities.size)
    val seenPkgs = HashSet<String>()
    for (info in activities) {
      val pkg = info.activityInfo.packageName ?: continue
      if (!seenPkgs.add(pkg)) continue
      val label = info.loadLabel(pm).toString()
      entries.add(AppEntry(label = label, packageName = pkg))
    }

    val q = query.lowercase()
    val scored = entries.mapNotNull { entry ->
      val label = entry.label.lowercase()
      val pkg = entry.packageName.lowercase()
      val score = when {
        label == q -> 100
        label.startsWith(q) -> 90
        q.length >= 3 && label.contains(q) -> 80
        q.length >= 3 && pkg.contains(q) -> 60
        q.length >= 4 && labelTokensMatch(label, q) -> 70
        else -> 0
      }
      if (score == 0) null else entry to score
    }.sortedByDescending { it.second }

    if (scored.isEmpty()) {
      // The query is spoken user content and the labels are the user's app
      // list. Counts only.
      Log.d("ChukAssistant", "openAppByName: no match, installed=${entries.size}")
      return mapOf(
        "found" to false,
        "launched" to false,
        "reason" to "no_match",
        "installedCount" to entries.size,
      )
    }

    val best = scored.first().first
    Log.d("ChukAssistant", "openAppByName: '$query' -> '${best.label}' (${best.packageName}) score=${scored.first().second}")
    val launch = pm.getLaunchIntentForPackage(best.packageName)
    if (launch == null) {
      return mapOf(
        "found" to true,
        "launched" to false,
        "label" to best.label,
        "packageName" to best.packageName,
        "reason" to "no_launch_intent",
      )
    }

    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    return try {
      startActivity(launch)
      mapOf(
        "found" to true,
        "launched" to true,
        "label" to best.label,
        "packageName" to best.packageName,
      )
    } catch (e: Exception) {
      mapOf(
        "found" to true,
        "launched" to false,
        "label" to best.label,
        "packageName" to best.packageName,
        "reason" to (e.message ?: "launch_failed"),
      )
    }
  }

  /// Shows a place in the maps app of the device.
  ///
  /// The intent names no package, so Android picks the default maps app. Many
  /// devices have no Google Maps at all, so a hard coded package would fail
  /// there.
  /**
   * Shows a place in the device maps app, or starts navigation to it.
   *
   * An address is resolved to coordinates first, because `geo:0,0?q=<text>`
   * only hands the text to the maps app as a *search*: the user then lands on
   * a result list instead of on the place. With coordinates the pin is exact
   * and, for [navigate], the route is already computed.
   *
   * Runs off the platform thread — [Geocoder] does network work.
   */
  private fun openMaps(
    query: String,
    latitude: Double?,
    longitude: Double?,
    navigate: Boolean,
  ): Map<String, Any?> {
    val place = query.trim()
    var lat = latitude
    var lon = longitude
    var resolved = false

    if ((lat == null || lon == null) && place.isNotEmpty()) {
      val point = geocode(place)
      if (point != null) {
        lat = point.first
        lon = point.second
        resolved = true
      }
    }

    val hasPoint = lat != null && lon != null
    val uri = when {
      // Navigation: Google Maps and most forks take `google.navigation:`,
      // which opens the route screen instead of a place card.
      navigate && hasPoint -> Uri.parse("google.navigation:q=$lat,$lon")
      navigate && place.isNotEmpty() ->
        Uri.parse("google.navigation:q=${Uri.encode(place)}")
      // `geo:lat,lon?q=lat,lon(Label)` pins the exact point and labels it.
      // `geo:lat,lon?q=<text>` would search for the text near the point.
      hasPoint && place.isNotEmpty() ->
        Uri.parse("geo:$lat,$lon?q=$lat,$lon(${Uri.encode(place)})")
      hasPoint -> Uri.parse("geo:$lat,$lon?q=$lat,$lon")
      place.isNotEmpty() -> Uri.parse("geo:0,0?q=${Uri.encode(place)}")
      else -> return mapOf("launched" to false, "reason" to "empty_query")
    }

    val launched = launchMapsUri(uri)
    if (launched != null) {
      return launched + mapOf(
        "navigating" to navigate,
        "geocoded" to resolved,
        "latitude" to lat,
        "longitude" to lon,
      )
    }

    // No app took the navigation scheme (a device without Google Maps).
    // Fall back to a plain pin, which every maps app handles.
    if (navigate) {
      val fallback = when {
        hasPoint -> Uri.parse("geo:$lat,$lon?q=$lat,$lon(${Uri.encode(place)})")
        else -> Uri.parse("geo:0,0?q=${Uri.encode(place)}")
      }
      val second = launchMapsUri(fallback)
      if (second != null) {
        return second + mapOf(
          "navigating" to false,
          "geocoded" to resolved,
          "note" to "no_navigation_app",
        )
      }
    }
    return mapOf("launched" to false, "reason" to "no_maps_app")
  }

  /** Starts [uri], or null when nothing on the device handles it. */
  private fun launchMapsUri(uri: Uri): Map<String, Any?>? {
    val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    val handler = packageManager.resolveActivity(intent, 0) ?: return null
    val label = handler.loadLabel(packageManager).toString()
    return try {
      startActivity(intent)
      mapOf("launched" to true, "app" to label, "uri" to uri.toString())
    } catch (e: Exception) {
      mapOf("launched" to false, "app" to label, "reason" to (e.message ?: "launch_failed"))
    }
  }

  /** Address to coordinates, or null when the platform cannot resolve it. */
  private fun geocode(address: String): Pair<Double, Double>? {
    return try {
      @Suppress("DEPRECATION")
      val matches = Geocoder(this).getFromLocationName(address, 1)
      val first = matches?.firstOrNull() ?: return null
      Pair(first.latitude, first.longitude)
    } catch (e: Exception) {
      Log.w("ChukAssistant", "geocode failed", e)
      null
    }
  }

  private fun labelTokensMatch(label: String, query: String): Boolean {
    val tokens = label.split(Regex("[\\s\\-_./]+")).filter { it.isNotEmpty() }
    return tokens.any { it.startsWith(query) }
  }

  private fun isAccessibilityServiceEnabled(): Boolean {
    val expectedComponent = ComponentName(this, AssistAccessibilityService::class.java).flattenToString()

    val enabledServices = Settings.Secure.getString(
      contentResolver,
      Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
    ) ?: return false

    return enabledServices
      .split(':')
      .map { it.trim() }
      .any { it.equals(expectedComponent, ignoreCase = true) }
  }
}
