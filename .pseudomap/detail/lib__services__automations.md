# lib/services/automations · Signaturen

## lib/services/automations/agents_automation.dart  (203 Z.)
- L11 `@immutable class AgentsAutomation`  — One automation of a coworker: a schedule (cron / every / at) or a watcher
  - L13 `const AgentsAutomation({ required this.id, required this.sessionKey, required this.kind, required this.name, required this.state, this.spec = const <String, dynamic>{}, this.prompt = '', this.nextFireAt, this.lastFiredAt, this.fireCount = 0, this.suppressedCount = 0, this.lastError, this.logPath, this.createdAt, })`
  - L31 `final String id`  — The host's short handle (`ab12cd34`).
  - L34 `final String sessionKey`  — The conversation that owns it. An agent only ever sees its own.
  - L37 `final String kind`  — `schedule` or `watcher`.
  - L40 `final String name`  — The label the model gave, or the host's default from the spec.
  - L43 `final String state`  — `active`, `paused`, `done` or `failed`.
  - L47 `final Map<String, dynamic> spec`  — `{cron}` / `{every}` / `{at}` for a schedule, `{script_path, restart}`
  - L50 `final String prompt`  — What a fired task says to the model (may be empty for a watcher).
  - L52 `final DateTime? nextFireAt`
  - L53 `final DateTime? lastFiredAt`
  - L54 `final int fireCount`
  - L57 `final int suppressedCount`  — Triggers folded by the rate limit (watcher).
  - L60 `final String? lastError`  — Why it failed, or the last non-fatal problem.
  - L63 `final String? logPath`  — Workspace-relative log of a watcher (`.agents/automations/<id>.log`).
  - L65 `final DateTime? createdAt`
  - L67 `bool get isSchedule`
  - L68 `bool get isWatcher`
  - L69 `bool get isActive`
  - L70 `bool get isPaused`
  - L73 `bool get isOver`  — `done` or `failed`: nothing more will happen.
  - L77 `String get specLabel`  — A short human reading of the spec (`every 5m`, `cron 0 9 * * 1-5`,
  - L100 `static AgentsAutomation? fromPayload(Map<String, dynamic> payload)`  — Reads an `automation` event or an `automation_list` entry. Null when
  - L131 `Map<String, dynamic> toJson()`
  - L151 `static int? _int(Object? value)`
  - L158 `static DateTime? _epoch(Object? value)`
  - L165 `static String _stamp(DateTime when)`
  - L172 `bool operator ==(Object other)`
  - L183 `int get hashCode`
- L190 `abstract interface class AgentsAutomationControl`  — The two frames the app sends about automations. Kept apart from
  - L193 `Future<void> sendAutomationControl({ required String id, required String action, })`  — `automation_control`: pause / resume / cancel one automation. The host
  - L201 `Future<void> requestAutomationList({String? sessionKey})`  — `automation_list`: ask for every automation of one session, or of the

## lib/services/automations/automation_ledger.dart  (74 Z.)
- L12 `ToolCall automationCallFromRelay( ToolCall? existing, AgentsRelayAutomation event, { DateTime? now, })`  — The transcript line of one automation: ONE [ToolCall] per automation id,
- L48 `String automationEventText(AgentsRelayAutomation event)`  — One line of English for an automation event, for the transcript card.

## lib/services/automations/automations_source.dart  (190 Z.)
- L18 `class AutomationsSource extends ChangeNotifier`  — The app's copy of the host's automations, kept current from the relay.
  - L19 `AutomationsSource._()`
  - L21 `static final AutomationsSource instance = AutomationsSource._()`
  - L23 `final Map<String, AgentsAutomation> _byId = <String, AgentsAutomation>{}`
  - L26 `final Map<String, String> _names = <String, String>{}`  — The host's coworker names, by session key (`agent_list`).
  - L27 `StreamSubscription<AgentsRelayInbound>? _sub`
  - L30 `final Set<String> _listed = <String>{}`  — Sessions whose list the host has answered at least once.
  - L31 `bool _listedAll = false`
  - L34 `void attach()`  — Starts listening. Idempotent.
  - L39 `List<AgentsAutomation> get all`  — Every automation known to this app, newest first.
  - L51 `List<AgentsAutomation> get distinct`  — Every automation, one row per automation, newest first.
  - L66 `static String identityOf(AgentsAutomation a)`  — What makes two rows the same automation: the same thread, the same kind,
  - L69 `static bool _better(AgentsAutomation a, AgentsAutomation b)`
  - L75 `List<AgentsAutomation> forSession(String sessionKey)`  — The automations of one conversation, newest first.
  - L84 `String coworkerName(String sessionKey)`  — The name to put over a group of rows: what the rest of the app calls that
  - L103 `List<AgentsAutomation> liveForSession(String sessionKey)`  — The active and paused ones of one conversation: what a thread's strip
  - L106 `AgentsAutomation? byId(String id)`
  - L110 `bool listed(String? sessionKey)`  — True once the host answered a list request for [sessionKey] (or for the
  - L115 `Future<bool> refresh({String? sessionKey})`  — Ask the host for the current list. Returns false when nothing is
  - L128 `Future<bool> control(String id, String action)`  — Pause / resume / cancel one automation. The host answers with the
  - L139 `void _onInbound(AgentsRelayInbound event)`
  - L171 `static int _newestFirst(AgentsAutomation a, AgentsAutomation b)`
  - L181 `void reset()`  — Test seam: forget everything and stop listening.
