/// What a coworker may do in its sandbox, as the host says
/// (docs/WIRE_CONTRACT.md, "Agent permissions").
///
/// The host is the truth. This service asks it for one coworker's permissions
/// (`agent_permissions_get`), sends a changed switch (`agent_permissions_set`
/// with only that key), and takes every `agent_permissions` reply as the whole
/// current set. A change applies from the coworker's next task, never in the
/// middle of one.
///
/// Everything is allowed by default. The one permission that starts off is the
/// user's own browser.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

/// How the workspace is bound into the sandbox.
enum AgentWorkspaceMount {
  /// The agent can change its files.
  rw,

  /// The agent can read its files and change none.
  ro,
}

/// One coworker's permissions. The defaults are the host's defaults.
@immutable
class AgentPermissions {
  const AgentPermissions({
    this.sudo = true,
    this.network = true,
    this.secretsEnv = true,
    this.workspaceMount = AgentWorkspaceMount.rw,
    this.userBrowser = false,
  });

  /// Everything on, except the user's own browser.
  static const AgentPermissions defaults = AgentPermissions();

  static const String keySudo = 'sudo';
  static const String keyNetwork = 'network';
  static const String keySecretsEnv = 'secrets_env';
  static const String keyWorkspaceMount = 'workspace_mount';
  static const String keyUserBrowser = 'user_browser';

  /// Every key, in the order the app shows them.
  static const List<String> keys = <String>[
    keySudo,
    keyNetwork,
    keySecretsEnv,
    keyWorkspaceMount,
    keyUserBrowser,
  ];

  /// Passwordless sudo in the sandbox.
  final bool sudo;

  /// The sandbox reaches the network.
  final bool network;

  /// The user's secrets reach the agent's commands as environment variables.
  final bool secretsEnv;

  /// Read-write or read-only workspace.
  final AgentWorkspaceMount workspaceMount;

  /// The agent drives the browser add-on on the user's computer.
  final bool userBrowser;

  bool get workspaceWritable => workspaceMount == AgentWorkspaceMount.rw;

  /// The switch state of [key]. The workspace switch is "writable".
  bool isOn(String key) => switch (key) {
    keySudo => sudo,
    keyNetwork => network,
    keySecretsEnv => secretsEnv,
    keyWorkspaceMount => workspaceWritable,
    keyUserBrowser => userBrowser,
    _ => throw ArgumentError.value(key, 'key', 'unknown permission'),
  };

  /// The wire value of one switch: a bool, or `rw` / `ro` for the workspace.
  static Object wireValue(String key, bool on) {
    if (!keys.contains(key)) {
      throw ArgumentError.value(key, 'key', 'unknown permission');
    }
    if (key == keyWorkspaceMount) return on ? 'rw' : 'ro';
    return on;
  }

  /// This set with one switch flipped to [on].
  AgentPermissions withSwitch(String key, bool on) => switch (key) {
    keySudo => copyWith(sudo: on),
    keyNetwork => copyWith(network: on),
    keySecretsEnv => copyWith(secretsEnv: on),
    keyWorkspaceMount => copyWith(
      workspaceMount: on ? AgentWorkspaceMount.rw : AgentWorkspaceMount.ro,
    ),
    keyUserBrowser => copyWith(userBrowser: on),
    _ => throw ArgumentError.value(key, 'key', 'unknown permission'),
  };

  AgentPermissions copyWith({
    bool? sudo,
    bool? network,
    bool? secretsEnv,
    AgentWorkspaceMount? workspaceMount,
    bool? userBrowser,
  }) {
    return AgentPermissions(
      sudo: sudo ?? this.sudo,
      network: network ?? this.network,
      secretsEnv: secretsEnv ?? this.secretsEnv,
      workspaceMount: workspaceMount ?? this.workspaceMount,
      userBrowser: userBrowser ?? this.userBrowser,
    );
  }

