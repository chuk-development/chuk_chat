# test/agents_permissions · Signaturen

## test/agents_permissions/agent_permissions_section_test.dart  (329 Z.)
- L16 `Widget _page(AgentsPermissionsService service, {String agentId = 'a'})`
- L26 `Switch _switch(WidgetTester tester, String key)`
- L33 `Future<(FakeHost, AgentsPermissionsService)> _open( WidgetTester tester, { bool connected = true, bool supported = true, })`
- L46 `void main()`

## test/agents_permissions/agents_error_routing_test.dart  (100 Z.)
- L19 `Future<void> _drain()`
- L25 `void main()`

## test/agents_permissions/agents_permissions_service_test.dart  (219 Z.)
- L8 `void main()`

## test/agents_permissions/permissions_fakes.dart  (51 Z.)
- L7 `class FakeHost`  — A stand-in for the host connection: what it sends, whether a host is
  - L8 `FakeHost({bool connected = true, bool supported = true}) : connection = ValueNotifier<Object?>(connected ? Object() : null), capabilities = ValueNotifier<Set<String>>( supported ? const <String>{kAgentPermissionsCapability} : const {}, )`
  - L14 `final ValueNotifier<Object?> connection`
  - L15 `final ValueNotifier<Set<String>> capabilities`
  - L16 `final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[]`
  - L19 `bool fail = false`  — Makes every send throw, the way the relay does with no socket.
  - L21 `Future<void> send(Map<String, dynamic> payload)`
  - L26 `AgentsPermissionsService service()`
  - L32 `void attach()`
  - L33 `void detach()`
  - L34 `void nameCapability()`
- L38 `Map<String, dynamic> permissionsReply( String agentId, AgentPermissions? p, { String? error, Map<String, bool>? enforced, })`
