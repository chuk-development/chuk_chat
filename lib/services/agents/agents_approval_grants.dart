// lib/services/agents/agents_approval_grants.dart
//
// Undo for an approval the user gave in a thread (bead chuk_chat-aupy).
//
// An answered approval stays in the transcript as one small row ("Approved:
// send mail with Fastmail", with Undo). A lasting answer ("always for this
// agent", "always on this site") is stored on the host, in the agent's
// approval policy (`agent_permissions.json`, docs/WIRE_CONTRACT.md,
// "Per-action approvals"). Undo takes it back out of that policy with the
// frames the settings page already uses, so no new host frame is needed:
//
// * `always_this_agent` sets the class back to `ask`.
// * `always_this_site` takes the site off the class's list.
//
// Which rows were revoked is kept on this device, so a reloaded thread still
// says "Revoked" instead of offering Undo again. The set is small (approval
// ids, capped) and lives in SharedPreferences.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// One answered approval, as the transcript line keeps it.
@immutable
class AgentsApprovalGrant {
  const AgentsApprovalGrant({
    required this.approvalId,
    required this.what,
    required this.approved,
    this.actionClass,
    this.scope,
    this.site,
  });

  /// Reads a decided `ask_user` line (`approvalCallFromRelay`). Null for a
  /// line that is not an answered approval: an open card, a takeover, an
  /// expired request, or a model's own `ask_user` question.
  static AgentsApprovalGrant? fromArguments(Map<String, dynamic> args) {
    final Object? id = args['approvalId'];
    final Object? decision = args['decision'];
    if (id is! String || id.isEmpty) return null;
    if (decision is! String || decision.isEmpty) return null;
    if (args['action'] == AgentsRelayApprovalRequest.takeoverAction) {
      return null;
    }
    if (decision == 'Expired') return null;
    final Object? rawScope = args['decision_scope'];
    final String? scope = rawScope is String && rawScope.isNotEmpty
        ? rawScope
        : null;
    final bool approved = scope != null
        ? scope != AgentsRelayApprovalRequest.scopeDeny
        : (decision.startsWith('Allowed') || decision == 'Publish');
    final Object? question = args['question'];
    String what = question is String ? question.trim() : '';
    // The line keeps the card's question ("Send this mail?"); after the
    // answer it is a statement.
    while (what.endsWith('?')) {
      what = what.substring(0, what.length - 1).trimRight();
    }
    if (what.isEmpty) {
      final Object? tool = args['tool'];
      what = tool is String && tool.isNotEmpty ? tool : 'this action';
    }
    final Object? actionClass = args['action_class'];
    final Object? site = args['site'];
    return AgentsApprovalGrant(
      approvalId: id,
      what: what,
      approved: approved,
      actionClass: actionClass is String && actionClass.isNotEmpty
          ? actionClass
          : null,
      scope: scope,
      site: site is String && site.isNotEmpty ? site : null,
    );
  }

  final String approvalId;

  /// What was allowed, in one line.
  final String what;
  final bool approved;

  /// `send_external`, `mcp_destructive`, `browser_act` or `publish`.
  final String? actionClass;

  /// What the answer covered (`once`, `always_this_agent`, …).
  final String? scope;
  final String? site;

  /// The answer is stored on the host and can be taken back.
  bool get isLasting =>
      approved &&
      actionClass != null &&
      (scope == AgentsRelayApprovalRequest.scopeAlwaysAgent ||
          (scope == AgentsRelayApprovalRequest.scopeAlwaysSite &&
              site != null));
}

/// Revokes lasting approvals and remembers which ones were revoked.
class AgentsApprovalGrants extends ChangeNotifier {
  AgentsApprovalGrants({
    AgentsPermissionsService? permissions,
    this.prefsKey = 'agents_revoked_approvals',
    this.replyTimeout = const Duration(seconds: 4),
  }) : _permissions = permissions; // ignore: prefer_initializing_formals

  /// The one instance the app uses.
  static AgentsApprovalGrants instance = AgentsApprovalGrants();

  final AgentsPermissionsService? _permissions;
  final String prefsKey;

  /// How long a site revoke waits for the host's policy when the app has
  /// not read it yet.
  final Duration replyTimeout;

  /// The most ids kept. Older ones fall off; their rows then offer Undo
  /// again, which is harmless (the host just confirms the policy).
  static const int maxKept = 200;

