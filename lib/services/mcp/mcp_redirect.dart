// lib/services/mcp/mcp_redirect.dart
//
// Where the browser lands after the reader has signed in.
//
// A loopback listener (RFC 8252) is used on every native platform, phone
// included: the app opens a port on 127.0.0.1, the browser is sent there,
// and the code arrives in the query string. It needs no custom URL scheme,
// no manifest entry and no plugin — which is why it works the same on
// Android, Linux, Windows and macOS.

export 'mcp_redirect_stub.dart'
    if (dart.library.io) 'mcp_redirect_io.dart';
