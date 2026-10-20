// lib/services/user_sync_signal_service.dart
//
// Cross-device sync signals. The database sends a tiny broadcast on the
// private topic `user:<uid>` (event `changed`, payload `{t, op, id}`) from
// the trigger `public.notify_user_change()`
// (supabase/migrations/20261020000000_realtime_sync_signals.sql). The signal
// never carries row data. This service only reacts by running the pull that
// already exists for the table. Applying row data from the signal is what
// caused the races fixed in dee848a8, so it is not done here.
//
// The 30 s polls stay as the fallback. The channel is open only while the
// app is in the foreground ([pause] / [resume] from AppLifecycleService); in
// the background, push notifications do the job. Each (re)subscribe runs
// every handler once, so a signal missed while the channel was down is not
// lost.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/agents/roster_pins.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_storage_bootstrap.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Opens the signal channel for [userId] and returns a function that closes
/// it. [onSignal] gets the broadcast payload, [onSubscribed] fires on every
/// successful (re)join.
typedef SignalChannelOpener = Future<Future<void> Function()> Function(
  String userId, {
  required void Function(Map<String, dynamic> payload) onSignal,
  required VoidCallback onSubscribed,
});

class UserSyncSignalService {
  UserSyncSignalService._();
  static final UserSyncSignalService instance = UserSyncSignalService._();

  static const String tableEncryptedChats = 'encrypted_chats';
  static const String tableCoworkChats = 'cowork_chats';
  static const String tableAgentsChatPins = 'agents_chat_pins';
  static const String tableUserBilling = 'user_billing';

  /// Signals for one table that arrive within this window collapse into one
  /// pull.
  @visibleForTesting
  Duration debounce = const Duration(milliseconds: 750);

  /// Test hooks. A non-null entry replaces the default handler of a table.
  @visibleForTesting
  final Map<String, Future<void> Function()> handlerOverrides =
      <String, Future<void> Function()>{};

  /// Test hook for the build flag `FEATURE_AGENTS`.
  @visibleForTesting
  bool? agentsEnabledOverride;

  /// Test hook that replaces the Supabase channel.
  @visibleForTesting
  SignalChannelOpener? channelOpenerOverride;

  final StreamController<void> _billingController =
      StreamController<void>.broadcast();

  /// Fires when the `user_billing` row of the signed-in user changed. The
  /// credit widgets listen here and reload their balance.
  Stream<void> get billingChanged => _billingController.stream;

  String? _userId;
  bool _paused = false;
  Future<void> Function()? _close;
  final Map<String, Timer> _timers = <String, Timer>{};

  /// The user the service runs for, also while paused.
  String? get userId => _userId;

  @visibleForTesting
  bool get isOpen => _close != null;

  @visibleForTesting
  int get pendingTimers => _timers.length;

  bool get _agentsEnabled => agentsEnabledOverride ?? kFeatureAgents;

  /// Start listening for [userId]. Idempotent: a second call for the same
  /// user is a no-op; a call for a different user closes the old channel
  /// first.
  Future<void> start(String userId) async {
    if (_userId == userId && (_close != null || _paused)) return;
    // The same user's open is in flight: join it, do not start a second one.
    if (_userId == userId && _opening != null) return _open();
    await stop();
    _userId = userId;
    _paused = false;
    await _open();
  }

  /// Close the channel, cancel the pending pulls and forget the user.
  Future<void> stop() async {
    _userId = null;
    _paused = false;
    await _closeChannel();
  }

  /// App went to the background: close the channel and cancel the pending
  /// pulls, but keep the user for [resume].
  Future<void> pause() async {
    if (_userId == null) return;
    _paused = true;
    await _closeChannel();
  }

  /// App came back to the foreground: open the channel again for the kept
  /// user. The catch-up run on `subscribed` covers what was missed.
  Future<void> resume() async {
    if (_userId == null || _close != null) return;
    _paused = false;
    await _open();
  }

  Future<void> _closeChannel() async {
    for (final Timer t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    final close = _close;
    _close = null;
    if (close == null) return;
    try {
      await close();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [UserSyncSignal] close failed: ${e.runtimeType}');
      }
    }
  }

  /// The open that is in flight, if any. A second open must not start next
  /// to it: pause→resume while the opener still waits, or two quick
  /// [start] calls, would open two channels on the same topic, and closing
  /// the second one can remove the live one.
  Future<void>? _opening;

