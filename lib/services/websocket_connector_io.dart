// lib/services/websocket_connector_io.dart
//
// Native (dart:io) WebSocket connector with certificate pinning.
// Uses dart:io's WebSocket.connect() with a pinned HttpClient so that
// the same SHA-256 fingerprint validation applied to Dio/HTTP requests
// also protects WebSocket connections.
//
// This file imports dart:io and must NOT be imported on web.

import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:chuk_chat/utils/certificate_pinning.dart';
import 'package:chuk_chat/utils/certificate_pinning_io.dart' as pinning_io;

/// Create a [WebSocketChannel] with certificate pinning on native platforms.
///
/// In release mode, creates a pinned [HttpClient] and passes it to
/// [WebSocket.connect] so that the server certificate is validated against
/// the configured SHA-256 pins. In debug mode, uses the default client
/// (no pinning) to allow proxy tools like Charles/mitmproxy.
Future<WebSocketChannel> connectWebSocket(Uri url) async {
  if (CertificatePinning.isEnabled) {
    final pinnedClient = pinning_io.createPinnedHttpClient(
      CertificatePinning.configuredPins,
    );

    try {
      final socket = await WebSocket.connect(
        url.toString(),
        customClient: pinnedClient,
      );

      return IOWebSocketChannel(socket);
    } finally {
      pinnedClient.close();
    }
  }

  // Debug mode — no pinning, use standard IOWebSocketChannel.connect
  return IOWebSocketChannel.connect(url);
}
