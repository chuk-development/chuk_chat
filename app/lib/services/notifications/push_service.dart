/// Push registration: FCM token ↔ `cowork_device_tokens`.
///
/// The host never talks to FCM. It writes a row, the Edge Function
/// `notify-run` reads this app's token rows and pushes a generic
/// "answer ready" (no content) to every device of the user. This service
/// keeps the token row true:
///
///  * signed in → upsert `{user_id, device_id, token, platform}`;
///  * `onTokenRefresh` → upsert again;
///  * signed out → delete the row (a push must not reach a signed-out phone);
///  * a push tapped (warm or cold) → [NotificationRouter].
///
/// `device_id` is the CoWork device id from the pairing store — the same id
/// the host already knows this install by.
///
/// **Firebase is optional.** Without `google-services.json` (Android) or on
/// Linux, `Firebase.initializeApp()` throws; the transport reports itself
/// unavailable and the service does nothing. The desktop channel (the host's
/// own notify-send toast) and the "answer ready" state on reconnect do not
/// depend on push, so the build and the app run without it.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;

import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/notifications/notification_router.dart';
import 'package:cowork/services/supabase_service.dart';

/// A push message as the service sees it: only the `data` map matters.
@immutable
class PushMessage {
  const PushMessage(this.data);

  final Map<String, dynamic> data;

  NotificationTarget? get target => NotificationTarget.fromData(data);
}

/// What the service needs from the push provider. [FirebasePushTransport]
/// is the real one; tests pass a fake.
abstract class PushTransport {
  /// True when push works on this build/platform. False disables the
  /// service quietly.
  Future<bool> initialize();

  Future<String?> token();

  Stream<String> get onTokenRefresh;

  /// The user tapped a push while the app was in the background.
  Stream<PushMessage> get onMessageOpenedApp;

  /// The push that launched the app from a cold start, if any.
  Future<PushMessage?> initialMessage();

  Future<void> requestPermission();
}

/// The `cowork_device_tokens` row.
abstract class DeviceTokenStore {
  Future<void> upsert({
    required String userId,
    required String deviceId,
    required String token,
    required String platform,
  });

  Future<void> delete({required String userId, required String deviceId});
}

class PushService {
  PushService._();

  static final PushService instance = PushService._();

  PushTransport? _transport;
  DeviceTokenStore? _store;
  Future<String> Function()? _deviceId;
  String? _platform;

  StreamSubscription<AuthState>? _authSub;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<PushMessage>? _openedSub;

  String? _userId;
  String? _token;
  bool _started = false;

  bool get isStarted => _started;

  /// The user id the last upsert went to (test/diagnostic).
  String? get registeredUserId => _userId;

  /// Starts the service. All seams are injectable; the defaults are Firebase,
  /// Supabase and the pairing store. Never throws.
  Future<void> start({
    PushTransport? transport,
    DeviceTokenStore? store,
    Future<String> Function()? deviceId,
    Stream<AuthState>? authStates,
    String? Function()? currentUserId,
    String? platform,
  }) async {
    if (_started) return;
    final PushTransport t = transport ?? FirebasePushTransport();
    bool available;
    try {
      available = await t.initialize();
    } catch (error) {
      if (kDebugMode) debugPrint('[PushService] unavailable: $error');
      available = false;
    }
    if (!available) return;

    _transport = t;
    _store = store ?? const SupabaseDeviceTokenStore();
    _deviceId = deviceId ?? _defaultDeviceId;
    _platform = platform ?? _defaultPlatform();
    _started = true;

    // A tap that launched the app: route it before anything else.
    try {
      final PushMessage? initial = await t.initialMessage();
      _route(initial);
    } catch (_) {}
    _openedSub = t.onMessageOpenedApp.listen(_route, onError: (Object _) {});

    _tokenSub = t.onTokenRefresh.listen((String token) {
      _token = token;
      unawaited(_syncToken());
    }, onError: (Object _) {});

    final String? Function() userIdOf = currentUserId ?? _defaultUserId;
    _userId = userIdOf();
    final Stream<AuthState>? states = authStates ?? _defaultAuthStates();
    if (states != null) {
      _authSub = states.listen(
        (AuthState state) => _onAuth(state, userIdOf),
        onError: (Object _) {},
      );
    }
    if (_userId != null) {
      unawaited(_register());
    }
  }

  Future<void> _onAuth(AuthState state, String? Function() userIdOf) async {
    final AuthChangeEvent event = state.event;
    // An if-chain, not a switch: the enum gains members across gotrue
    // releases and an exhaustive switch would stop compiling.
    if (event == AuthChangeEvent.signedOut) {
      await _unregister();
      return;
    }
    if (event == AuthChangeEvent.signedIn ||
        event == AuthChangeEvent.initialSession ||
        event == AuthChangeEvent.userUpdated) {
      final String? id = userIdOf();
      if (id == null || id == _userId) return;
      _userId = id;
      await _register();
    }
  }

