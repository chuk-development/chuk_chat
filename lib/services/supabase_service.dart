import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

    if (SupabaseConfig.isUsingPlaceholderValues) {
      throw StateError(
        'Supabase credentials are not configured. Provide valid values via --dart-define or update lib/supabase_config.dart.',
      );
    }

    await Supabase.initialize(
      url: SupabaseConfig.supabaseUrl,
      anonKey: SupabaseConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );

    _initialized = true;
  }

  static GoTrueClient get auth => client.auth;

  static Future<Session?> refreshSession() async {
    final DateTime now = DateTime.now();
    if (_inFlightRefresh != null) {
      return _inFlightRefresh;
    }
    if (_lastRefreshTime != null &&
        now.difference(_lastRefreshTime!) < _kMinRefreshInterval) {
      return auth.currentSession;
    }

    Future<Session?> _performRefresh() async {
      try {
        final current = auth.currentSession;
        if (current == null) return null;
        final response = await auth.refreshSession();
        _lastRefreshTime = DateTime.now();
        return response.session ?? auth.currentSession;
      } on AuthException catch (error) {
        debugPrint('Failed to refresh session: ${error.message}');
        return null;
      }
    }

    try {
      _inFlightRefresh = _performRefresh();
      return await _inFlightRefresh;
    } finally {
      _inFlightRefresh = null;
    }
  }

  static Future<void> signOut() async {
    try {
      await auth.signOut();
    } on AuthException catch (error) {
      debugPrint('Failed to sign out: ${error.message}');
    }
  }
}
