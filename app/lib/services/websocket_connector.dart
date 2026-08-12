// lib/services/websocket_connector.dart
//
// WebSocket connector — conditional export.
// On native (dart:io) platforms, exports the IO implementation with
// certificate pinning. On web, exports a stub that uses the browser's
// native WebSocket API.

export 'websocket_connector_web.dart'
    if (dart.library.io) 'websocket_connector_io.dart';
