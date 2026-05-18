// lib/services/offline_queue_service.dart
//
// Conditional export: SQLite-backed queue on native, SharedPreferences on web.
//
// Public API is exposed via [OfflineQueueService] (singleton-style static API
// on the [OfflineQueueServiceBase] returned by `.instance`).
export 'offline_queue_service_web.dart'
    if (dart.library.io) 'offline_queue_service_native.dart';
