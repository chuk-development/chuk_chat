/// The zero-click cloud computer setup (CHAT-164), with no widget in it.
///
///     idle -> checking -> settingUp -> (slow) -> linking -> linked
///                |            |                    |
///                v            v                    v
///      hidden / suspended   failed / suspended   failed
///
/// * **checking**: one `GET` of the state. Nothing is drawn yet, so a user
///   without a cloud computer never sees a screen flash.
/// * **settingUp**: the app makes (or reads back) a one-time pairing token,
///   sends it with the `POST`, and claims the token's relay channel until the
///   cloud host has parked there. This is exactly the install page's wait
///   ([AgentsInstallFlow]); only the command is sent to the server instead of
///   being shown.
/// * **slow**: the same wait, after [AgentsCloudBoxFlow.slowAfter]. The screen
///   says that it takes longer and that the user can leave.
/// * **linking**: the shared invite pairing runs.
/// * **linked**: the trust is saved; the shell now has a computer.
/// * **hidden**: the server has no cloud computers (404) or the plan has none
///   (402, or the user status says so). The shell shows what it showed before.
/// * **suspended**: a payment problem stopped the computer.
/// * **failed**: anything else. [retry] starts again.
///
/// The flow runs at most once per start: [maybeStart] does nothing unless the
/// flow is idle, so a rebuild or a second signal cannot fire a second request.
/// The `POST` is idempotent on the server too, and the pending token is kept
/// in secure storage (never in plain preferences, never in a log), so a
/// restart or a resume ([AgentsCloudBoxFlow.resumed]) sends the same token
/// again, or a fresh one once it expired. Two runs are never closer than
/// [AgentsCloudBoxFlow.minGap] (10 s). The relay's pairing park lives only
/// 300 s and only the signed-in app can claim it, so the app keeps claiming
/// while the cloud host comes up, and picks the wait up again on every start.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_install_flow.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';

enum AgentsCloudBoxPhase {
  idle,
  checking,
  settingUp,
  slow,
  linking,
  linked,
  hidden,
  suspended,
  failed;

  /// True for the phases the shell draws the setup screen for.
  bool get visible => switch (this) {
    AgentsCloudBoxPhase.settingUp ||
    AgentsCloudBoxPhase.slow ||
    AgentsCloudBoxPhase.linking ||
    AgentsCloudBoxPhase.suspended ||
    AgentsCloudBoxPhase.failed => true,
    _ => false,
  };
}

/// Whether the user's plan includes a cloud computer: true, false, or null
/// when the app does not know (an older server). Null still sends the request;
/// a 402 then hides the feature.
typedef AgentsCloudBoxPlanGate = bool? Function();

class AgentsCloudBoxFlow extends ChangeNotifier {
  AgentsCloudBoxFlow({
    required AgentsCloudBoxApi api,
    required AgentsInstallTicketStore store,
    required AccountSessionSource sessionSource,
    required AgentsInstallClaimWaiter claimWaiter,
    required AgentsInstallPairer pair,
    AgentsCloudBoxPlanGate? planIncludesBox,
    bool Function()? hasComputer,
    this.slowAfter = const Duration(minutes: 2),
    this.maxTokens = 3,
    this.minGap = const Duration(seconds: 10),
    DateTime Function()? now,
    Random? random,
  }) : _api = api,
       _store = store,
       _sessionSource = sessionSource,
       _claimWaiter = claimWaiter,
       _pair = pair,
       _planIncludesBox = planIncludesBox ?? _unknownPlan,
       _hasComputer = hasComputer ?? _noComputer,
       _now = now ?? DateTime.now,
       _random = random;

  static bool? _unknownPlan() => null;
  static bool _noComputer() => false;

  /// Whether a computer is paired already (CHAT-177). The box is then ADDED
  /// next to it: the flow only books a new box, or goes on with a setup this
  /// device began (its pending token). A box that exists and that this
  /// device did not set up is either one of the paired computers or comes
  /// back with the restore, so the flow leaves it alone.
  final bool Function() _hasComputer;

  final AgentsCloudBoxApi _api;
  final AgentsInstallTicketStore _store;
  final AccountSessionSource _sessionSource;
  final AgentsInstallClaimWaiter _claimWaiter;
  final AgentsInstallPairer _pair;
  final AgentsCloudBoxPlanGate _planIncludesBox;
  final DateTime Function() _now;
  final Random? _random;

  /// When the setup screen says that it takes longer than usual.
  final Duration slowAfter;

  /// How many tokens one run may use. A token lives 30 minutes; when one
  /// expires before the cloud host parked, a fresh one is sent.
  final int maxTokens;

