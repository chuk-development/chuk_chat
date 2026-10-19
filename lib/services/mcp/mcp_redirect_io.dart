// lib/services/mcp/mcp_redirect_io.dart
//
// The loopback listener used on native platforms. See mcp_redirect.dart.

import 'dart:async';
import 'dart:io';

/// A one-shot HTTP server on the loopback that catches the OAuth redirect.
///
/// It binds BOTH loopback addresses — 127.0.0.1 and ::1 — because the address
/// the browser dials is `localhost`, and which of the two that resolves to
/// first is the OS's choice (Happy Eyeballs). One address bound and the browser
/// dialling the other means a connection-refused page instead of a sign-in.
/// A bind failure on one of the two is fine as long as the other holds.
class McpRedirectListener {
  McpRedirectListener._(this._servers);

  final List<HttpServer> _servers;
  final Completer<Uri> _result = Completer<Uri>();

  /// Open a port and start listening.
  static Future<McpRedirectListener> start() async {
    HttpServer? v4;
    HttpServer? v6;
    // Both binds must hand out the SAME port, so the port is chosen up front
    // and passed to bind rather than letting each server pick its own.
    for (int attempt = 0; attempt < 5; attempt++) {
      final int port = await _freePort();
      try {
        v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException {
        v4 = null;
        // The port was taken between the probe and the bind; try another.
        continue;
      }
      try {
        v6 = await HttpServer.bind(InternetAddress.loopbackIPv6, port);
      } on SocketException catch (e) {
        if (_isNoIpv6(e)) {
          // No IPv6 on this machine (containers, some Linux setups, kernels
          // booted with ipv6.disable=1): the v4 listener that is already
          // bound carries the sign-in alone.
          v6 = null;
          break;
        }
        // An address-in-use is a PORT collision — another process listens
        // on [::1] at this port — not "no IPv6". Keeping v4 would send the
        // OAuth code, carried in the callback URL, to that other process
        // whenever the browser resolves localhost to ::1 first. Drop the
        // bound v4 (closed, not leaked) and retry on a fresh port; the same
        // for anything else unexpected.
        await v4.close(force: true);
        v4 = null;
        v6 = null;
        continue;
      }
      break;
    }
    if (v4 == null && v6 == null) {
      throw const SocketException('no loopback port available');
    }
    final listener = McpRedirectListener._([
      ?v4,
      ?v6,
    ]);
    for (final HttpServer server in listener._servers) {
      listener._listen(server);
    }
    return listener;
  }

  /// "No IPv6 on this machine at all" — nothing can be listening on ::1, so
  /// the v4 listener carries the sign-in alone. EADDRNOTAVAIL (the address
  /// does not exist: Linux 99, macOS 49, Windows 10049) and EAFNOSUPPORT
  /// (IPv6 disabled in the kernel: Linux 97, macOS 47, Windows 10047). A
  /// kernel with `ipv6.disable=1` gives the latter, and a machine in that
  /// state would otherwise lose every OAuth sign-in.
  static bool _isNoIpv6(SocketException e) =>
      switch (e.osError?.errorCode) {
        99 || 49 || 10049 || 97 || 47 || 10047 => true,
        _ => false,
      };

  /// A port the kernel says is free. Racy by nature — the bind right after is
  /// the real test — but it keeps the retry loop honest instead of spinning.
  static Future<int> _freePort() async {
    final RawServerSocket probe = await RawServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = probe.port;
    await probe.close();
    return port;
  }

  /// The address to hand the authorization server.
  ///
  /// `localhost`, not `127.0.0.1`: RFC 8252 §7.3 says the authorization server
  /// must accept a variable port on a loopback redirect, and some servers
  /// (Fastmail is the one this was built against) normalise what they register
  /// to the name `localhost` and drop the port entirely. Sending `127.0.0.1`
  /// would make such a server register a URI we never send, and the sign-in
  /// would be refused before the browser even opened. The variable port lives
  /// in the URL the browser is sent to; the server matches on host + path.
  Uri get redirectUri =>
      Uri.parse('http://localhost:$_port/mcp/callback');

  int get _port => _servers.first.port;

  /// Completes with the full callback URL, including code and state.
  Future<Uri> get callback => _result.future;

  void _listen(HttpServer server) {
    server.listen(
      (HttpRequest request) async {
        final uri = request.uri;
        final ok = uri.queryParameters.containsKey('code');

        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_page(ok));
        await request.response.close();

        if (!_result.isCompleted) _result.complete(uri);
        await close();
      },
      onError: (Object error) {
        if (!_result.isCompleted) _result.completeError(error);
      },
    );
  }

  Future<void> close() async {
    for (final HttpServer server in _servers) {
      await server.close(force: true);
    }
  }

  static String _page(bool ok) =>
      '<!doctype html><meta charset="utf-8">'
      '<title>Agents</title>'
      '<body style="font-family:system-ui;background:#111;color:#eee;'
      'display:flex;align-items:center;justify-content:center;height:100vh">'
      '<p>${ok ? 'Connected. You can close this tab and go back to Agents.' : 'Sign-in was cancelled. You can close this tab.'}</p>';
}
