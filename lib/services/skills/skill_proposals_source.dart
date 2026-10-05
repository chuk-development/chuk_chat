// lib/services/skills/skill_proposals_source.dart
//
// The app's copy of the skill proposals the coworkers made, per thread
// (docs/WIRE_CONTRACT.md, "Skill proposals"; bead chuk_chat-al2u).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/skills/skill_proposal.dart';
import 'package:chuk_chat/services/skills/skills_source.dart';

/// Where one proposal stands, as the card draws it.
enum SkillProposalState { pending, saved, dismissed }

/// One proposal of one thread.
@immutable
class SkillProposalEntry {
  const SkillProposalEntry({
    required this.proposal,
    required this.threadKey,
    this.state = SkillProposalState.pending,
    this.savedName,
    this.hidden = false,
  });

  final AgentsRelaySkillProposal proposal;
  final String threadKey;
  final SkillProposalState state;

  /// The name the skill was saved under, once [state] is saved.
  final String? savedName;

  /// A decided card the thread has moved past. It is no longer drawn.
  final bool hidden;

  String get proposalId => proposal.proposalId;
  bool get isPending => state == SkillProposalState.pending;

  SkillProposalEntry copyWith({
    AgentsRelaySkillProposal? proposal,
    SkillProposalState? state,
    String? savedName,
    bool? hidden,
  }) => SkillProposalEntry(
    proposal: proposal ?? this.proposal,
    threadKey: threadKey,
    state: state ?? this.state,
    savedName: savedName ?? this.savedName,
    hidden: hidden ?? this.hidden,
  );
}

/// One instance for the app, like [SkillsSource]. It listens to
/// [AgentsRelayLink.inbound], keeps every `skill_proposal` (live and replayed)
/// under its thread, and sends the user's answer.
///
/// What a thread shows ([forThread]): every pending proposal, and the newest
/// decided one until the user sends the next task in that thread. A replayed
/// decided row draws its outcome; older decided rows of a full replay stay
/// out of the way, because the card sits at the end of the transcript and the
/// conversation has moved past them.
class SkillProposalsSource extends ChangeNotifier {
  SkillProposalsSource._();

  static final SkillProposalsSource instance = SkillProposalsSource._();

  final Map<String, List<SkillProposalEntry>> _byThread =
      <String, List<SkillProposalEntry>>{};
  StreamSubscription<AgentsRelayInbound>? _sub;

  /// Where the answer goes. Null reads the bound relay controller.
  @visibleForTesting
  AgentsSkillProposalControl? Function()? controlOverride;

  /// Called after a save, to refresh the Skills page. Null asks
  /// [SkillsSource] for a fresh `skills_list`.
  @visibleForTesting
  Future<bool> Function()? refreshSkillsOverride;

  /// Starts listening. Idempotent.
  void attach() {
    _sub ??= AgentsRelayLink.instance.inbound.listen(ingest);
  }

  /// The proposals [threadKey] draws, oldest first.
  List<SkillProposalEntry> forThread(String threadKey) =>
      List<SkillProposalEntry>.unmodifiable(
        (_byThread[threadKey] ?? const <SkillProposalEntry>[]).where(
          (SkillProposalEntry e) => !e.hidden,
        ),
      );

  SkillProposalEntry? byId(String proposalId) {
    for (final List<SkillProposalEntry> list in _byThread.values) {
      for (final SkillProposalEntry entry in list) {
        if (entry.proposalId == proposalId) return entry;
      }
    }
    return null;
  }

  /// Takes one inbound event. Public for tests; [attach] wires it.
  void ingest(AgentsRelayInbound event) {
    switch (event) {
      case AgentsRelaySkillProposal():
        _onProposal(event);
      case AgentsRelayTaskAck():
        // The user sent the next task in this thread: a decided card is
        // history now. A pending one stays; it can still be answered.
        final String? thread = event.sessionKey;
        if (thread == null || !event.isHeld || event.isDuplicate) return;
        if (_hideDecided(thread)) notifyListeners();
      default:
        return;
    }
  }