  AgentsCloudBoxPhase get phase => _phase;
  AgentsCloudBoxPhase _phase = AgentsCloudBoxPhase.idle;

  /// The server's last answer, or null before the first one.
  AgentsCloudBoxStatus? get status => _status;
  AgentsCloudBoxStatus? _status;

  /// True when [phase] is hidden because the plan has no cloud computer. A
  /// plan change ([planChanged]) may then start the flow again.
  bool get hiddenForPlan => _hiddenForPlan;
  bool _hiddenForPlan = false;

  /// The shortest time between two runs (two requests to the server).
  final Duration minGap;

  DateTime? _lastRunAt;
  Timer? _delayedRun;

  AgentsClaimCancel? _cancel;
  Timer? _slowTimer;
  int _generation = 0;
  bool _disposed = false;

  /// Starts the setup once. Does nothing unless the flow is idle.
  Future<void> maybeStart() async {
    if (_phase != AgentsCloudBoxPhase.idle) return;
    await _runThrottled();
  }

  /// Starts again after a failure or a payment fix.
  Future<void> retry() async {
    if (_running) return;
    await _runThrottled();
  }

  /// The app came back to the front (or started). A pending setup that
  /// failed or was paused is picked up again: the pending token is read back
  /// from secure storage, or a fresh one is made when it expired, and the
  /// idempotent request is sent again. A wait that still runs is left alone.
  Future<void> resumed() async {
    if (_running) return;
    switch (_phase) {
      case AgentsCloudBoxPhase.idle:
      case AgentsCloudBoxPhase.failed:
      case AgentsCloudBoxPhase.suspended:
        await _runThrottled();
      case AgentsCloudBoxPhase.hidden:
        await planChanged();
      default:
        return;
    }
  }

  bool get _running =>
      _phase == AgentsCloudBoxPhase.checking ||
      _phase == AgentsCloudBoxPhase.settingUp ||
      _phase == AgentsCloudBoxPhase.slow ||
      _phase == AgentsCloudBoxPhase.linking;

  /// Never two runs closer than [minGap]: a run asked for too early is
  /// delayed to the end of the gap, and a second ask in the gap joins it.
  Future<void> _runThrottled() async {
    final DateTime now = _now();
    final DateTime? last = _lastRunAt;
    if (last != null) {
      final Duration since = now.difference(last);
      if (since < minGap) {
        if (_delayedRun != null) return;
        _delayedRun = Timer(minGap - since, () {
          _delayedRun = null;
          unawaited(_run());
        });
        return;
      }
    }
    await _run();
  }

  /// The user status changed (for example right after a payment). A flow
  /// that was hidden only for the plan starts again when the plan now says
  /// yes.
  Future<void> planChanged() async {
    if (_phase != AgentsCloudBoxPhase.hidden || !_hiddenForPlan) return;
    if (_planIncludesBox() != true) return;
    await _runThrottled();
  }

  /// The device has a computer now (a restore, a manual pairing). Stops the
  /// wait and goes back to idle, so a later "no computer" can start again.
  void stop() {
    _stopRun();
    if (_phase == AgentsCloudBoxPhase.idle) return;
    _set(AgentsCloudBoxPhase.idle);
  }

  Future<void> _run() async {
    final int generation = _stopRun();
    _lastRunAt = _now();
    final String? userId = _sessionSource.current()?.userId;
    if (userId == null || userId.isEmpty) {
      // Signed out: stay idle so the next signal can start the flow.
      _set(AgentsCloudBoxPhase.idle);
      return;
    }
    _hiddenForPlan = false;
    _set(AgentsCloudBoxPhase.checking);

    final bool? included = _planIncludesBox();
    AgentsCloudBoxStatus current;
    try {
      current = await _api.fetch();
    } on AgentsCloudBoxException catch (error) {
      if (_stale(generation)) return;
      if (error.unavailable || included != true) {
        // Off on the server, or a quiet failure for a user who may have no
        // cloud computer at all: show nothing.
        _set(AgentsCloudBoxPhase.hidden);
      } else {
        _set(AgentsCloudBoxPhase.failed);
      }
      return;
    } catch (_) {
      if (_stale(generation)) return;
      _set(
        included == true
            ? AgentsCloudBoxPhase.failed
            : AgentsCloudBoxPhase.hidden,
      );
      return;
    }
    if (_stale(generation)) return;
    _status = current;
    if (current.state == AgentsCloudBoxState.suspended) {
      _set(AgentsCloudBoxPhase.suspended);
      return;
    }
    if (current.state == AgentsCloudBoxState.none && included == false) {
      _hiddenForPlan = true;
      _set(AgentsCloudBoxPhase.hidden);
      return;
    }
    if (_hasComputer() && current.state != AgentsCloudBoxState.none) {
      AgentsInstallTicket? pending;
      try {
        pending = await _store.loadFor(userId: userId, now: _now());
      } catch (_) {
        pending = null;
      }
      if (_stale(generation)) return;
      if (pending == null) {
        _set(AgentsCloudBoxPhase.hidden);
        return;
      }
    }

    for (var attempt = 0; attempt < maxTokens; attempt++) {
      final _Outcome outcome = await _requestAndWait(
        userId: userId,
        generation: generation,
        fresh: attempt > 0,
      );
      if (outcome != _Outcome.expired) return;
    }
    if (_stale(generation)) return;
    _set(AgentsCloudBoxPhase.failed);
  }

