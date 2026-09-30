// lib/voice/incoming/relay_call_state_sender.dart
//
// [CallStateSender] over the live Agents transport. The transport is the one
// [AgentsRelayLink] holds right now; it changes on every reconnect. A state
// that cannot go out (no transport, not paired, a send that fails) waits in a
// short queue and goes out, in order, once the host is attached again: an
// `accepted` lost to a network blip would otherwise let the host turn an
// answered call into `missed`.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_voice_call_frames.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';

class RelayCallStateSender implements CallStateSender {
  RelayCallStateSender({
    ValueListenable<AgentsRelayController?>? controller,
    this.maxQueued = 32,
    this.maxAge = const Duration(minutes: 10),
    this.retryAfter = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _controller = controller ?? AgentsRelayLink.instance.controller,
       _now = now ?? DateTime.now {
    _controller.addListener(_rebind);
    _rebind();
  }

  final ValueListenable<AgentsRelayController?> _controller;

  /// At most this many states wait; the oldest go first.
  final int maxQueued;

  /// A state older than this is dropped instead of sent: the host has long
  /// decided the call by then.
  final Duration maxAge;

  /// A send that failed while the host looked attached is tried again after
  /// this long.
  final Duration retryAfter;
  final DateTime Function() _now;

  final List<_Queued> _queue = <_Queued>[];
  AgentsRelayController? _bound;
  Timer? _retry;
  bool _flushing = false;
  bool _disposed = false;

  /// States waiting for the host (tests).
  @visibleForTesting
  int get queued => _queue.length;

  @override
  Future<void> send(String callId, String state) async {
    if (_disposed) return;
    _queue.add(_Queued(callId, state, _now()));
    while (_queue.length > maxQueued) {
      _queue.removeAt(0);
    }
    await _flush();
  }

  void _rebind() {
    final AgentsRelayController? next = _controller.value;
    if (identical(next, _bound)) return;
    _bound?.state.removeListener(_onState);
    _bound = next;
    next?.state.addListener(_onState);
    unawaited(_flush());
  }

  void _onState() => unawaited(_flush());

  Future<void> _flush() async {
    if (_flushing || _disposed) return;
    final AgentsRelayController? c = _controller.value;
    if (c == null || c is! AgentsVoiceCallControl || !c.state.value.isPaired) {
      return;
    }
    final AgentsVoiceCallControl control = c as AgentsVoiceCallControl;
    _flushing = true;
    try {
      final DateTime cutoff = _now().subtract(maxAge);
      _queue.removeWhere((_Queued q) => q.at.isBefore(cutoff));
      while (_queue.isNotEmpty) {
        final _Queued next = _queue.first;
        try {
          await control.sendVoiceCallState(
            callId: next.callId,
            state: next.state,
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '[incoming-call] ${next.callId} ${next.state} not sent '
              '(${e.runtimeType}); kept',
            );
          }
          _retry?.cancel();
          _retry = Timer(retryAfter, () => unawaited(_flush()));
          return;
        }
        if (_queue.isNotEmpty && identical(_queue.first, next)) {
          _queue.removeAt(0);
        }
        if (kDebugMode) {
          debugPrint('[incoming-call] sent ${next.callId} ${next.state}');
        }
      }
    } finally {
      _flushing = false;
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _controller.removeListener(_rebind);
    _bound?.state.removeListener(_onState);
    _bound = null;
    _queue.clear();
  }
}

class _Queued {
  _Queued(this.callId, this.state, this.at);

  final String callId;
  final String state;
  final DateTime at;
}
