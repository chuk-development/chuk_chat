// lib/services/local_chat_cache_service.dart
// Conditional export: SQLite on native, SharedPreferences on web.
export 'local_chat_cache_web.dart'
    if (dart.library.io) 'local_chat_cache_native.dart';
