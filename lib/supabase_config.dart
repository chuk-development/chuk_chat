class SupabaseConfig {
  static const String _hardcodedUrl =
      'https://xooposctxswumvgtyqlg.supabase.co';
  static const String _hardcodedAnonKey =
      'sb_publishable_g4Yz0bTZPB27ig8E1ROGzw_rprl-7U7';

  static const String _envUrl = String.fromEnvironment('SUPABASE_URL');
  static const String _envAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static String get supabaseUrl {
    if (_envUrl.isNotEmpty) return _envUrl;
    return _hardcodedUrl;
  }

  static String get supabaseAnonKey {
    if (_envAnonKey.isNotEmpty) return _envAnonKey;
    return _hardcodedAnonKey;
  }

  /// Returns true when the developer has not configured the Supabase credentials yet.
  static bool get isUsingPlaceholderValues {
    return false;
  }
}
