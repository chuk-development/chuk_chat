package dev.chuk.chat.assist

object AssistantRuntime {
  @Volatile
  var accessibilityService: AssistAccessibilityService? = null

  @Volatile
  var overlayActivity: AssistOverlayActivity? = null

  @Volatile
  var notificationListener: AssistNotificationListenerService? = null

  @Volatile
  var lastContext: Map<String, Any?> = mapOf(
    "packageName" to "",
    "className" to "",
    "visibleText" to "",
    "timestamp" to 0L,
  )

  /**
   * True only while an assistant surface is on screen.
   *
   * The accessibility service keeps running after the surface is dismissed, so
   * without this gate it would go on capturing the text of whatever the user
   * does next — a banking app, a chat — into a process-global field.
   */
  @Volatile
  var sessionActive: Boolean = false

  private val emptyContext: Map<String, Any?> = mapOf(
    "packageName" to "",
    "className" to "",
    "visibleText" to "",
    "timestamp" to 0L,
  )

  /** Drops captured screen text and buffered notifications when a session ends. */
  fun reset() {
    lastContext = emptyContext
    synchronized(notificationLock) {
      notifications.clear()
    }
  }

  private val notificationLock = Any()
  private val notifications: ArrayDeque<Map<String, String>> = ArrayDeque()

  fun addNotification(item: Map<String, String>) {
    synchronized(notificationLock) {
      notifications.addFirst(item)
      while (notifications.size > 30) {
        notifications.removeLast()
      }
    }
  }

  fun readNotifications(): List<Map<String, String>> {
    synchronized(notificationLock) {
      return notifications.toList()
    }
  }
}