  /// One token: send it, wait for the cloud host, pair. Returns
  /// [_Outcome.expired] when the token ran out before the host parked.
  Future<_Outcome> _requestAndWait({
    required String userId,
    required int generation,
    required bool fresh,
  }) async {
    AgentsInstallTicket ticket;
    try {
      ticket = fresh
          ? await _store.mintAndSave(
              userId: userId,
              now: _now(),
              random: _random,
            )
          : await _store.loadOrMint(
              userId: userId,
              now: _now(),
              random: _random,
            );
    } catch (_) {
      // Secure storage is locked. The token still works for this run; it
      // only cannot survive a restart.
      ticket = AgentsInstallTicket.mint(
        userId: userId,
        now: _now(),
        random: _random,
      );
    }
    if (_stale(generation)) return _Outcome.done;

    final AgentsCloudBoxStatus answer;
    try {
      answer = await _api.request(ticket.token);
    } on AgentsCloudBoxException catch (error) {
      if (_stale(generation)) return _Outcome.done;
      if (error.noPlan || error.unavailable) {
        _hiddenForPlan = error.noPlan;
        await _dropTicket();
        _set(AgentsCloudBoxPhase.hidden);
      } else {
        _set(AgentsCloudBoxPhase.failed);
      }
      return _Outcome.done;
    } catch (_) {
      if (_stale(generation)) return _Outcome.done;
      _set(AgentsCloudBoxPhase.failed);
      return _Outcome.done;
    }
    if (_stale(generation)) return _Outcome.done;
    _status = answer;
    if (answer.state == AgentsCloudBoxState.suspended) {
      _set(AgentsCloudBoxPhase.suspended);
      return _Outcome.done;
    }

    final AgentsClaimCancel cancel = AgentsClaimCancel();
    _cancel = cancel;
    if (_phase != AgentsCloudBoxPhase.slow) {
      _set(AgentsCloudBoxPhase.settingUp);
      _slowTimer?.cancel();
      _slowTimer = Timer(slowAfter, () {
        if (!_stale(generation) && _phase == AgentsCloudBoxPhase.settingUp) {
          _set(AgentsCloudBoxPhase.slow);
        }
      });
    }

    final String? device;
    try {
      device = await _claimWaiter(
        ticket.invite,
        deadline: ticket.expiresAt,
        cancel: cancel,
      );
    } on AgentsCloudRelayException catch (error) {
      if (_stale(generation)) return _Outcome.done;
      if (error.code == 'claim_expired') {
        await _dropTicket();
        return _Outcome.expired;
      }
      _set(AgentsCloudBoxPhase.failed);
      return _Outcome.done;
    } catch (_) {
      if (_stale(generation)) return _Outcome.done;
      _set(AgentsCloudBoxPhase.failed);
      return _Outcome.done;
    }
    if (_stale(generation) || device == null) return _Outcome.done;

    _slowTimer?.cancel();
    _set(AgentsCloudBoxPhase.linking);
    try {
      await _pair(ticket.invite);
    } catch (_) {
      // A won claim cannot be won again: this token is spent.
      await _dropTicket();
      if (_stale(generation)) return _Outcome.done;
      _set(AgentsCloudBoxPhase.failed);
      return _Outcome.done;
    }
    await _dropTicket();
    if (_stale(generation)) return _Outcome.done;
    _set(AgentsCloudBoxPhase.linked);
    return _Outcome.done;
  }

  Future<void> _dropTicket() async {
    try {
      await _store.delete();
    } catch (_) {
      // A stale ticket is discarded on read once it expires.
    }
  }

  /// Cancels the running wait, if any, and opens a new run.
  int _stopRun() {
    _delayedRun?.cancel();
    _delayedRun = null;
    _cancel?.cancel();
    _cancel = null;
    _slowTimer?.cancel();
    _slowTimer = null;
    return ++_generation;
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _set(AgentsCloudBoxPhase phase) {
    if (_disposed) return;
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRun();
    super.dispose();
  }
}

enum _Outcome { done, expired }