  /// Reads the host's `permissions` map. A key that is missing or has the
  /// wrong type keeps its default: the host always sends the whole set, so
  /// that only happens with a newer or broken host.
  factory AgentPermissions.fromJson(Map<String, dynamic> json) {
    bool flag(String key, bool fallback) {
      final Object? value = json[key];
      return value is bool ? value : fallback;
    }

    final Object? mount = json[keyWorkspaceMount];
    return AgentPermissions(
      sudo: flag(keySudo, defaults.sudo),
      network: flag(keyNetwork, defaults.network),
      secretsEnv: flag(keySecretsEnv, defaults.secretsEnv),
      workspaceMount: mount == 'ro'
          ? AgentWorkspaceMount.ro
          : AgentWorkspaceMount.rw,
      userBrowser: flag(keyUserBrowser, defaults.userBrowser),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    keySudo: sudo,
    keyNetwork: network,
    keySecretsEnv: secretsEnv,
    keyWorkspaceMount: workspaceMount.name,
    keyUserBrowser: userBrowser,
  };

  @override
  bool operator ==(Object other) =>
      other is AgentPermissions &&
      other.sudo == sudo &&
      other.network == network &&
      other.secretsEnv == secretsEnv &&
      other.workspaceMount == workspaceMount &&
      other.userBrowser == userBrowser;

  @override
  int get hashCode =>
      Object.hash(sudo, network, secretsEnv, workspaceMount, userBrowser);

  @override
  String toString() => 'AgentPermissions(${toJson()})';
}

/// Seals and sends one control frame to the host. Throws when nothing is
/// connected.
typedef AgentsControlFrameSender = Future<void> Function(
  Map<String, dynamic> payload,
);

Future<void> _sendOverRelay(Map<String, dynamic> payload) async {
  final Object? controller = AgentsRelayLink.instance.controller.value;
  if (controller is! AgentsRelayClient) {
    throw StateError('Not connected to the host');
  }
  await controller.sendControlFrame(payload);
}

/// The capability a host names in `host_route.capabilities` when it answers
/// the permission frames. The app sends them to no other host.
const String kAgentPermissionsCapability = 'agent_permissions';

// ── F2: automations + cost totals ──
/// The capability a host names when it keeps a weekly euro budget per
/// coworker (docs/WIRE_CONTRACT.md, "The budget setting"). `budget_weekly`
/// goes to no other host.
const String kCostBudgetCapability = 'cost_budget';

/// The largest weekly budget the host accepts, in euro.
const double kBudgetWeeklyMax = 10000;

/// Reads what the user typed as a weekly budget: euro with a dot or a comma,
/// an optional `€`, empty = 0 (no limit). Null when it is not a number in
/// 0..[kBudgetWeeklyMax]. Rounded to cents, as the host stores it.
double? parseBudgetWeekly(String text) {
  final String cleaned = text
      .replaceAll('€', '')
      .replaceAll(' ', '')
      .replaceAll(',', '.')
      .trim();
  if (cleaned.isEmpty) return 0;
  final double? value = double.tryParse(cleaned);
  if (value == null || !value.isFinite) return null;
  if (value < 0 || value > kBudgetWeeklyMax) return null;
  return (value * 100).round() / 100;
}
// ── end F2 ──

/// The app's copy of the host's answers, per coworker.
///
/// It sends nothing to a host that did not name [kAgentPermissionsCapability]:
/// an older host answers an unknown frame with an `error`, and that is no
/// answer to show. It also notifies when the connection or the host's
/// capabilities change, so a section that found nobody to ask asks again as
/// soon as there is somebody.
class AgentsPermissionsService extends ChangeNotifier {
  AgentsPermissionsService({
    AgentsControlFrameSender? send,
    ValueListenable<Object?>? connection,
    ValueListenable<Set<String>>? capabilities,
  }) : _send = send ?? _sendOverRelay,
       _connection = connection ?? AgentsRelayLink.instance.controller,
       _capabilities = capabilities ?? AgentsRelayClient.hostCapabilities {
    // own browser: first, so the repaint below sees the status gone.
    _connection.addListener(_forgetUserBrowserOnDrop);
    _connection.addListener(notifyListeners);
    _capabilities.addListener(notifyListeners);
  }

  /// The one instance the app uses.
  static AgentsPermissionsService instance = AgentsPermissionsService();

