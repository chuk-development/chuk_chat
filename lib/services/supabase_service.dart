import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/auth_trace.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/session_refresh_scheduler.dart';
import 'package:chuk_chat/supabase_config.dart';

class SupabaseService {
  const SupabaseService._();

  static bool _initialized = false;
  static DateTime? _lastRefreshTime;
  static Future<Session?>? _inFlightRefresh;
  static const Duration _kMinRefreshInterval = Duration(seconds: 30);

  /// How much life an access token must have left to be handed out as is.
  ///
  /// Every real refresh rotates the refresh token. If the response is lost —
  /// a dropped mobile connection, a killed app — the server has already
  /// retired the old token while this device still holds it, and the next
  /// refresh fails with `refresh_token_already_used`. Once the access token
  /// expires, gotrue then signs the user out. Callers want a usable token,
  /// not a fresh one, so a session with time left is returned untouched and
  /// the rotation count drops from one every 30 s to roughly one per hour.
  ///
  /// With Agents the refresh token is also SHARED with the paired host (bead
  /// cowork-2n1), so a spent token logs out two devices. Only
  /// [SessionRefreshScheduler] and [SupabaseAccountSession], which refresh at
  /// 60 s left, reach the network on their own.
  static const Duration _kRefreshLeeway = Duration(minutes: 10);

  static SupabaseClient get client {
    if (!_initialized) {
      throw StateError(
        'Call SupabaseService.initialize() before accessing the client.',
      );
    }
    return Supabase.instance.client;
  }

  static Future<void> initialize() async {
    if (_initialized) return;

    // Load .env file for desktop development (if no --dart-define values)
    await SupabaseConfig.initialize();

    if (SupabaseConfig.isUsingPlaceholderValues) {
      throw StateError(
        'Supabase credentials are not configured.\n'
        'For desktop: Create a .env file with SUPABASE_URL and SUPABASE_ANON_KEY\n'
        'For mobile: Use --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
      );
    }

    await Supabase.initialize(
      url: SupabaseConfig.supabaseUrl,
      publishableKey: SupabaseConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        // Agents-only (bead cowork-2n1): the app's refresh must respect the
        // paired host, which shares the single-use refresh token. gotrue's
        // own timer cannot know about the host; SessionRefreshScheduler does,
        // and it refreshes on its own when no relay is in use.
        autoRefreshToken: false,
      ),
    );

    _initialized = true;
    initializedListenable.value = true;
    SessionRefreshScheduler.instance.start();
  }

  static GoTrueClient get auth => client.auth;

  /// Whether [initialize] has completed. Lets callers (and tests) read
  /// auth state opportunistically without risking a [StateError].
  static bool get isInitialized => _initialized;

  /// Flips once [initialize] has completed. `main()` starts initialisation
  /// without awaiting it and runs the app immediately, so a widget can be
  /// built before the client exists; this lets it wait for the client instead
  /// of polling for it or giving up for its whole lifetime.
  static final ValueNotifier<bool> initializedListenable =
      ValueNotifier<bool>(false);


  /// Whether [session] is close enough to expiry that it must be renewed.
  @visibleForTesting
  static bool sessionNeedsRefresh(Session session) {
    if (session.isExpired) return true;
    final int? expiresAt = session.expiresAt;
    if (expiresAt == null) return true;
    final DateTime expiry = DateTime.fromMillisecondsSinceEpoch(
      expiresAt * 1000,
    );
    return expiry.difference(DateTime.now()) <= _kRefreshLeeway;
  }

  /// Returns a session whose access token is usable right now.
  ///
  /// Set [force] to rotate the token even when the current one still has
  /// life left — only a caller that must prove the session is still valid
  /// server-side needs that.
  static Future<Session?> refreshSession({bool force = false}) async {
    final DateTime now = DateTime.now();
    if (_inFlightRefresh != null) {
      return await _inFlightRefresh!;
    }
    final Session? current = auth.currentSession;
    if (current == null) return null;
    // A token with time left is handed back as is: refreshing it buys
    // nothing and costs one rotation.
    if (!force && !sessionNeedsRefresh(current)) {
      return current;
    }
    // If the cached session is already expired, bypass the throttle — we MUST
    // refresh, otherwise callers receive an expired token and hit 401s.
    // A forced refresh must reach the server: that is the whole point of
    // asking for one.
    final bool bypassThrottle = force || current.isExpired;
    if (!bypassThrottle &&
        _lastRefreshTime != null &&
        now.difference(_lastRefreshTime!) < _kMinRefreshInterval) {
      return current;
    }

    Future<Session?> performRefresh() async {
      final DateTime startedAt = DateTime.now();
      try {
        final current = auth.currentSession;
        if (current == null) {
          _lastRefreshTime = startedAt;
          return null;
        }
        final response = await auth.refreshSession();
        _lastRefreshTime = DateTime.now();
        return response.session ?? auth.currentSession;
      } on AuthException catch (error) {
        _lastRefreshTime = DateTime.now();
        // Check if this is a network error - keep existing session
        if (NetworkStatusService.isNetworkError(error)) {
          if (kDebugMode) {
            debugPrint(
              '📴 Session refresh failed (network): ${error.message} - keeping session',
            );
          }
          return auth.currentSession; // Keep existing session on network error
        }
        // Actual auth error (e.g., token revoked)
        if (kDebugMode) {
          debugPrint('⚠️ Session refresh auth error: ${error.message}');
        }
        return null;
      } catch (e) {
        // Generic error (SocketException, etc.) - likely network related
        _lastRefreshTime = DateTime.now();
        if (kDebugMode) {
          debugPrint('📴 Session refresh error: $e - keeping session');
        }
        return auth.currentSession; // Keep existing session
      }
    }

    try {
      _inFlightRefresh = performRefresh();
      return await _inFlightRefresh;
    } finally {
      _inFlightRefresh = null;
    }
  }

  /// Force-refresh the session, bypassing the throttle.
  /// Returns null if the refresh token has been revoked (auth error).
  /// Throws on network errors so caller can distinguish.
  static Future<Session?> forceRefreshSession() async {
    if (_inFlightRefresh != null) {
      return await _inFlightRefresh!;
    }
    // Bypass throttle by not checking _lastRefreshTime
    Future<Session?> performForceRefresh() async {
      try {
        final current = auth.currentSession;
        if (current == null) return null;
        final response = await auth.refreshSession();
        _lastRefreshTime = DateTime.now();
        return response.session ?? auth.currentSession;
      } on AuthException catch (error) {
        _lastRefreshTime = DateTime.now();
        if (NetworkStatusService.isNetworkError(error)) {
          rethrow; // Let caller know it's a network issue
        }
        // Token revoked or invalid
        return null;
      }
    }

    try {
      _inFlightRefresh = performForceRefresh();
      return await _inFlightRefresh;
    } finally {
      _inFlightRefresh = null;
    }
  }

  /// Signs the user out. Every caller is a deliberate sign-out — the app has
  /// no other reason to call it — so it is traced: a sign-out the user did not
  /// ask for has to be attributable to the line that made it.
  static Future<void> signOut() async {
    AuthTrace.note(
      'app-signout',
      detail: <String, Object?>{
        'by': StackTrace.current
            .toString()
            .split('\n')
            .skip(1)
            .take(2)
            .join(' | '),
      },
    );
    try {
      await auth.signOut();
    } on AuthException catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to sign out: ${error.message}');
      }
    }
  }
}
