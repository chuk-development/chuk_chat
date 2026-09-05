// COWORK STUB. Upstream: chuk_chat/lib/services/mcp/mcp_sync_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: the verbatim `chat_sync_service.dart` calls `McpSyncService.pullAndReconcile()`
// on every sync tick. CoWork mirrors connectors through `McpConnectorSync`
// (services/mcp/mcp_connector_sync.dart) on its own schedule, so this hook is
// a no-op. Owner: cowork-47 (services/mcp).
// Keep the public API signature-compatible with upstream so the imported chat sync compiles unchanged.

/// Background reconcile of MCP connectors with the cloud mirror. Inert in
/// CoWork, deliberately.
///
/// chuk_chat syncs one row per connector and reconciles them on a tick. CoWork
/// mirrors the whole connector set as ONE encrypted blob
/// (`McpConnectorSync`), pulled by `McpService.load()` when the app starts and
/// pushed on every connect and disconnect. A 30-second tick would decrypt that
/// blob over and over for a set that only changes when the user touches it.
///
/// It would also be actively wrong for tokens: the mirror is written on connect
/// and disconnect, so it is routinely the OLDER copy of a record this device
/// has since refreshed. `McpService` adopts a mirrored secret only when the
/// local one is unusable, precisely so a stale blob cannot sign the user out —
/// and a poll would be nothing but repeated chances to hit that path.
///
/// If connectors ever need to appear on a second device without a restart, the
/// place to add it is here, calling `McpService.load()`'s pull rather than a
/// new mechanism.
class McpSyncService {
  McpSyncService._();

  static Future<void> pullAndReconcile() async {}
}
