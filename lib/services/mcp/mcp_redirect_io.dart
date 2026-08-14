// lib/services/mcp/mcp_redirect_io.dart
//
// The loopback listener used on native platforms. See mcp_redirect.dart.

import 'dart:async';
import 'dart:io';

/// A one-shot HTTP server on 127.0.0.1 that catches the OAuth redirect.
class McpRedirectListener {
  McpRedirectListener._(this._server);

  final HttpServer _server;
  final Completer<Uri> _result = Completer<Uri>();

  /// Open a port and start listening.
  static Future<McpRedirectListener> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final listener = McpRedirectListener._(server);
    listener._listen();
    return listener;
  }

  /// The address to hand the authorization server.
  Uri get redirectUri =>
      Uri.parse('http://127.0.0.1:${_server.port}/mcp/callback');

  /// Completes with the full callback URL, including code and state.
  Future<Uri> get callback => _result.future;

  void _listen() {
    _server.listen((HttpRequest request) async {
      final uri = request.uri;
      final ok = uri.queryParameters.containsKey('code');

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_page(ok));
      await request.response.close();

      if (!_result.isCompleted) _result.complete(uri);
      await close();
    }, onError: (Object error) {
      if (!_result.isCompleted) _result.completeError(error);
    });
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  static String _page(bool ok) =>
      '<!doctype html><meta charset="utf-8">'
      '<title>Chuk Chat</title>'
      '<body style="font-family:system-ui;background:#111;color:#eee;'
      'display:flex;align-items:center;justify-content:center;height:100vh">'
      '<p>${ok ? 'Connected. You can close this tab and go back to Chuk Chat.' : 'Sign-in was cancelled. You can close this tab.'}</p>';
}
