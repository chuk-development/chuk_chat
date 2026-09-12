package dev.chuk.chat.assist

import android.app.PendingIntent
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class AssistNotificationListenerService : NotificationListenerService() {
  override fun onListenerConnected() {
    super.onListenerConnected()
    AssistantRuntime.notificationListener = this
  }

  override fun onListenerDisconnected() {
    AssistantRuntime.notificationListener = null
    super.onListenerDisconnected()
  }

  override fun onNotificationPosted(sbn: StatusBarNotification) {
    val extras = sbn.notification.extras
    val title = extras.getCharSequence("android.title")?.toString().orEmpty()
    val text = extras.getCharSequence("android.text")?.toString().orEmpty()

    AssistantRuntime.addNotification(
      mapOf(
        "packageName" to sbn.packageName.orEmpty(),
        "title" to title,
        "text" to text,
      ),
    )
  }

  /**
   * Fire a Stop/Cancel/Reset action on the timer notification of a clock app.
   * Returns true if an action was fired.
   */
  fun fireTimerDismissAction(): Boolean {
    val active = try {
      activeNotifications ?: return false
    } catch (e: SecurityException) {
      Log.w("ChukAssistant", "fireTimerDismissAction: no access", e)
      return false
    }

    Log.d("ChukAssistant", "fireTimerDismissAction: scanning ${active.size} active notifications")

    val clockPackages = listOf(
      "com.google.android.deskclock",
      "com.android.deskclock",
      "com.android.alarmclock",
      "ch.bitspin.timely",
      "com.urbandroid.lux",
      "org.lineageos.deskclock",
    )
    val stopRegex = Regex(
      "(?i)(stop|stopp|stoppen|anhalt|halt an|halten|beenden|beend|cancel|abbrech|löschen|loeschen|reset|zurücksetz|zuruecksetz|dismiss|verwerfen|aus|off|fertig|done|close|schliessen|schließen|x)",
    )
    val avoidRegex = Regex(
      "(?i)(snooze|schlummer|add|minute|extend|verlänger|verlanger|\\+|plus|repeat)",
    )

    fun looksLikeTimer(sbn: StatusBarNotification): Boolean {
      if (clockPackages.any { sbn.packageName.equals(it, ignoreCase = true) }) return true
      val ex = sbn.notification.extras
      val haystack = listOf(
        ex.getCharSequence("android.title")?.toString().orEmpty(),
        ex.getCharSequence("android.text")?.toString().orEmpty(),
        ex.getCharSequence("android.subText")?.toString().orEmpty(),
        sbn.notification.channelId.orEmpty(),
      ).joinToString(" ").lowercase()
      return haystack.contains("timer") || haystack.contains("kurzzeit")
    }

    // Deliberately no per-notification logging: the title and the text are
    // the user's messages.

    val candidates = active.filter { looksLikeTimer(it) }
    Log.d("ChukAssistant", "fireTimerDismissAction: ${candidates.size} timer-like candidates")

    for (sbn in candidates) {
      val actions = sbn.notification.actions
      if (actions == null || actions.isEmpty()) {
        Log.d("ChukAssistant", "  ${sbn.packageName}: no actions array (RemoteViews-only notif)")
        continue
      }

      // Try strict stop match first.
      var match = actions.firstOrNull { a ->
        val t = a.title?.toString().orEmpty()
        stopRegex.containsMatchIn(t) && !avoidRegex.containsMatchIn(t)
      }

      // Fallback: known clock package — try the LAST action (Google Clock orders
      // "+1 min", "Stop" → last is usually stop). Skip anything that looks like snooze/add.
      if (match == null && clockPackages.any { sbn.packageName.equals(it, ignoreCase = true) }) {
        match = actions.lastOrNull { a ->
          val t = a.title?.toString().orEmpty()
          !avoidRegex.containsMatchIn(t)
        }
      }

      if (match == null) {
        Log.d(
          "ChukAssistant",
          "  ${sbn.packageName}: no matching stop action in ${actions.map { it.title }}",
        )
        continue
      }

      try {
        match.actionIntent?.send()
        Log.d("ChukAssistant", "fireTimerDismissAction: fired '${match.title}' on ${sbn.packageName}")
        return true
      } catch (e: PendingIntent.CanceledException) {
        Log.w("ChukAssistant", "fireTimerDismissAction: pending intent canceled", e)
      }
    }
    return false
  }

  /** Cancel any timer notifications outright (last resort). */
  fun cancelTimerNotifications(): Boolean {
    val active = try {
      activeNotifications ?: return false
    } catch (e: SecurityException) {
      return false
    }
    val clockPackages = setOf(
      "com.google.android.deskclock",
      "com.android.deskclock",
      "com.android.alarmclock",
      "org.lineageos.deskclock",
    )
    var any = false
    for (sbn in active) {
      val haystack = listOf(
        sbn.notification.extras.getCharSequence("android.title")?.toString().orEmpty(),
        sbn.notification.extras.getCharSequence("android.text")?.toString().orEmpty(),
      ).joinToString(" ").lowercase()
      val isTimer = clockPackages.contains(sbn.packageName) ||
        haystack.contains("timer") || haystack.contains("kurzzeit")
      if (isTimer) {
        try {
          cancelNotification(sbn.key)
          any = true
        } catch (_: Exception) {
        }
      }
    }
    return any
  }
}