  final AgentsControlFrameSender _send;
  final ValueListenable<Object?> _connection;
  final ValueListenable<Set<String>> _capabilities;
  final Map<String, AgentPermissions> _confirmed = <String, AgentPermissions>{};
  final Map<String, AgentPermissions> _optimistic =
      <String, AgentPermissions>{};
  final Map<String, Map<String, bool>> _enforced =
      <String, Map<String, bool>>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, String> _appliesFrom = <String, String>{};
  // F2: cost totals. The host's weekly budget per coworker (0 = none).
  final Map<String, double> _budgets = <String, double>{};

  /// Routes the relay's `agent_permissions` replies here. Idempotent.
  void attach() {
    AgentsRelayClient.agentPermissionsSink = handleFrame;
    // own browser
    AgentsRelayClient.userBrowserStatusSink = handleUserBrowserStatus;
  }

  /// A host is connected right now.
  bool get connected => _connection.value != null;

  /// The connected host answers the permission frames.
  bool get supported =>
      _capabilities.value.contains(kAgentPermissionsCapability);

  /// True once the host answered for [agentId] with a set of permissions.
  /// Before that the switches show the defaults and stay disabled.
  bool isKnown(String agentId) => _confirmed.containsKey(agentId);

  /// What the section draws: the host's last answer, with a switch the user
  /// just flipped shown flipped until the host's reply lands.
  AgentPermissions permissionsOf(String agentId) =>
      _optimistic[agentId] ?? _confirmed[agentId] ?? AgentPermissions.defaults;

  /// The host's own answer only, or null before it answered.
  AgentPermissions? confirmedOf(String agentId) => _confirmed[agentId];

  /// Whether this host really enforces [key] for [agentId]. True until the
  /// host said otherwise (a host that sends no `enforced` enforces all).
  bool isEnforced(String agentId, String key) =>
      _enforced[agentId]?[key] ?? true;

  /// Why the host refused the last request, or null.
  String? errorOf(String agentId) => _errors[agentId];

  /// When a change takes effect, as the host said (`next_task`).
  String appliesFromOf(String agentId) => _appliesFrom[agentId] ?? 'next_task';