  AgentsPermissionsService get _service =>
      _permissions ?? AgentsPermissionsService.instance;

  final Map<String, String> _agentForThread = <String, String>{};
  final List<String> _revoked = <String>[];
  final Set<String> _busy = <String>{};
  Future<void>? _loading;

  /// The thread view says which agent a thread belongs to. A thread
  /// nobody registered is taken to be the agent's own key.
  void registerThread(String threadKey, String agentId) {
    if (threadKey.isEmpty || agentId.isEmpty) return;
    _agentForThread[threadKey] = agentId;
  }

  String agentIdFor(String threadKey) =>
      _agentForThread[threadKey] ?? threadKey;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> stored =
          prefs.getStringList(prefsKey) ?? const <String>[];
      for (final String id in stored) {
        if (!_revoked.contains(id)) _revoked.add(id);
      }
      notifyListeners();
    } catch (_) {
      // A locked store: nothing is marked revoked, Undo stays offered.
    }
  }

  bool isRevoked(String approvalId) => _revoked.contains(approvalId);

  /// An Undo for [approvalId] is on its way.
  bool isBusy(String approvalId) => _busy.contains(approvalId);

  /// Takes [grant] back out of the agent's policy on the host. True once
  /// the frame went out; false when the host cannot be asked (offline, an
  /// old host) — the row then keeps its Undo.
  Future<bool> revoke(
    AgentsApprovalGrant grant, {
    required String threadKey,
  }) async {
    if (!grant.isLasting || _busy.contains(grant.approvalId)) return false;
    _busy.add(grant.approvalId);
    notifyListeners();
    try {
      final String agentId = agentIdFor(threadKey);
      final AgentsPermissionsService service = _service;
      final bool sent;
      if (grant.scope == AgentsRelayApprovalRequest.scopeAlwaysSite) {
        sent = await _revokeSite(service, agentId, grant);
      } else {
        sent = await service.setApprovalMode(
          agentId,
          grant.actionClass!,
          AgentApprovals.modeAsk,
        );
      }
      if (sent) await _markRevoked(grant.approvalId);
      return sent;
    } catch (_) {
      return false;
    } finally {
      _busy.remove(grant.approvalId);
      notifyListeners();
    }
  }

  /// The host replaces a class's whole site list, so the list it gets must
  /// be the real one minus this site. Without the policy in hand the app
  /// asks for it first; sending a guessed list would drop the other sites.
  Future<bool> _revokeSite(
    AgentsPermissionsService service,
    String agentId,
    AgentsApprovalGrant grant,
  ) async {
    if (!service.approvalsSupported) return false;
    if (service.approvalsOf(agentId) == null) {
      final Completer<void> answered = Completer<void>();
      void listener() {
        if (service.approvalsOf(agentId) != null && !answered.isCompleted) {
          answered.complete();
        }
      }

      service.addListener(listener);
      try {
        if (!await service.refresh(agentId)) return false;
        await answered.future.timeout(replyTimeout, onTimeout: () {});
      } finally {
        service.removeListener(listener);
      }
      if (service.approvalsOf(agentId) == null) return false;
    }
    final AgentApprovals approvals = service.approvalsOf(agentId)!;
    final String wanted = _canonSite(grant.site!);
    final String? listed = approvals
        .sitesOf(grant.actionClass!)
        .where((String s) => _canonSite(s) == wanted)
        .firstOrNull;
    // Not on the list (any more): nothing to take back, and the row may
    // say so.
    if (listed == null) return true;
    return service.removeApprovalSite(agentId, grant.actionClass!, listed);
  }

  static String _canonSite(String site) {
    String s = site.trim().toLowerCase();
    if (s.startsWith('www.')) s = s.substring(4);
    return s;
  }

  Future<void> _markRevoked(String approvalId) async {
    await load();
    _revoked.remove(approvalId);
    _revoked.add(approvalId);
    while (_revoked.length > maxKept) {
      _revoked.removeAt(0);
    }
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, List<String>.of(_revoked));
    } catch (_) {
      // Kept for this session.
    }
  }

  @visibleForTesting
  void reset() {
    _agentForThread.clear();
    _revoked.clear();
    _busy.clear();
    _loading = null;
  }
}