  /// Signed in: get a token and write the row.
  Future<void> _register() async {
    final PushTransport? t = _transport;
    if (t == null) return;
    try {
      await t.requestPermission();
      _token ??= await t.token();
    } catch (error) {
      if (kDebugMode) debugPrint('[PushService] token failed: $error');
    }
    await _syncToken();
  }

  Future<void> _syncToken() async {
    final String? userId = _userId;
    final String? token = _token;
    final DeviceTokenStore? store = _store;
    if (userId == null || token == null || store == null) return;
    try {
      await store.upsert(
        userId: userId,
        deviceId: await _deviceId!(),
        token: token,
        platform: _platform!,
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[PushService] upsert failed: $error');
    }
  }

  /// Signed out: the row goes, so no push reaches this device.
  Future<void> _unregister() async {
    final String? userId = _userId;
    _userId = null;
    final DeviceTokenStore? store = _store;
    if (userId == null || store == null) return;
    try {
      await store.delete(userId: userId, deviceId: await _deviceId!());
    } catch (error) {
      if (kDebugMode) debugPrint('[PushService] delete failed: $error');
    }
  }

  void _route(PushMessage? message) {
    final NotificationTarget? target = message?.target;
    if (target != null) NotificationRouter.instance.open(target);
  }

  static Future<String> _defaultDeviceId() async =>
      (await CoworkPairingStore().loadOrCreateIdentity()).deviceId;

  static String? _defaultUserId() {
    if (!SupabaseService.isInitialized) return null;
    return SupabaseService.auth.currentUser?.id;
  }

  static Stream<AuthState>? _defaultAuthStates() =>
      SupabaseService.isInitialized
      ? SupabaseService.auth.onAuthStateChange
      : null;

  static String _defaultPlatform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  /// Test seam.
  @visibleForTesting
  Future<void> reset() async {
    await _authSub?.cancel();
    await _tokenSub?.cancel();
    await _openedSub?.cancel();
    _authSub = null;
    _tokenSub = null;
    _openedSub = null;
    _transport = null;
    _store = null;
    _deviceId = null;
    _platform = null;
    _userId = null;
    _token = null;
    _started = false;
  }
}

/// `cowork_device_tokens` over the Supabase client (RLS: own rows only).
class SupabaseDeviceTokenStore implements DeviceTokenStore {
  const SupabaseDeviceTokenStore();

  static const String table = 'cowork_device_tokens';

  @override
  Future<void> upsert({
    required String userId,
    required String deviceId,
    required String token,
    required String platform,
  }) => SupabaseService.client.from(table).upsert(<String, dynamic>{
    'user_id': userId,
    'device_id': deviceId,
    'token': token,
    'platform': platform,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  }, onConflict: 'user_id,device_id');

  @override
  Future<void> delete({required String userId, required String deviceId}) =>
      SupabaseService.client
          .from(table)
          .delete()
          .eq('user_id', userId)
          .eq('device_id', deviceId);
}

/// Firebase Cloud Messaging. Only Android and iOS carry a push; everywhere
/// else [initialize] says no before touching Firebase.
class FirebasePushTransport implements PushTransport {
  FirebaseMessaging? _messaging;

  static bool get _pushPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<bool> initialize() async {
    if (!_pushPlatform) return false;
    try {
      // Throws without google-services.json / GoogleService-Info.plist. That
      // is the "keys missing" state: the build works, push is off.
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(coworkPushBackgroundHandler);
      _messaging = FirebaseMessaging.instance;
      return true;
    } catch (error) {
      if (kDebugMode) debugPrint('[PushService] Firebase off: $error');
      return false;
    }
  }

  @override
  Future<String?> token() => _messaging!.getToken();

  @override
  Stream<String> get onTokenRefresh => _messaging!.onTokenRefresh;

  @override
  Stream<PushMessage> get onMessageOpenedApp => FirebaseMessaging
      .onMessageOpenedApp
      .map((RemoteMessage m) => PushMessage(m.data));

  @override
  Future<PushMessage?> initialMessage() async {
    final RemoteMessage? m = await _messaging!.getInitialMessage();
    return m == null ? null : PushMessage(m.data);
  }

  @override
  Future<void> requestPermission() async {
    await _messaging!.requestPermission();
  }
}

/// Runs in a background isolate when a push arrives while the app is not
/// in the foreground. The system already shows the notification (it is a
/// `notification` message, not data-only), and the payload carries no
/// content to process, so there is nothing to do here. It exists so the
/// plugin has a registered handler and does not warn.
@pragma('vm:entry-point')
Future<void> coworkPushBackgroundHandler(RemoteMessage message) async {}