  void _onProposal(AgentsRelaySkillProposal proposal) {
    final String thread =
        proposal.sessionKey ?? AgentsRelayLink.instance.sessionKey.value;
    final List<SkillProposalEntry> list = _byThread.putIfAbsent(
      thread,
      () => <SkillProposalEntry>[],
    );
    final SkillProposalState incoming = proposal.isDecided
        ? (proposal.isSaved
              ? SkillProposalState.saved
              : SkillProposalState.dismissed)
        : SkillProposalState.pending;
    final int at = list.indexWhere(
      (SkillProposalEntry e) => e.proposalId == proposal.proposalId,
    );
    if (at >= 0) {
      final SkillProposalEntry known = list[at];
      // A decision the app saw stays: a replayed row from before it is older
      // news. A decided row for a card still open is the host's truth.
      if (!known.isPending || incoming == SkillProposalState.pending) return;
      list[at] = known.copyWith(
        proposal: proposal,
        state: incoming,
        savedName: proposal.savedName ?? proposal.name,
      );
      notifyListeners();
      return;
    }
    // A newer card pushes an older decided one out of view.
    _hideDecided(thread);
    list.add(
      SkillProposalEntry(
        proposal: proposal,
        threadKey: thread,
        state: incoming,
        savedName: incoming == SkillProposalState.saved
            ? (proposal.savedName ?? proposal.name)
            : null,
      ),
    );
    notifyListeners();
  }

  bool _hideDecided(String thread) {
    final List<SkillProposalEntry>? list = _byThread[thread];
    if (list == null) return false;
    bool changed = false;
    for (int i = 0; i < list.length; i++) {
      if (!list[i].isPending && !list[i].hidden) {
        list[i] = list[i].copyWith(hidden: true);
        changed = true;
      }
    }
    return changed;
  }

  /// Sends the user's answer and folds the host's reply into the card.
  ///
  /// `saved` / `dismissed` (also when another device decided first) decide
  /// the card; a save refreshes the Skills page. `invalid`, `not_found` and
  /// an app-side failure leave it pending and are returned for the card to
  /// show. Edits are sent only when given.
  Future<AgentsSkillProposalResult> decide(
    String proposalId, {
    required bool accept,
    String? name,
    String? description,
    String? body,
  }) async {
    final AgentsSkillProposalControl? control = _control();
    if (control == null) {
      return AgentsSkillProposalResult.failed(proposalId, 'not_connected');
    }
    final AgentsSkillProposalResult result;
    try {
      result = await control.sendSkillProposalDecision(
        proposalId: proposalId,
        accept: accept,
        name: name,
        description: description,
        body: body,
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[skill-proposals] decide failed: $error');
      return AgentsSkillProposalResult.failed(proposalId, 'not_sent');
    }
    if (result.isDecided) {
      _markDecided(proposalId, result);
      if (result.isSaved) unawaited(_refreshSkills());
    }
    return result;
  }

  void _markDecided(String proposalId, AgentsSkillProposalResult result) {
    for (final List<SkillProposalEntry> list in _byThread.values) {
      final int at = list.indexWhere(
        (SkillProposalEntry e) => e.proposalId == proposalId,
      );
      if (at < 0) continue;
      final SkillProposalEntry known = list[at];
      list[at] = known.copyWith(
        state: result.isSaved
            ? SkillProposalState.saved
            : SkillProposalState.dismissed,
        savedName: result.isSaved ? (result.name ?? known.proposal.name) : null,
        hidden: false,
      );
      notifyListeners();
      return;
    }
  }

  AgentsSkillProposalControl? _control() {
    final override = controlOverride;
    if (override != null) return override();
    final Object? controller = AgentsRelayLink.instance.controller.value;
    return controller is AgentsSkillProposalControl ? controller : null;
  }

  Future<void> _refreshSkills() async {
    try {
      await (refreshSkillsOverride ?? SkillsSource.instance.refresh)();
    } catch (error) {
      if (kDebugMode) debugPrint('[skill-proposals] skills refresh: $error');
    }
  }

  /// Test seam: forget everything and stop listening.
  @visibleForTesting
  void reset() {
    _sub?.cancel();
    _sub = null;
    _byThread.clear();
    controlOverride = null;
    refreshSkillsOverride = null;
  }
}
