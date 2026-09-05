# Diff for `app/lib/pages/messenger_shell.dart` — WS-7 taps

Status 2026-09-05: APPLIED by cowork-c6 itself (coordinator cowork-76's
decision after cowork-5c closed at its context limit). `messenger_shell_test`
16/16 green afterwards. Kept here as the record of what changed.

From cowork-c6 (P7 app-side notifications, bead cowork-o3j). The shell is the
only place that maps a `session_key` to a coworker, so it owns the two
notification hooks below. Both are small and additive.

## Imports (add)

```dart
import 'package:cowork/services/notifications/cowork_notifications.dart';
import 'package:cowork/services/notifications/notification_router.dart';
```

## initState / dispose

```dart
  @override
  void initState() {
    super.initState();
    ...existing...
    // WS-7: a tapped "answer ready" toast (local or push) names a thread.
    // Cold start included: the router keeps the target until we take it.
    NotificationRouter.instance.pending.addListener(_onNotificationTap);
    // The toast carries the coworker's name, never the answer.
    CoworkNotifications.instance.threadLabel = (String threadKey) =>
        _agentIdForThread(threadKey) == null
            ? 'CoWork'
            : (_roster.byId(_agentIdForThread(threadKey)!)?.name ?? 'CoWork');
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotificationTap());
  }

  @override
  void dispose() {
    NotificationRouter.instance.pending.removeListener(_onNotificationTap);
    ...existing...
  }
```

## New method

```dart
  /// Opens the thread a notification named. Selecting it is enough: the
  /// thread view replays from its cursor on `didUpdateWidget` (a different
  /// thread) or already did on `paired` (the same thread), and the
  /// "Answer ready" affordance comes from the replayed `while_away` done.
  void _onNotificationTap() {
    final NotificationTarget? target = NotificationRouter.instance.take();
    if (target == null || !mounted) return;
    final String? agentId = _agentIdForThread(target.sessionKey);
    if (agentId == null) return; // unknown thread: nothing to open
    _select(agentId, target.sessionKey);
    // Close the host's row and clear the OS toast for this thread.
    unawaited(CoworkNotifications.instance.onOpenedFromNotification(
      target.sessionKey,
      runId: target.runId,
    ));
  }
```

Notes for 5c:
- `_select` already flips `_showThreadOnNarrow`, so on a phone the tap lands
  in the chat, not the inbox.
- `_agentIdForThread` falls back to `_selectedAgentId` today; for a tap that
  fallback is fine (a thread we cannot place opens on the selected coworker),
  but if you prefer strictness, guard with `agent.threads.any(...)` first.
- No new test needed on your side beyond one that pumps the shell, sets
  `NotificationRouter.instance.open(NotificationTarget(sessionKey: ...))`
  and expects the thread selected; `NotificationRouter.instance.reset()` in
  `tearDown`.
