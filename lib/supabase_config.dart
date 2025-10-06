class SupabaseConfig {
  /// Project URL taken from your Supabase settings.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://your-project-ref.supabase.co',
  );

  /// The anon public key from your Supabase project settings.
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'your-anon-public-key',
  );

  /// Returns true when the developer has not configured the Supabase credentials yet.
  static bool get isUsingPlaceholderValues {
    return supabaseUrl.contains('your-project-ref') ||
        supabaseAnonKey.contains('your-anon-public-key');
  }
}
