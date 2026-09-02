// lib/services/mcp/mcp_availability.dart
//
// Which MCP servers exist but are not connected yet, and how to look one up
// by id. Kept in its own file, apart from mcp_service.dart, so the tool
// registry / executor / prompt builder can reason about availability without
// importing the whole connect/OAuth stack (which would form an import cycle).

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';

/// Every catalogue server (our own first-party ones plus the offered
/// connectors) that the reader has NOT connected yet, in catalogue order.
///
/// Registry / hand-added servers are not here: they have no constant entry,
/// so the model cannot name one it has not already seen.
List<McpCatalogueEntry> unconnectedCatalogueEntries() {
  final connectedIds = McpService.connections.value.map((c) => c.id).toSet();
  return [...firstPartyConnectors(), ...kMcpCatalogue]
      .where((e) => !connectedIds.contains(e.id))
      .toList();
}

/// The catalogue entry with this [id], searching the first-party connectors
/// first and then the offered connectors. Null when no catalogue entry uses
/// the id — for a registry or hand-added server, which carry no constant
/// entry.
McpCatalogueEntry? catalogueEntryById(String id) {
  for (final entry in firstPartyConnectors()) {
    if (entry.id == id) return entry;
  }
  for (final entry in kMcpCatalogue) {
    if (entry.id == id) return entry;
  }
  return null;
}
