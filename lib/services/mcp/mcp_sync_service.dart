// AGENTS ADAPTATION. Upstream: chuk_chat/lib/services/mcp/mcp_sync_service.dart
// @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: the verbatim `chat_sync_service.dart` calls
// `McpSyncService.pullAndReconcile()` on every sync tick. Owner: cowork-47
// (services/mcp).
// Keep the public API signature-compatible with upstream so the imported chat
// sync compiles unchanged.

/// The tick that keeps Agents's connector set level with the cloud.
///
/// chuk_chat reconciles one row per connector here — adds, re-keys and
/// removes. Agents does not: its own mirror is ONE encrypted blob and the
/// device stays the authority on what is connected, so a tick that could
/// remove a connector or overwrite a live token would be a way to sign the
/// user out, not a feature (see `McpService.adoptMirrors`, which only ever
/// adds a connector this device is missing and only replaces a secret the
/// device can no longer use).
///
/// What the tick DOES do is pull. Until bead cowork-7zd this class was inert
/// and the mirrors were read exactly once, from `McpService.load()`, the first
/// time the connectors page was built. A user who never opened that page kept
/// an empty local store, so `McpStore.forwardPayloads` handed the Python host
/// no connectors at all and the agent could not call a server the user had
/// signed into in chuk_chat. And that single attempt was made whether or not
/// the mirrors were readable yet, then latched.
///
/// `ChatSyncService` calls this only when the client is online, signed in and
/// holds the encryption key — exactly the three conditions the mirrors need —
/// so it is the right clock for the pull. The work itself is throttled and
/// single-flight inside [McpService.adoptMirrors], so a 30-second tick costs a
/// comparison almost every time.
library;

import 'package:chuk_chat/services/mcp/mcp_service.dart';

class McpSyncService {
  McpSyncService._();

  /// Adopt whatever the encrypted mirrors hold that this device is missing.
  /// Never throws; a tick that cannot reach Supabase is simply retried by the
  /// next one.
  static Future<void> pullAndReconcile() => McpService.adoptMirrors();
}
