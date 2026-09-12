package dev.chuk.chat.assist

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the microphone session alive while the overlay is backgrounded.
 * Runs as a foreground service of type `microphone` with a persistent
 * notification so Android does not kill the mic / process mid-conversation.
 */
class VoiceForegroundService : Service() {
  companion object {
    const val ACTION_START = "dev.chuk.chat.assist.voice.START"
    const val ACTION_STOP = "dev.chuk.chat.assist.voice.STOP"
    private const val CHANNEL_ID = "chuk_assistant_voice"
    private const val NOTIFICATION_ID = 4711
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP -> {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        return START_NOT_STICKY
      }
      else -> startInForeground()
    }
    return START_NOT_STICKY
  }

  private fun startInForeground() {
    createChannel()
    val notification: Notification = Notification.Builder(this, CHANNEL_ID)
      .setContentTitle("Chuk Chat")
      .setContentText("Der Assistent hört zu")
      .setSmallIcon(applicationInfo.icon)
      .setOngoing(true)
      .build()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
      )
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
  }

  private fun createChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
        mgr.createNotificationChannel(
          NotificationChannel(
            CHANNEL_ID,
            "Sprachassistent",
            NotificationManager.IMPORTANCE_LOW,
          ),
        )
      }
    }
  }
}
