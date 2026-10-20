# tool/agent_driver/bin · Signaturen

## tool/agent_driver/bin/agent_driver.dart  (161 Z.)
- L25 `Future<void> main(List<String> args)`
- L89 `Future<int> runScript( AgentTools tools, File file, { required bool headless, Map<String, String> vars = const <String, String>{}, })`  — Runs a walk file: a JSON list of `{"tool": "<name>", "args": {...}}`.
- L139 `Map<String, Object?> substituteVars( Map<String, Object?> args, Map<String, String> vars, )`  — Replaces `{{KEY}}` in the string values of [args] with [vars]`[KEY]`.
- L156 `String? _option(List<String> args, String name)`
