// An in-memory stand-in for the kv_cache that McpStore keeps its connection
// list in. Widget tests need it: the real kv_cache goes through
// path_provider and SQLite, whose futures never complete under the widget
// test's fake async, so a store on the default backend hangs the test.

import 'package:chuk_chat/services/mcp/mcp_store.dart';

McpListBackend memoryMcpList([Map<String, String>? backing]) {
  final map = backing ?? <String, String>{};
  return McpListBackend(
    read: (key) async => map[key],
    write: (key, value) async => map[key] = value,
  );
}
