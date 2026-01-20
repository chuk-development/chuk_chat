/// Supabase configuration.
///
/// Credentials are loaded from compile-time environment variables:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
///
/// Or use the .env file with the run.sh helper script.
class SupabaseConfig {
  static const String _envUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _envAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static const String _placeholderUrl = 'https://your-project.supabase.co';
  static const String _placeholderKey = 'your-anon-key-here';

  static String get supabaseUrl {
    if (_envUrl.isNotEmpty) return _envUrl;
    return _placeholderUrl;
  }

  static String get supabaseAnonKey {
    if (_envAnonKey.isNotEmpty) return _envAnonKey;
    return _placeholderKey;
  }

  /// Returns true when the developer has not configured the Supabase credentials yet.
  static bool get isUsingPlaceholderValues {
    return _envUrl.isEmpty || _envAnonKey.isEmpty;
  }
}
