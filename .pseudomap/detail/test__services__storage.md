# test/services/storage · Signaturen

## test/services/storage/agents_chat_cache_migration_test.dart  (169 Z.)
- L12 `void main()`

## test/services/storage/agents_chat_storage_bootstrap_test.dart  (129 Z.)
- L9 `void main()`
- L97 `void _flushTests()`

## test/services/storage/agents_chat_store_test.dart  (555 Z.)
- L11 `List<Map<String, dynamic>> rows(List<List<String>> turns)`
- L17 `void main()`
- L371 `void _outboxTests()`

## test/services/storage/agents_cloud_table_test.dart  (569 Z.)
- L17 `_user = 'user-7'`
- L18 `_chukChatId = '0b6c7f1e-2a51-4a8e-9d0e-6f4b8f7e1a23'`
- L20 `String _payload(List<List<String>> turns, {String? customName})`
- L30 `Map<String, dynamic> _cloudRow( String id, String payloadJson, { String updatedAt = '2026-09-20T10:00:00.000Z', String? title, })`  — A `cowork_chats` row as the server returns it. The "ciphertext" is the
- L44 `class _Cloud`
  - L45 `final Map<String, Map<String, dynamic>> rows = {}`
  - L46 `final List<List<String>?> selects = []`
  - L47 `final List<String> deletes = []`
  - L48 `final Map<String, Map<String, dynamic>> updates = {}`
  - L52 `int maxRows = 1000`  — The server's row limit: no response holds more rows, as with
  - L54 `void install()`
- L89 `void main()`

## test/services/storage/agents_offline_sqlite_test.dart  (97 Z.)
- L12 `void main()`

## test/services/storage/chat_origin_routing_test.dart  (325 Z.)
- L28 `chukChatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b'`
- L29 `agentsThreadKey = 'amber-otter-2'`
- L31 `List<Map<String, dynamic>> turn(String text)`
- L35 `OfflineSendPayload payload(String chatId)`
- L45 `void removeAsTheSyncDoes(String chatId)`  — Upstream's local removal drops the chat first and then reaches for the
- L53 `void main()`
