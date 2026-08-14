// lib/services/multiplex_tool_proxy.dart
//
// Tiny adapter that lets HTTP-shaped tool clients route through the
// multiplexed /v2/ws socket when a chat session is open. Returns null
// when no session is bound, signalling the caller to fall back to the
// existing v1 HTTP path.

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/multiplex_session.dart';

/// Result of [tryToolViaMultiplex]. Either holds a decoded body (when
/// the mux call returned successfully) or signals that the caller
/// should fall back to HTTP.
class MultiplexToolOutcome {
  const MultiplexToolOutcome._({this.body, this.fallback = false, this.error});

  /// Multiplex returned a result — caller should consume `body` directly.
  factory MultiplexToolOutcome.ok(Map<String, dynamic> body) =>
      MultiplexToolOutcome._(body: body);

  /// No multiplex session bound — caller should hit the v1 HTTP endpoint.
  factory MultiplexToolOutcome.fallback() =>
      const MultiplexToolOutcome._(fallback: true);

  /// Multiplex was bound but the tool errored. Caller should NOT retry
  /// over HTTP (the server already executed the call); surface the error
  /// to the user.
  factory MultiplexToolOutcome.errored(Object error) =>
      MultiplexToolOutcome._(error: error);

  final Map<String, dynamic>? body;
  final bool fallback;
  final Object? error;

  bool get isOk => body != null;

  bool get isError => error != null;
}

/// Attempt to send a tool call over the multiplex socket. Designed so
/// each existing HTTP tool handler can keep its post-response decoding
/// logic intact:
///
/// ```dart
/// final mux = await tryToolViaMultiplex(tool: 'brave_search', payload: body);
/// if (mux.isError) {
///   return 'Search error: ${mux.error}';
/// }
/// final data = mux.body ?? await _postOverHttp(...);
/// ```
Future<MultiplexToolOutcome> tryToolViaMultiplex({
  required String tool,
  required Map<String, dynamic> payload,
}) async {
  final connection = MultiplexSession.current;
  if (connection == null) {
    return MultiplexToolOutcome.fallback();
  }
  try {
    final result = await connection.tool(tool: tool, payload: payload);
    return MultiplexToolOutcome.ok(result);
  } on MultiplexException catch (e) {
    if (kDebugMode) {
      debugPrint('⚠️ [Multiplex tool=$tool] error: ${e.detail}');
    }
    return MultiplexToolOutcome.errored(e);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('⚠️ [Multiplex tool=$tool] unexpected: $e');
    }
    return MultiplexToolOutcome.errored(e);
  }
}