  /// Opens the channel unless one is open or opening. Waits for an open in
  /// flight first, then checks again: that open may have dropped its channel
  /// because a pause came in while it was waiting.
  Future<void> _open() async {
    for (Future<void>? pending = _opening; pending != null; pending = _opening) {
      await pending;
    }
    if (_userId == null || _paused || _close != null) return;
    late final Future<void> run;
    run = _openChannel().whenComplete(() {
      if (identical(_opening, run)) _opening = null;
    });
    _opening = run;
    await run;
  }

  Future<void> _openChannel() async {
    final String? userId = _userId;
    if (userId == null) return;
    final opener = channelOpenerOverride ?? _openSupabaseChannel;
    try {
      final close = await opener(
        userId,
        onSignal: handleSignal,
        onSubscribed: handleSubscribed,
      );
      // A stop/pause or a user switch while the channel was opening.
      if (_userId != userId || _paused || _close != null) {
        await close();
        return;
      }
      _close = close;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [UserSyncSignal] open failed: ${e.runtimeType}');
      }
    }
  }

  static Future<Future<void> Function()> _openSupabaseChannel(
    String userId, {
    required void Function(Map<String, dynamic> payload) onSignal,
    required VoidCallback onSubscribed,
  }) async {
    final client = SupabaseService.client;
    // supabase_flutter sets the realtime token on sign-in and on refresh by
    // itself. This call makes sure the join of a private channel does not
    // race that update; it is a no-op when the token is already set.
    final String? token = client.auth.currentSession?.accessToken;
    if (token != null) {
      try {
        await client.realtime.setAuth(token);
      } catch (_) {
        // An expired token is refreshed by gotrue, which sets it again.
      }
    }
    final channel = client.channel(
      'user:$userId',
      opts: const RealtimeChannelConfig(private: true),
    );
    channel
      ..onBroadcast(event: 'changed', callback: onSignal)
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          onSubscribed();
        } else if (kDebugMode) {
          debugPrint('⚠️ [UserSyncSignal] channel status: ${status.name}');
        }
      });
    if (kDebugMode) {
      debugPrint('🔄 [UserSyncSignal] channel opened');
    }
    return () => client.removeChannel(channel);
  }

  /// One broadcast from the trigger. The table name is the only field used.
  @visibleForTesting
  void handleSignal(Map<String, dynamic> message) {
    if (_close == null || _paused || _userId == null) return;
    // The broadcast arrives as `{type, event, payload: {t, op, id}}`; accept
    // the bare payload too.
    final Object? inner = message['payload'];
    final Map<dynamic, dynamic> payload = inner is Map ? inner : message;
    final Object? table = payload['t'];
    if (table is! String) return;
    _schedule(table);
  }

  /// The channel joined (first time or after a reconnect): run every pull
  /// once to catch signals sent while it was down.
  @visibleForTesting
  void handleSubscribed() {
    if (_paused || _userId == null) return;
    final tables = <String>[
      tableEncryptedChats,
      if (_agentsEnabled) tableCoworkChats,
      if (_agentsEnabled) tableAgentsChatPins,
      tableUserBilling,
    ];
    if (kDebugMode) {
      debugPrint('🔄 [UserSyncSignal] subscribed, catch-up ${tables.length}');
    }
    for (final String t in tables) {
      _schedule(t);
    }
  }

  void _schedule(String table) {
    final handler = _handlerFor(table);
    if (handler == null) return;
    _timers[table]?.cancel();
    _timers[table] = Timer(debounce, () {
      _timers.remove(table);
      if (_paused || _userId == null) return;
      if (kDebugMode) {
        debugPrint('🔄 [UserSyncSignal] pull $table');
      }
      unawaited(
        Future<void>.sync(handler).catchError((Object e) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [UserSyncSignal] $table pull failed: ${e.runtimeType}',
            );
          }
        }),
      );
    });
  }

  Future<void> Function()? _handlerFor(String table) {
    switch (table) {
      case tableEncryptedChats:
        return handlerOverrides[table] ?? ChatSyncService.syncNow;
      case tableCoworkChats:
        if (!_agentsEnabled) return null;
        return handlerOverrides[table] ?? AgentsChatStorageBootstrap.flushNow;
      case tableAgentsChatPins:
        if (!_agentsEnabled) return null;
        return handlerOverrides[table] ??
            () => RosterPins.instance.load(force: true);
      case tableUserBilling:
        return handlerOverrides[table] ??
            () async => _billingController.add(null);
      default:
        return null;
    }
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    await stop();
    handlerOverrides.clear();
    agentsEnabledOverride = null;
    channelOpenerOverride = null;
    debounce = const Duration(milliseconds: 750);
  }
}
