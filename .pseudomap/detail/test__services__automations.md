# test/services/automations · Signaturen

## test/services/automations/agents_automation_test.dart  (223 Z.)
- L10 `Map<String, dynamic> eventPayload({ String event = 'created', String id = 'ab12cd34', String state = 'active', String kind = 'schedule', Map<String, dynamic> spec = const {'every': 300}, int fireCount = 0, String? runId, String? reason, bool replay = false, int? mid, })`  — The wire shapes of docs/WIRE_CONTRACT.md, "Automations", as the host
- L44 `void main()`

## test/services/automations/automations_source_test.dart  (167 Z.)
- L11 `class FakeAutomationController extends FakeRelayController implements AgentsAutomationControl`  — The shared test double, plus the two automation frames the source sends.
  - L13 `final List<(String, String)> controls = <(String, String)>[]`
  - L14 `final List<String?> listRequests = <String?>[]`
  - L15 `Object? sendError`
  - L18 `Future<void> sendAutomationControl({ required String id, required String action, })`
  - L27 `Future<void> requestAutomationList({String? sessionKey})`
- L33 `AgentsAutomation automation(String id, {String session = 'thread-1', String state = 'active', double created = 1.0})`
- L44 `void main()`
