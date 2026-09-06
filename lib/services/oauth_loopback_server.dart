import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

/// Colours of the small page the browser shows after the redirect.
class OAuthResultPageTheme {
  const OAuthResultPageTheme({
    required this.successColor,
    required this.errorColor,
    required this.background,
    required this.card,
    required this.border,
    required this.text,
  });

  final String successColor;
  final String errorColor;
  final String background;
  final String card;
  final String border;
  final String text;
}

/// Loopback HTTP server for the desktop OAuth redirect.
///
/// The provider redirects the browser to `http://127.0.0.1:<port>/callback`.
/// This server takes the `code` from that request, answers with a small
/// "you can close this window" page and completes [code].
///
/// Every provider service used to carry its own copy of this, differing only
/// in the port, the page colours and the wording of two error messages.
class OAuthLoopbackServer {
  OAuthLoopbackServer({
    required this.port,
    required this.successTitle,
    required this.theme,
  });

  final int port;

  /// Headline of the success page, e.g. `GitHub Connected!`.
  final String successTitle;
  final OAuthResultPageTheme theme;

  io.HttpServer? _server;
  Completer<String>? _completer;
  String? _expectedState;

  /// Redirect URI to send to the provider.
  String get redirectUri => 'http://127.0.0.1:$port/callback';

  /// Fresh, unguessable `state` value for one authorization run.
  static String generateState() {
    final random = Random.secure();
    final values = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(values);
  }

  /// Binds the port and starts listening. [expectedState] is compared against
  /// the `state` the provider sends back.
  Future<void> start({required String expectedState}) async {
    await stop();
    _expectedState = expectedState;
    _completer = Completer<String>();
    _server = await io.HttpServer.bind('127.0.0.1', port);
    _server!.listen(_handle);
  }

  /// Completes with the authorization code, or with an error when the user
  /// denied access or the `state` did not match.
  Future<String> get code {
    final completer = _completer;
    if (completer == null) {
      throw StateError('start() must run before the code is awaited');
    }
    return completer.future;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handle(io.HttpRequest request) async {
    if (request.uri.path != '/callback') return;

    final code = request.uri.queryParameters['code'];
    final state = request.uri.queryParameters['state'];
    final error = request.uri.queryParameters['error'];

    if (error != null) {
      _fail(Exception('OAuth error: $error'));
      await _respond(request, 200, _page('Authorization Failed', false));
      return;
    }

    if (state != _expectedState) {
      _fail(Exception('CSRF state mismatch'));
      await _respond(request, 200, _page('Security Error', false));
      return;
    }

    if (code == null) {
      await _respond(request, 400, 'Missing authorization code');
      return;
    }

    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.complete(code);
    }
    await _respond(request, 200, _page(successTitle, true));
  }

  void _fail(Object error) {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  Future<void> _respond(io.HttpRequest request, int status, String body) async {
    request.response
      ..statusCode = status
      ..headers.set('Content-Type', 'text/html; charset=utf-8')
      ..write(body);
    await request.response.close();
  }

  String _page(String title, bool success) {
    final color = success ? theme.successColor : theme.errorColor;
    return '<!DOCTYPE html><html><head><title>$title</title>'
        '<style>body{font-family:sans-serif;display:flex;'
        'justify-content:center;align-items:center;'
        'height:100vh;margin:0;background:${theme.background};'
        'color:${theme.text};}'
        '.c{text-align:center;padding:40px;background:${theme.card};'
        'border-radius:12px;border:1px solid ${theme.border};}'
        'h1{color:$color;}</style></head><body>'
        '<div class="c"><h1>$title</h1>'
        '<p>You can close this window.</p></div></body></html>';
  }
}
