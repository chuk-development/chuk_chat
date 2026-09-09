// lib/services/oauth_loopback_callback.dart

import 'dart:async';
import 'dart:io' as io;

/// The few colours that separate one provider's callback page from another.
///
/// The page itself is the same for every provider: one card, one heading, one
/// line telling the user the window can be closed. Only the palette changes.
class OAuthCallbackTheme {
  const OAuthCallbackTheme({
    required this.successColor,
    required this.failureColor,
    required this.background,
    required this.card,
    required this.border,
    required this.text,
  });

  final String successColor;
  final String failureColor;
  final String background;
  final String card;
  final String border;
  final String text;

  static const github = OAuthCallbackTheme(
    successColor: '#28a745',
    failureColor: '#dc3545',
    background: '#0d1117',
    card: '#161b22',
    border: '#30363d',
    text: '#c9d1d9',
  );

  static const google = OAuthCallbackTheme(
    successColor: '#34A853',
    failureColor: '#EA4335',
    background: '#202124',
    card: '#292a2d',
    border: '#3c4043',
    text: '#e8eaed',
  );
}

/// The page the browser lands on after the provider redirects back.
String oauthCallbackHtml(
  String title,
  bool success,
  OAuthCallbackTheme theme,
) {
  final color = success ? theme.successColor : theme.failureColor;
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

/// Serves the loopback redirect of a desktop OAuth flow on [port].
///
/// The provider sends the browser to `http://127.0.0.1:<port>/callback`, this
/// server answers it, hands the authorization code to [codeCompleter] and
/// shows the user a page saying the window can be closed.
///
/// Every completion is guarded on `isCompleted`: a browser that replays the
/// redirect (a refresh, a restored tab) would otherwise complete the same
/// future twice, which throws inside the listen handler where nothing catches
/// it. The caller closes the returned server when its flow ends.
Future<io.HttpServer> startOAuthLoopbackServer({
  required int port,
  required String expectedState,
  required Completer<String> codeCompleter,
  required String connectedTitle,
  required OAuthCallbackTheme theme,
}) async {
  final server = await io.HttpServer.bind('127.0.0.1', port);

  server.listen((io.HttpRequest request) async {
    if (request.uri.path != '/callback') {
      // The callback page makes the browser ask for /favicon.ico. Answering
      // it keeps that connection from staying open until the server closes.
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }

    final code = request.uri.queryParameters['code'];
    final state = request.uri.queryParameters['state'];
    final error = request.uri.queryParameters['error'];

    Future<void> respond(String title, bool success) async {
      request.response
        ..statusCode = 200
        ..headers.set('Content-Type', 'text/html; charset=utf-8')
        ..write(oauthCallbackHtml(title, success, theme));
      await request.response.close();
    }

    if (error != null) {
      if (!codeCompleter.isCompleted) {
        codeCompleter.completeError(Exception('OAuth error: $error'));
      }
      await respond('Authorization Failed', false);
      return;
    }

    if (state != expectedState) {
      if (!codeCompleter.isCompleted) {
        codeCompleter.completeError(Exception('CSRF state mismatch'));
      }
      await respond('Security Error', false);
      return;
    }

    if (code == null) {
      // Settle the completer here too, or the caller sits on its five-minute
      // timeout for a redirect that already told us it has nothing.
      if (!codeCompleter.isCompleted) {
        codeCompleter.completeError(
          Exception('OAuth callback returned no authorization code'),
        );
      }
      request.response
        ..statusCode = 400
        ..write('Missing authorization code');
      await request.response.close();
      return;
    }

    if (!codeCompleter.isCompleted) {
      codeCompleter.complete(code);
    }
    await respond(connectedTitle, true);
  }, onError: (Object error) {
    // A socket-level failure never reaches the handler above, so without this
    // the completer would never settle and the flow would hang.
    if (!codeCompleter.isCompleted) {
      codeCompleter.completeError(error);
    }
  });

  return server;
}
