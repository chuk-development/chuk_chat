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


  /// How much life an access token must have left to be handed back untouched.
  ///
  /// The chuk-verbatim callers (the send path, the 401 handlers, the credit
  /// display) ask for a session, not for a new one. Every real refresh spends
  /// the single-use refresh token that this app SHARES with the paired host
  /// (bead cowork-2n1), and a spent token turns into a logout the moment the
  /// access token lapses. So a token with life left is the answer, and only
  /// [SessionRefreshScheduler] and [SupabaseAccountSession] — which refresh at
  /// 60 s left — actually reach the network.
  static const Duration _kRefreshLeeway = Duration(minutes: 10);

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
  /// Set [force] to spend the refresh token even when the current one still
  /// has life left.
  static Future<Session?> refreshSession({bool force = false}) async {
    final DateTime now = DateTime.now();
    if (_inFlightRefresh != null) {
      return await _inFlightRefresh!;
    }
    final Session? current = auth.currentSession;
    if (current != null && !force && !sessionNeedsRefresh(current)) {
      return current;
    }
    // If the cached session is already expired, bypass the throttle — we MUST
    // refresh, otherwise callers receive an expired token and hit 401s.
    final bool sessionExpired = current != null && current.isExpired;
    if (!sessionExpired &&
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
