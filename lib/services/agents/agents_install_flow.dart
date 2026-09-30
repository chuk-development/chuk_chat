/// The install page's state machine, with no widget in it.
///
///     preparing -> waiting -> linking -> linked
///                     |          |
///                     v          v
///                  expired     failed
///
/// * **preparing**: the pending ticket is read back, or a fresh one is made.
/// * **waiting**: the command is on screen, and the app claims the ticket's
///   channel again and again until the computer has run the command and parked
///   there ([AgentsCloudRelaySocket.waitForPairingClaim]).
/// * **linking**: the relay bound the computer to this account; the normal
///   invite pairing runs ([AgentsInstallPairer]).
/// * **linked**: the trust is saved, and the ticket is deleted.
///
/// "New command" throws the pending ticket away and starts again from a fresh
/// one. Closing the page cancels the wait but keeps the ticket, so coming back
/// within its lifetime shows the same command and waits again.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';

/// Waits until the computer has parked on the invite's channel and claims it.
/// Returns the host's device id, or null when [cancel] fired. Throws
/// [AgentsCloudRelayException] (code `claim_expired` at [deadline]).
typedef AgentsInstallClaimWaiter = Future<String?> Function(
  AgentsPairingInvite invite, {
  required DateTime deadline,
  required AgentsClaimCancel cancel,
});

/// Runs the shared invite pairing and saves the trust. Throws on failure.
typedef AgentsInstallPairer = Future<void> Function(AgentsPairingInvite invite);

enum AgentsInstallPhase {
  preparing,
  waiting,
  linking,
  linked,
  expired,
  failed,
  signedOut,
}

class AgentsInstallFlow extends ChangeNotifier {
  AgentsInstallFlow({
    required AgentsInstallTicketStore store,
    required AccountSessionSource sessionSource,
    required AgentsInstallClaimWaiter claimWaiter,
    required AgentsInstallPairer pair,
    DateTime Function()? now,
    Random? random,
  }) : _store = store,
       _sessionSource = sessionSource,
       _claimWaiter = claimWaiter,
       _pair = pair,
       _now = now ?? DateTime.now,
       _random = random;

  final AgentsInstallTicketStore _store;
  final AccountSessionSource _sessionSource;
  final AgentsInstallClaimWaiter _claimWaiter;
  final AgentsInstallPairer _pair;
  final DateTime Function() _now;
  final Random? _random;

  AgentsInstallPhase get phase => _phase;
  AgentsInstallPhase _phase = AgentsInstallPhase.preparing;

  /// The ticket on screen. Null before [start] has made or read one.
  AgentsInstallTicket? get ticket => _ticket;
  AgentsInstallTicket? _ticket;

  /// One plain sentence about the last failure. Never the token.
  String? get message => _message;
  String? _message;

  /// The clock the page reads for the time left.
  DateTime now() => _now();

  AgentsClaimCancel? _cancel;

  /// Bumped for every new run. A result from an older run is dropped.
  int _generation = 0;
  bool _disposed = false;

  static const String _failedText =
      'Your computer could not be linked. Make a new command and run it '
      'again.';

  static const String _signedOutText =
      'Sign in first. Then you can add your computer.';

  /// Reads the pending ticket of this account, or makes one, and starts to
  /// wait for the computer.
  Future<void> start() => _begin(fresh: false);

  /// Throws the pending ticket away and starts again with a new one.
  Future<void> newCommand() => _begin(fresh: true);

  /// The "pair with a code" way: stops the wait and pairs with [invite] (from
  /// the code page) through the same sequence.
  Future<void> pairWithInvite(AgentsPairingInvite invite) async {
    final int generation = _stopWaiting();
    await _link(invite, generation);
  }

  Future<void> _begin({required bool fresh}) async {
    final int generation = _stopWaiting();
    final String? userId = _sessionSource.current()?.userId;
    if (userId == null || userId.isEmpty) {
      _set(AgentsInstallPhase.signedOut, message: _signedOutText);
      return;
    }
    _ticket = fresh ? null : _ticket;
    _set(AgentsInstallPhase.preparing);
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
      // Secure storage is not available (a locked keystore). The command
      // still works; it only cannot survive leaving the page.
      ticket = AgentsInstallTicket.mint(
        userId: userId,
        now: _now(),
        random: _random,
      );
    }
    if (_stale(generation)) return;
    _ticket = ticket;
    if (ticket.isExpiredAt(_now())) {
      _set(AgentsInstallPhase.expired);
      return;
    }
    await _wait(ticket, generation);
  }

  Future<void> _wait(AgentsInstallTicket ticket, int generation) async {
    final AgentsClaimCancel cancel = AgentsClaimCancel();
    _cancel = cancel;
    _set(AgentsInstallPhase.waiting);
    final String? device;
    try {
      device = await _claimWaiter(
        ticket.invite,
        deadline: ticket.expiresAt,
        cancel: cancel,
      );
    } on AgentsCloudRelayException catch (error) {
      if (_stale(generation)) return;
      if (error.code == 'claim_expired') {
        _set(AgentsInstallPhase.expired);
      } else {
        _set(AgentsInstallPhase.failed, message: error.message);
      }
      return;
    } catch (_) {
      if (_stale(generation)) return;
      _set(AgentsInstallPhase.failed, message: _failedText);
      return;
    }
    if (_stale(generation) || device == null) return;
    await _link(ticket.invite, generation);
  }

  Future<void> _link(AgentsPairingInvite invite, int generation) async {
    _set(AgentsInstallPhase.linking);
    try {
      await _pair(invite);
    } catch (error) {
      // A won claim cannot be won again, and the host answers one join per
      // claim, so this command is spent. Drop it: the next open makes a new
      // one instead of showing the same dead command again.
      try {
        await _store.delete();
      } catch (_) {
        // A stale ticket is discarded on read once it expires.
      }
      if (_stale(generation)) return;
      _set(
        AgentsInstallPhase.failed,
        message: error is AgentsCloudRelayException
            ? error.message
            : _failedText,
      );
      return;
    }
    try {
      await _store.delete();
    } catch (_) {
      // The ticket expires on its own; a stale one is discarded on read.
    }
    if (_stale(generation)) return;
    _ticket = null;
    _set(AgentsInstallPhase.linked);
  }

  /// Cancels the running wait, if any, and opens a new run.
  int _stopWaiting() {
    _cancel?.cancel();
    _cancel = null;
    return ++_generation;
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _set(AgentsInstallPhase phase, {String? message}) {
    if (_disposed) return;
    _phase = phase;
    _message = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    _cancel = null;
    super.dispose();
  }
}
