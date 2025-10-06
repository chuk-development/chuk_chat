import 'package:chuk_chat/supabase_config_private.dart';

class SupabaseConfig {
  static const String _placeholderUrl = 'https://your-project-ref.supabase.co';
  static const String _placeholderAnonKey = 'your-anon-public-key';

  static const String _envUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _envAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static String get supabaseUrl {
    if (_envUrl.isNotEmpty) return _envUrl;
    if (SupabaseConfigPrivate.supabaseUrl.isNotEmpty) {
      return SupabaseConfigPrivate.supabaseUrl;
    }
    return _placeholderUrl;
  }

  static String get supabaseAnonKey {
    if (_envAnonKey.isNotEmpty) return _envAnonKey;
    if (SupabaseConfigPrivate.supabaseAnonKey.isNotEmpty) {
      return SupabaseConfigPrivate.supabaseAnonKey;
    }
    return _placeholderAnonKey;
  }

  /// Returns true when the developer has not configured the Supabase credentials yet.
  static bool get isUsingPlaceholderValues {
    return supabaseUrl == _placeholderUrl ||
        supabaseAnonKey == _placeholderAnonKey;
  }
}
