/// Turns one push into one local notification (docs/agents/NOTIFICATIONS.md,
/// "Push").
///
/// The same code runs for three senders:
///
///  * the FCM background handler (its own isolate, the app may be dead),
///  * the FCM foreground handler (`onMessage`),
///  * the UnifiedPush message handler (foreground, or the background engine
///    that the UnifiedPush service starts).
///
/// The push `data` carries a generic `title`/`body` and the sealed preview
/// (`preview_sealed`). This file opens the seal with the stored pairing and
/// shows the agent's name, the answer preview and the agent's face. Any
/// failure (no pairing, no seal for this channel, a bad tag, no secure
/// storage in the background) falls back to the generic text. It never
/// logs content.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/notifications/local_notifications.dart';
import 'package:chuk_chat/services/notifications/notification_avatar.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/notifications/sealed_preview.dart';

/// Loads the pairing whose channel key opens the seal.
typedef PairingLoader = Future<AgentsStoredPairing?> Function();

/// Finds a cached avatar PNG. No painting (the background cannot paint).
typedef CachedAvatarLookup = Future<String?> Function(String agentId);

/// The longest body a push toast shows. The host already clips to 300
/// characters; this only guards against a wrong sender.
const int kMaxPushBodyChars = 400;

/// The text of one push toast, after the seal was (or was not) opened.
@immutable
class PushToastText {
  const PushToastText({
    required this.sessionKey,
    required this.title,
    required this.body,
    this.runId,
    this.agentId,
  });

  final String sessionKey;
  final String title;
  final String body;
  final String? runId;
  final String? agentId;
}

class PushPresenter {
  PushPresenter._();

  /// Builds the toast text for [data]. [opened] is the opened seal, or null.
  /// [previewOn] is the user's preview setting. Returns null when the push
  /// names no thread.
  @visibleForTesting
  static PushToastText? textFor(
    Map<Object?, Object?> data, {
    SealedPreview? opened,
    required bool previewOn,
  }) {
    final NotificationTarget? target = NotificationTarget.fromData(data);
    final String? sessionKey = opened?.sessionKey ?? target?.sessionKey;
    if (sessionKey == null || sessionKey.isEmpty) return null;
    final String fallbackTitle = _text(data['title']) ?? 'Chuk Chat';
    final String fallbackBody =
        _text(data['body']) ?? LocalNotifications.defaultBody;
    final String? openedTitle = _text(opened?.title);
    final String? openedBody = _text(opened?.body);
    String body = previewOn && openedBody != null ? openedBody : fallbackBody;
    if (body.length > kMaxPushBodyChars) {
      body = '${body.substring(0, kMaxPushBodyChars - 1).trimRight()}…';
    }
    return PushToastText(
      sessionKey: sessionKey,
      title: openedTitle ?? fallbackTitle,
      body: body,
      runId: opened?.runId ?? target?.runId,
      agentId: opened?.agentId ?? _text(data['agent_id']),
    );
  }

  /// Shows the toast for one push [data] map. Never throws.
  ///
  /// [isVisible] returns true when the thread is open on screen; the push
  /// then shows nothing. The other seams are for tests.
  static Future<void> present(
    Map<Object?, Object?> data, {
    bool Function(String sessionKey)? isVisible,
    PairingLoader? loadPairing,
    CachedAvatarLookup? avatarLookup,
    LocalNotifications? notifications,
  }) async {
    try {
      final LocalNotifications local =
          notifications ?? LocalNotifications.instance;
      if (!local.isInitialized) await local.initialize();
      // The seal is keyed by channel, and every paired computer has its
      // own (CHAT-177): each one is tried.
      final SealedPreview? opened = await _open(
        data,
        loadPairing == null
            ? () => AgentsPairingStore().listPairings()
            : () async {
                final AgentsStoredPairing? one = await loadPairing();
                return one == null
                    ? const <AgentsStoredPairing>[]
                    : <AgentsStoredPairing>[one];
              },
      );
      final PushToastText? text = textFor(
        data,
        opened: opened,
        previewOn: await LocalNotifications.answerPreviewEnabled(),
      );
      if (text == null) return;
      if (isVisible != null && isVisible(text.sessionKey)) return;
      final CachedAvatarLookup lookup =
          avatarLookup ?? AgentNotificationAvatar.instance.cachedPath;
      String? icon;
      for (final String? id in <String?>[text.agentId, text.sessionKey]) {
        if (id == null || id.isEmpty) continue;
        icon = await lookup(id);
        if (icon != null) break;
      }
      await local.showText(
        sessionKey: text.sessionKey,
        title: text.title,
        body: text.body,
        runId: text.runId,
        iconPath: icon,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PushPresenter] failed: ${error.runtimeType}');
      }
    }
  }

  /// [present] for a raw push body (UnifiedPush): UTF-8 JSON of the same
  /// map FCM carries as `data`.
  static Future<void> presentBytes(
    List<int> content, {
    bool Function(String sessionKey)? isVisible,
  }) async {
    Map<Object?, Object?>? data;
    try {
      final Object? decoded = jsonDecode(utf8.decode(content));
      if (decoded is Map) data = decoded;
    } catch (_) {
      data = null;
    }
    if (data == null) {
      if (kDebugMode) debugPrint('[PushPresenter] body is not a JSON map');
      return;
    }
    await present(data, isVisible: isVisible);
  }

  static Future<SealedPreview?> _open(
    Map<Object?, Object?> data,
    Future<List<AgentsStoredPairing>> Function() loadPairings,
  ) async {
    if (data['preview_sealed'] == null) return null;
    try {
      final List<AgentsStoredPairing> pairings = await loadPairings().timeout(
        const Duration(seconds: 5),
      );
      for (final AgentsStoredPairing pairing in pairings) {
        final SealedPreview? opened = await openPreviewFromPushData(
          data,
          channelId: pairing.channelId,
          channelKey: pairing.channelKey,
        );
        if (opened != null) return opened;
      }
      return null;
    } catch (_) {
      // Secure storage can be locked in the background. Generic text then.
      return null;
    }
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final String text = value.trim();
    return text.isEmpty ? null : text;
  }
}
