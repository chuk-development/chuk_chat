/// Push without Google Play: UnifiedPush (docs/agents/NOTIFICATIONS.md,
/// "Phones without Google Play").
///
/// A distributor app (ntfy, or any other) keeps one connection for all apps.
/// The app registers with it and gets an endpoint URL. That URL is the
/// "token" of this transport: [PushService] writes it to
/// `cowork_device_tokens` with `platform = 'unifiedpush'`, and `notify-run`
/// POSTs the push data (JSON) to it. The message handler opens the seal like
/// the FCM handler ([PushPresenter]).
///
/// Android only. When the app is not running, the UnifiedPush service starts
/// a Flutter engine that runs `main(['--unifiedpush-bg'])`. `main` then calls
/// [unifiedPushBackgroundMain] and shows the toast without the UI.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:unifiedpush/unifiedpush.dart' as up;

import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/notifications/local_notifications.dart';
import 'package:chuk_chat/services/notifications/push_presenter.dart';
import 'package:chuk_chat/services/notifications/push_service.dart';

/// The argument the UnifiedPush service gives `main` in its own engine.
const String kUnifiedPushBackgroundArg = '--unifiedpush-bg';

/// The one registration this app uses.
const String kUnifiedPushInstance = 'chuk_agents';

/// The `platform` value of a UnifiedPush row in `cowork_device_tokens`.
const String kUnifiedPushPlatform = 'unifiedpush';

class UnifiedPushTransport implements PushTransport {
  final StreamController<String> _endpoints =
      StreamController<String>.broadcast();
  final Completer<String?> _firstEndpoint = Completer<String?>();
  String? _endpoint;

  static bool get _platformOk =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True when a distributor exists and the registration started.
  @override
  Future<bool> initialize() async {
    if (!_platformOk) return false;
    try {
      await up.UnifiedPush.initialize(
        onNewEndpoint: _onNewEndpoint,
        onRegistrationFailed: (up.FailedReason reason, String instance) {
          if (kDebugMode) {
            debugPrint('[UnifiedPush] registration failed: ${reason.name}');
          }
          if (!_firstEndpoint.isCompleted) _firstEndpoint.complete(null);
        },
        onUnregistered: (String instance) {
          if (kDebugMode) debugPrint('[UnifiedPush] unregistered');
        },
        onMessage: (up.PushMessage message, String instance) {
          unawaited(
            PushPresenter.presentBytes(
              message.content,
              isVisible: AgentsNotifications.instance.isThreadVisible,
            ),
          );
        },
      );
      if (!await _pickDistributor()) return false;
      await up.UnifiedPush.register(instance: kUnifiedPushInstance);
      return true;
    } catch (error) {
      if (kDebugMode) debugPrint('[UnifiedPush] off: $error');
      return false;
    }
  }

  /// Uses the saved or the default distributor. When there is none of
  /// those but some are installed, the first one is saved and used.
  static Future<bool> _pickDistributor() async {
    if (await up.UnifiedPush.tryUseCurrentOrDefaultDistributor()) return true;
    final List<String> all = await up.UnifiedPush.getDistributors();
    if (all.isEmpty) return false;
    await up.UnifiedPush.saveDistributor(all.first);
    return true;
  }

  void _onNewEndpoint(up.PushEndpoint endpoint, String instance) {
    if (instance != kUnifiedPushInstance) return;
    _endpoint = endpoint.url;
    if (!_firstEndpoint.isCompleted) _firstEndpoint.complete(endpoint.url);
    _endpoints.add(endpoint.url);
  }

  @override
  Future<String?> token() async {
    final String? known = _endpoint;
    if (known != null) return known;
    return _firstEndpoint.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
  }

  @override
  Stream<String> get onTokenRefresh => _endpoints.stream;

  /// Taps come through the local notification plugin, not through here.
  @override
  Stream<PushMessage> get onMessageOpenedApp =>
      const Stream<PushMessage>.empty();

  @override
  Future<PushMessage?> initialMessage() async => null;

  @override
  Future<void> requestPermission() async {
    await LocalNotifications.instance.requestPermission();
  }
}

/// The entry of the background engine that the UnifiedPush service starts
/// when the app is not running. No UI: it only wires the message handler,
/// so the queued message reaches [PushPresenter].
Future<void> unifiedPushBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await up.UnifiedPush.initialize(
      onMessage: (up.PushMessage message, String instance) {
        unawaited(PushPresenter.presentBytes(message.content));
      },
    );
  } catch (error) {
    if (kDebugMode) debugPrint('[UnifiedPush] background init: $error');
  }
}
