import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// A controller the test drives directly: set [set], push [emit] — no socket
/// and no real pairing ceremony. Shared by the adapter, ledger, replay-loader
/// and thread-view tests so they all exercise the same seam.
class FakeRelayController implements AgentsRelayController {
  final ValueNotifier<AgentsRelayState> _state =
      ValueNotifier<AgentsRelayState>(
    const AgentsRelayState(phase: AgentsRelayPhase.idle),
  );
  final StreamController<AgentsRelayInbound> _inbound =
      StreamController<AgentsRelayInbound>.broadcast(sync: true);

  int connectCalls = 0;
  final List<(String, int, int)> replayPages = <(String, int, int)>[];
  int reconnectCalls = 0;
  bool provisioned = false;

  /// When true, [reconnect] reports a failure instead of pairing — the host
  /// that stays away. That is what a view needs to give up on its own
  /// reconnects and offer the way out again.
  bool reconnectFails = false;

  final List<String> tasks = <String>[];
  final List<String> taskSessionKeys = <String>[];
  final List<String?> taskModelIds = <String?>[];
  final List<String?> taskProviderSlugs = <String?>[];
  final List<String?> taskReasoning = <String?>[];
  final List<bool> taskDebugFlags = <bool>[];

  /// The `regenerate` flag of each task, in order. A Retry sets it; every other
  /// send leaves it false.
  final List<bool> taskRegenerateFlags = <bool>[];

  int stopCalls = 0;
  final List<String> stopSessionKeys = <String>[];

  /// Run ids acknowledged after a live `done`.
  final List<String> ackedRunIds = <String>[];

  /// Every `replay` frame, as `(sessionKey, afterId)`.
  final List<(String, int)> replayRequests = <(String, int)>[];

  /// Every here.now publish decision, as `(approvalId, approved)`.
  final List<(String, bool)> approvalDecisions = <(String, bool)>[];

  /// Every `secrets` frame, as `(values, revision, requestId)`.
  final List<(Map<String, String>, int, String?)> secretsSent =
      <(Map<String, String>, int, String?)>[];

  /// When set, [requestStop] throws it — the "the stop never left" path.
  Object? stopError;

  /// When set, [sendTask] throws it.
  Object? taskError;

  @override
  ValueListenable<AgentsRelayState> get state => _state;

  @override
  Stream<AgentsRelayInbound> get inbound => _inbound.stream;

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {
    connectCalls++;
    _state.value = const AgentsRelayState(
      phase: AgentsRelayPhase.paired,
      peerDeviceId: 'host-laptop-1',
      sas: '428913',
    );
  }

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required AgentsStoredPairing pairing,
  }) async {
    reconnectCalls++;
    if (reconnectFails) {
      _state.value = const AgentsRelayState(
        phase: AgentsRelayPhase.error,
        detail: 'Host unreachable',
      );
      return;
    }
    _state.value = const AgentsRelayState(
      phase: AgentsRelayPhase.paired,
      peerDeviceId: 'host-laptop-1',
      detail: 'Reconnected',
    );
  }

  @override
  AgentsStoredPairing? get establishedTrust => null;

  @override
  Future<void> provisionAccount(AccountSession session) async {
    provisioned = true;
  }

  @override
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members, {
    bool agentToAgent = true,
  }) async {}

  @override
  Future<void> setRoomAgentToAgent(String roomId, bool enabled) async {}

  @override
  Future<void> sendRoomTask(String roomId, String message) async {}

  @override
  Future<void> requestRoomHistory(String roomId) async {}

  @override
  Future<void> deleteRoom(String roomId) async {}

  @override
  Future<void> renameRoom(String roomId, String name) async {}

  @override
  Future<void> createAgent(String agentId, String name) async {}

  @override
  Future<void> renameAgent(String agentId, String name) async {}

  @override
  Future<void> requestAgentList() async {}

  @override
  Future<void> addRoomMember(
    String roomId,
    String agentId,
    String handle,
  ) async {}

  @override
  Future<void> removeRoomMember(String roomId, String agentId) async {}

  @override
  Future<void> sendTask(
    String prompt, {
    String sessionKey = 'default',
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    bool debug = false,
    bool regenerate = false,
  }) async {
    tasks.add(prompt);
    taskSessionKeys.add(sessionKey);
    taskModelIds.add(modelId);
    taskProviderSlugs.add(providerSlug);
    taskReasoning.add(reasoningEffort);
    taskDebugFlags.add(debug);
    taskRegenerateFlags.add(regenerate);
    final error = taskError;
    if (error != null) throw error;
  }

  @override
  Future<void> requestStop({String sessionKey = 'default'}) async {
    stopCalls++;
    stopSessionKeys.add(sessionKey);
    final error = stopError;
    if (error != null) throw error;
  }

  @override
  Future<void> requestReplay({
    String sessionKey = 'default',
    int afterId = 0,
    int beforeId = 0,
    int limit = 0,
  }) async {
    replayRequests.add((sessionKey, afterId));
    // Replay paging (Bead cowork-axx): the page a request asked for.
    replayPages.add((sessionKey, beforeId, limit));
  }

  /// The session keys the view asked to replay, in order.
  List<String> get replaySessionKeys =>
      <String>[for (final request in replayRequests) request.$1];

  @override
  Future<void> sendRunAck(String runId) async {
    ackedRunIds.add(runId);
  }

  @override
  Future<void> startBrowserView({String? sessionKey}) async {}

  @override
  Future<void> stopBrowserView() async {}

  @override
  Future<void> sendBrowserData(Uint8List bytes) async {}

  @override
  Future<void> sendApprovalDecision({
    required String approvalId,
    required bool approved,
  }) async {
    approvalDecisions.add((approvalId, approved));
  }

  @override
  Future<void> sendSecrets({
    required Map<String, String> values,
    required int revision,
    String? requestId,
  }) async {
    secretsSent.add((Map<String, String>.of(values), revision, requestId));
  }

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
    _state.dispose();
  }

  void set(AgentsRelayState next) => _state.value = next;

  void emit(AgentsRelayInbound event) {
    if (!_inbound.isClosed) _inbound.add(event);
  }
}