  /// Asks the host for [agentId]'s permissions. False when nothing is
  /// connected, the host does not answer these frames, or the frame could not
  /// be sent.
  Future<bool> refresh(String agentId) async {
    if (!supported) return false;
    try {
      await _send(<String, dynamic>{
        'type': 'agent_permissions_get',
        'agent_id': agentId,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Flips one switch. The row flips at once so it does not bounce; the
  /// host's reply (the truth) then replaces it, and puts it back when the host
  /// refused. False when the frame could not be sent; the switch is put back.
  Future<bool> setSwitch(String agentId, String key, bool on) async {
    final Object value = AgentPermissions.wireValue(key, on);
    if (!supported) return false;
    final AgentPermissions before = permissionsOf(agentId);
    _optimistic[agentId] = before.withSwitch(key, on);
    _errors.remove(agentId);
    notifyListeners();
    try {
      await _send(<String, dynamic>{
        'type': 'agent_permissions_set',
        'agent_id': agentId,
        'permissions': <String, dynamic>{key: value},
      });
      return true;
    } catch (_) {
      _optimistic.remove(agentId);
      notifyListeners();
      return false;
    }
  }

  /// Takes one `agent_permissions` reply for one coworker: the whole set, what
  /// this host enforces, and the reason when a request was refused. A reply
  /// with no set (an unknown coworker) carries only the reason. It may come
  /// from another device's change: the host sends every change to all of them.
  void handleFrame(Map<String, dynamic> payload) {
    if (payload['type'] != 'agent_permissions') return;
    final Object? agentId = payload['agent_id'];
    if (agentId is! String || agentId.isEmpty) return;
    final Object? permissions = payload['permissions'];
    final Object? error = payload['error'];
    final bool hasError = error is String && error.isNotEmpty;
    if (permissions is! Map && !hasError) return;
    if (permissions is Map) {
      _confirmed[agentId] = AgentPermissions.fromJson(
        permissions.map((Object? k, Object? v) => MapEntry('$k', v)),
      );
    }
    _optimistic.remove(agentId);
    if (hasError) {
      _errors[agentId] = error;
    } else {
      _errors.remove(agentId);
    }
    _readApprovals(agentId, payload); // F1: approvals
    _readUserBrowser(agentId, payload); // own browser
    final Object? enforced = payload['enforced'];
    if (enforced is Map) {
      _enforced[agentId] = <String, bool>{
        for (final MapEntry<Object?, Object?> e in enforced.entries)
          if (e.value is bool) '${e.key}': e.value! as bool,
      };
    }
    final Object? appliesFrom = payload['applies_from'];
    if (appliesFrom is String && appliesFrom.isNotEmpty) {
      _appliesFrom[agentId] = appliesFrom;
    }
    // F2: cost totals. In every reply for a known agent, also 0.
    final Object? budget = payload['budget_weekly'];
    if (budget is num && budget.isFinite) {
      _budgets[agentId] = budget.toDouble();
    }
    notifyListeners();
  }

  // ── F2: automations + cost totals ──
  /// The connected host keeps a weekly budget per coworker.
  bool get budgetSupported =>
      _capabilities.value.contains(kCostBudgetCapability);

  /// The coworker's weekly budget as the host last said, in euro; 0 = no
  /// limit. Null before the host answered with one.
  double? budgetOf(String agentId) => _budgets[agentId];

  /// Sends `agent_permissions_set` with `budget_weekly` only. The host's
  /// reply replaces the shown value (or carries `error`, see [errorOf]).
  /// False when the host does not keep budgets or the frame could not be
  /// sent. Throws [ArgumentError] for a value outside 0..[kBudgetWeeklyMax].
  Future<bool> setBudget(String agentId, double euro) async {
    if (!euro.isFinite || euro < 0 || euro > kBudgetWeeklyMax) {
      throw ArgumentError.value(euro, 'euro', 'outside 0..10000');
    }
    if (!budgetSupported) return false;
    _errors.remove(agentId);
    try {
      await _send(<String, dynamic>{
        'type': 'agent_permissions_set',
        'agent_id': agentId,
        'budget_weekly': (euro * 100).round() / 100,
      });
      return true;
    } catch (_) {
      return false;
    }
  }
  // ── end F2 ──

  // ── F1: approvals + cost ──
  final Map<String, AgentApprovals> _approvals = <String, AgentApprovals>{};
  final Map<String, AgentApprovals> _optimisticApprovals =
      <String, AgentApprovals>{};

  /// The connected host asks before outward actions and keeps a policy per
  /// coworker (docs/WIRE_CONTRACT.md, "Per-action approvals").
  bool get approvalsSupported =>
      _capabilities.value.contains(kActionApprovalsCapability);

  /// The coworker's approval policy as the host last said, with a choice the
  /// user just made shown until the host's reply lands. Null before the host
  /// sent one (an old host never does).
  AgentApprovals? approvalsOf(String agentId) =>
      _optimisticApprovals[agentId] ?? _approvals[agentId];

  void _readApprovals(String agentId, Map<String, dynamic> payload) {
    final Object? approvals = payload['approvals'];
    // Every `agent_permissions` reply replaces what is shown, so a lasting
    // answer given on a card in a run lands here at once.
    _optimisticApprovals.remove(agentId);
    if (approvals is Map) {
      _approvals[agentId] = AgentApprovals.fromJson(
        approvals.map((Object? k, Object? v) => MapEntry('$k', v)),
      );
    }
  }

  /// Sets one class to `ask`, `allow` or `deny`. Sends `approvals` only. False
  /// when the host does not keep approvals or the frame could not be sent;
  /// the choice is put back then.
  Future<bool> setApprovalMode(
    String agentId,
    String actionClass,
    String mode,
  ) {
    if (!AgentApprovals.modes.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', 'not ask, allow or deny');
    }
    final AgentApprovals before =
        approvalsOf(agentId) ?? const AgentApprovals();
    return _sendApprovals(
      agentId,
      optimistic: before.withMode(actionClass, mode),
      approvals: <String, dynamic>{
        'classes': <String, String>{actionClass: mode},
      },
    );
  }

  /// Takes [site] off a class's list. The host replaces the WHOLE list of a
  /// class it is sent, so the list goes out without the site.
  Future<bool> removeApprovalSite(
    String agentId,
    String actionClass,
    String site,
  ) {
    final AgentApprovals before =
        approvalsOf(agentId) ?? const AgentApprovals();
    final List<String> rest = <String>[
      for (final String s in before.sitesOf(actionClass))
        if (s != site) s,
    ];
    return _sendApprovals(
      agentId,
      optimistic: before.withSites(actionClass, rest),
      approvals: <String, dynamic>{
        'sites': <String, List<String>>{actionClass: rest},
      },
    );
  }

  Future<bool> _sendApprovals(
    String agentId, {
    required AgentApprovals optimistic,
    required Map<String, dynamic> approvals,
  }) async {
    if (!approvalsSupported) return false;
    _optimisticApprovals[agentId] = optimistic;
    _errors.remove(agentId);
    notifyListeners();
    try {
      await _send(<String, dynamic>{
        'type': 'agent_permissions_set',
        'agent_id': agentId,
        'approvals': approvals,
      });
      return true;
    } catch (_) {
      _optimisticApprovals.remove(agentId);
      notifyListeners();
      return false;
    }
  }
  // ── end F1 ──

  // ── own browser ──
  /// The host's status of the user's own browser (docs/WIRE_CONTRACT.md,
  /// "Inbound: agent_permissions.user_browser" and "user_browser_status").
  /// Host-wide: the last block the host sent, from a reply or a push. Null
  /// before the host sent one, and after the connection went away (an old
  /// host never sends one).
  UserBrowserStatus? _userBrowser;

  /// `in_use_by_this_agent` per coworker, from the replies. A push carries no
  /// such flag and clears these: the holder may have changed.
  final Map<String, bool> _userBrowserMine = <String, bool>{};

  /// The host's last word on the user's browser, or null.
  UserBrowserStatus? get userBrowserStatus => _userBrowser;

  /// Whether a coworker OTHER than [agentId] holds the user's browser now.
  /// Reads `in_use_by.agent_id` first, then the reply's own flag. Unknown
  /// counts as no: the app never claims a holder the host did not name.
  bool userBrowserHeldByOther(String agentId) {
    final UserBrowserStatus? s = _userBrowser;
    if (s == null || !s.inUse) return false;
    final String? holder = s.inUseByAgentId;
    if (holder != null) return holder != agentId;
    final bool? mine = _userBrowserMine[agentId];
    return mine == false;
  }

  void _readUserBrowser(String agentId, Map<String, dynamic> payload) {
    final UserBrowserStatus? status = UserBrowserStatus.fromJson(
      payload['user_browser'],
    );
    if (status == null) return;
    _userBrowser = status;
    final bool? mine = status.inUseByThisAgent;
    if (mine == null) {
      _userBrowserMine.remove(agentId);
    } else {
      _userBrowserMine[agentId] = mine;
    }
  }

  /// Takes one `user_browser_status` push: the whole status replaces the
  /// stored one, and every listener repaints. No polling.
  void handleUserBrowserStatus(Map<String, dynamic> payload) {
    if (payload['type'] != 'user_browser_status') return;
    final UserBrowserStatus? status = UserBrowserStatus.fromJson(
      payload['user_browser'],
    );
    if (status == null) return;
    _userBrowser = status;
    _userBrowserMine.clear();
    notifyListeners();
  }

  void _forgetUserBrowserOnDrop() {
    if (_connection.value != null) return;
    _userBrowser = null;
    _userBrowserMine.clear();
  }
  // ── end own browser ──

  @override
  void dispose() {
    _connection.removeListener(notifyListeners);
    _capabilities.removeListener(notifyListeners);
    _connection.removeListener(_forgetUserBrowserOnDrop); // own browser
    super.dispose();
  }

  /// Test seam: forget every answer.
  @visibleForTesting
  void reset() {
    _confirmed.clear();
    _optimistic.clear();
    _enforced.clear();
    _errors.clear();
    _appliesFrom.clear();
    _budgets.clear(); // F2: cost totals
    _approvals.clear(); // F1: approvals
    _optimisticApprovals.clear(); // F1: approvals
    _userBrowser = null; // own browser
    _userBrowserMine.clear(); // own browser
  }
}

// ── own browser ──
/// The host's status of the user's own browser: the `user_browser` block of
/// an `agent_permissions` reply or of a `user_browser_status` push. It never
/// carries a URL, a tab title or a thread key.
@immutable
class UserBrowserStatus {
  const UserBrowserStatus({
    this.hostListening = false,
    this.installed = false,
    this.browsers = const <String>[],
    this.connected = false,
    this.browser,
    this.version,
    this.trustedInput,
    this.inUse = false,
    this.inUseByAgentId,
    this.inUseByName,
    this.inUseByThisAgent,
    this.stopped = false,
  });

  /// The host's broker runs.
  final bool hostListening;

  /// The bridge is registered with at least one browser ("paired").
  final bool installed;

  /// The browsers the bridge is registered with (`chrome`, `brave`, ...).
  final List<String> browsers;

  /// An add-on is connected now.
  final bool connected;

  /// What the connected add-on said: `chrome`, `firefox`, ...
  final String? browser;
  final String? version;

  /// False = synthetic input only (Firefox). Null when not said.
  final bool? trustedInput;

  /// A coworker holds the browser now.
  final bool inUse;

  /// Who holds it: the app's agent id and the name the user gave it.
  final String? inUseByAgentId;
  final String? inUseByName;

  /// Only in a reply (per coworker); null in a push.
  final bool? inUseByThisAgent;

  /// The user pressed Stop and did not allow the browser again.
  final bool stopped;

  /// Not set up, or set up and not connected: the setup card has something
  /// to say. False while the host's broker does not run (nothing to set up
  /// on the app's side then).
  bool get needsSetup => hostListening && (!installed || !connected);

  /// Reads one block. Null when [raw] is not a map. A key of the wrong type
  /// keeps its default, never a guess.
  static UserBrowserStatus? fromJson(Object? raw) {
    if (raw is! Map) return null;
    bool flag(String key) => raw[key] == true;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    final Object? by = raw['in_use_by'];
    final Object? mine = raw['in_use_by_this_agent'];
    final Object? trusted = raw['trusted_input'];
    final Object? browsers = raw['browsers'];
    return UserBrowserStatus(
      hostListening: flag('host_listening'),
      installed: flag('installed'),
      browsers: List<String>.unmodifiable(<String>[
        if (browsers is List)
          for (final Object? b in browsers)
            if (b is String && b.trim().isNotEmpty) b.trim(),
      ]),
      connected: flag('connected'),
      browser: text(raw['browser']),
      version: text(raw['version']),
      trustedInput: trusted is bool ? trusted : null,
      inUse: flag('in_use'),
      inUseByAgentId: by is Map ? text(by['agent_id']) : null,
      inUseByName: by is Map ? text(by['name']) : null,
      inUseByThisAgent: mine is bool ? mine : null,
      stopped: flag('stopped'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UserBrowserStatus &&
      other.hostListening == hostListening &&
      other.installed == installed &&
      listEquals(other.browsers, browsers) &&
      other.connected == connected &&
      other.browser == browser &&
      other.version == version &&
      other.trustedInput == trustedInput &&
      other.inUse == inUse &&
      other.inUseByAgentId == inUseByAgentId &&
      other.inUseByName == inUseByName &&
      other.inUseByThisAgent == inUseByThisAgent &&
      other.stopped == stopped;

  @override
  int get hashCode => Object.hash(
    hostListening,
    installed,
    Object.hashAll(browsers),
    connected,
    browser,
    version,
    trustedInput,
    inUse,
    inUseByAgentId,
    inUseByName,
    inUseByThisAgent,
    stopped,
  );
}

/// A browser id as people say it: `chrome` -> `Chrome`. Unknown ids get a
/// capital first letter.
String userBrowserDisplayName(String id) {
  const Map<String, String> known = <String, String>{
    'chrome': 'Chrome',
    'chromium': 'Chromium',
    'brave': 'Brave',
    'edge': 'Edge',
    'firefox': 'Firefox',
    'opera': 'Opera',
    'vivaldi': 'Vivaldi',
  };
  final String key = id.trim().toLowerCase();
  if (known.containsKey(key)) return known[key]!;
  if (key.isEmpty) return id;
  return key[0].toUpperCase() + key.substring(1);
}
// ── end own browser ──

// ── F1: approvals + cost ──
/// The capability a host names when it asks before outward actions
/// (docs/WIRE_CONTRACT.md, "Per-action approvals"). `approvals` goes to no
/// other host.
const String kActionApprovalsCapability = 'action_approvals';

/// One coworker's approval policy: per action class `ask`, `allow` or `deny`,
/// the sites a class allows without asking, and the host's defaults.
@immutable
class AgentApprovals {
  const AgentApprovals({
    this.classes = const <String, String>{},
    this.sites = const <String, List<String>>{},
    this.defaults = const <String, String>{},
    this.appliesFrom = 'next_action',
  });

  static const String classPublish = 'publish';
  static const String classSendExternal = 'send_external';
  static const String classMcpDestructive = 'mcp_destructive';
  static const String classBrowserAct = 'browser_act';

  static const String modeAsk = 'ask';
  static const String modeAllow = 'allow';
  static const String modeDeny = 'deny';

  /// The three modes, in the order the app offers them.
  static const List<String> modes = <String>[modeAsk, modeAllow, modeDeny];

  /// The classes in the order the app shows them.
  static const List<String> order = <String>[
    classSendExternal,
    classMcpDestructive,
    classBrowserAct,
    classPublish,
  ];

  /// The host's defaults, for a host that leaves `defaults` out.
  static const Map<String, String> fallbackDefaults = <String, String>{
    classPublish: modeAsk,
    classSendExternal: modeAsk,
    classMcpDestructive: modeAsk,
    classBrowserAct: modeAllow,
  };

  /// Effective mode per class, as the host said.
  final Map<String, String> classes;

  /// Allowed sites per class (only `browser_act` has them today).
  final Map<String, List<String>> sites;

  /// The default mode per class.
  final Map<String, String> defaults;

  /// `next_action`: the runtime reads the policy at every class call.
  final String appliesFrom;

  /// The classes to show: the known ones the host listed, in [order], then
  /// any newer class the host listed.
  List<String> get shownClasses => <String>[
    for (final String c in order)
      if (classes.containsKey(c)) c,
    for (final String c in classes.keys)
      if (!order.contains(c)) c,
  ];

  String modeOf(String actionClass) =>
      classes[actionClass] ?? defaultOf(actionClass);

  String defaultOf(String actionClass) =>
      defaults[actionClass] ?? fallbackDefaults[actionClass] ?? modeAsk;

  List<String> sitesOf(String actionClass) =>
      sites[actionClass] ?? const <String>[];

  AgentApprovals withMode(String actionClass, String mode) => AgentApprovals(
    classes: <String, String>{...classes, actionClass: mode},
    sites: sites,
    defaults: defaults,
    appliesFrom: appliesFrom,
  );

  AgentApprovals withSites(String actionClass, List<String> list) =>
      AgentApprovals(
        classes: classes,
        sites: <String, List<String>>{
          ...sites,
          actionClass: List<String>.unmodifiable(list),
        },
        defaults: defaults,
        appliesFrom: appliesFrom,
      );

  /// Reads the host's `approvals` block. A mode or a site of the wrong type
  /// is dropped, never guessed.
  factory AgentApprovals.fromJson(Map<String, dynamic> json) {
    Map<String, String> modesOf(Object? raw) => <String, String>{
      if (raw is Map)
        for (final MapEntry<Object?, Object?> e in raw.entries)
          if (e.value is String && modes.contains(e.value))
            '${e.key}': e.value! as String,
    };
    final Object? rawSites = json['sites'];
    final Object? appliesFrom = json['applies_from'];
    return AgentApprovals(
      classes: modesOf(json['classes']),
      defaults: modesOf(json['defaults']),
      sites: <String, List<String>>{
        if (rawSites is Map)
          for (final MapEntry<Object?, Object?> e in rawSites.entries)
            if (e.value is List)
              '${e.key}': List<String>.unmodifiable(<String>[
                for (final Object? site in e.value! as List)
                  if (site is String && site.isNotEmpty) site,
              ]),
      },
      appliesFrom: appliesFrom is String && appliesFrom.isNotEmpty
          ? appliesFrom
          : 'next_action',
    );
  }
}
// ── end F1 ──
