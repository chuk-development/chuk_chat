/// The one-time install ticket: what lets one pasted command link a computer.
///
/// The app mints a token and shows ONE command to paste on the Linux computer:
///
///     curl -fsSL https://api.chuk.chat/agents/install.sh | bash -s -- --token=<P>-<D>
///
/// The token contract (the host implements the same):
///
///  * `P` — exactly 64 lowercase hex characters, 256 bits from
///    `Random.secure()`. It is the relay pairing channel the host parks on and
///    the app claims, and it is the §15 channel id.
///  * `D` — exactly 8 decimal digits from `Random.secure()`.
///  * The §15 pairing code is exactly `P-D`. So the ticket IS an ordinary
///    [AgentsPairingInvite]; nothing after the claim is new.
///
/// Only this app knows the token, the relay claim binds it to the signed-in
/// account, and it is valid for [kAgentsInstallTicketLifetime]. The pending
/// ticket is kept in secure storage, so leaving the install page and coming
/// back shows the SAME command and keeps waiting.
///
/// The token is key material. It is never logged, never put in an analytics
/// event and never put in an error text. [AgentsInstallTicket.toString] says
/// nothing about it.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';

/// How long a minted command stays valid.
const Duration kAgentsInstallTicketLifetime = Duration(minutes: 30);

/// Characters in the channel half of the token.
const int kAgentsInstallChannelLength = 64;

/// Digits in the code half of the token.
const int kAgentsInstallDigitsLength = 8;

final RegExp _channelPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _digitsPattern = RegExp(r'^[0-9]{8}$');

/// A pending install: the token halves, when it was made, when it stops
/// working, and the account it belongs to.
@immutable
class AgentsInstallTicket {
  const AgentsInstallTicket({
    required this.channel,
    required this.digits,
    required this.createdAt,
    required this.expiresAt,
    required this.userId,
  });

  /// Makes a fresh ticket for [userId]. [random] defaults to
  /// `Random.secure()`; a test passes a seeded one to get a known token.
  factory AgentsInstallTicket.mint({
    required String userId,
    required DateTime now,
    Random? random,
    Duration lifetime = kAgentsInstallTicketLifetime,
  }) {
    final Random source = random ?? Random.secure();
    final StringBuffer channel = StringBuffer();
    for (var i = 0; i < kAgentsInstallChannelLength ~/ 2; i++) {
      channel.write(source.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    final StringBuffer digits = StringBuffer();
    for (var i = 0; i < kAgentsInstallDigitsLength; i++) {
      digits.write(source.nextInt(10));
    }
    return AgentsInstallTicket(
      channel: channel.toString(),
      digits: digits.toString(),
      createdAt: now,
      expiresAt: now.add(lifetime),
      userId: userId,
    );
  }

  /// `P`: the pairing channel. Key material.
  final String channel;

  /// `D`: the eight digits. Key material together with [channel].
  final String digits;

  final DateTime createdAt;
  final DateTime expiresAt;

  /// The Supabase user id of the account that minted it.
  final String userId;

  /// `P-D`, the value of `--token=`. It is also the §15 pairing code.
  String get token => '$channel-$digits';

  /// The invite the app pairs with once the host has parked on [channel].
  AgentsPairingInvite get invite => AgentsPairingInvite(
    pairingChannel: channel,
    pairingCode: token,
    relayBase: Uri.parse(kDefaultAgentsRelayBase),
  );

  /// The one line the user pastes on the computer.
  String get command => agentsInstallCommand(token);

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  /// How long the command still works, never below zero.
  Duration remainingAt(DateTime now) {
    final Duration left = expiresAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// True when both halves have exactly the contract's shape.
  bool get isWellFormed =>
      _channelPattern.hasMatch(channel) && _digitsPattern.hasMatch(digits);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'channel': channel,
    'digits': digits,
    'created_at_ms': createdAt.millisecondsSinceEpoch,
    'expires_at_ms': expiresAt.millisecondsSinceEpoch,
    'user_id': userId,
  };

  /// Reads a stored ticket, or null when it is malformed or from a future
  /// version. A bad record means "no ticket", never a crash.
  static AgentsInstallTicket? tryParse(String source) {
    try {
      final Object? decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != 1) return null;
      final AgentsInstallTicket ticket = AgentsInstallTicket(
        channel: decoded['channel'] as String,
        digits: decoded['digits'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          decoded['created_at_ms'] as int,
        ),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          decoded['expires_at_ms'] as int,
        ),
        userId: decoded['user_id'] as String,
      );
      if (!ticket.isWellFormed || ticket.userId.isEmpty) return null;
      return ticket;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsInstallTicket &&
      other.channel == channel &&
      other.digits == digits &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.expiresAt.isAtSameMomentAs(expiresAt) &&
      other.userId == userId;

  /// Instants, not zones: a ticket read back from storage is in local time.
  @override
  int get hashCode => Object.hash(
    channel,
    digits,
    createdAt.millisecondsSinceEpoch,
    expiresAt.millisecondsSinceEpoch,
    userId,
  );

  /// Says nothing about the token: a `toString` is how a secret gets into a
  /// log line.
  @override
  String toString() => 'AgentsInstallTicket(expires: $expiresAt)';
}

/// The command for [token]: the installer piped to bash, the token as its one
/// argument.
String agentsInstallCommand(String token) =>
    'curl -fsSL $kAgentsInstallScriptUrl | bash -s -- --token=$token';

/// Keeps the one pending ticket in secure storage.
class AgentsInstallTicketStore {
  AgentsInstallTicketStore({AgentsSecureKeyValueStore? backend})
    : _store = backend ?? const FlutterSecureKeyValueStore();

  static const String _kTicket = 'cowork_install_ticket';

  final AgentsSecureKeyValueStore _store;

  /// The pending ticket of [userId], or null. A ticket that is expired at
  /// [now], belongs to another account, or cannot be read is deleted, so it
  /// can never be shown or used again.
  Future<AgentsInstallTicket?> loadFor({
    required String userId,
    required DateTime now,
  }) async {
    final String? raw = await _store.read(_kTicket);
    if (raw == null) return null;
    final AgentsInstallTicket? ticket = AgentsInstallTicket.tryParse(raw);
    if (ticket == null || ticket.userId != userId || ticket.isExpiredAt(now)) {
      await _store.delete(_kTicket);
      return null;
    }
    return ticket;
  }

  Future<void> save(AgentsInstallTicket ticket) =>
      _store.write(_kTicket, jsonEncode(ticket.toJson()));

  Future<void> delete() => _store.delete(_kTicket);

  /// The pending ticket of [userId], or a fresh one that is saved first.
  Future<AgentsInstallTicket> loadOrMint({
    required String userId,
    required DateTime now,
    Random? random,
  }) async {
    final AgentsInstallTicket? pending = await loadFor(
      userId: userId,
      now: now,
    );
    if (pending != null) return pending;
    return mintAndSave(userId: userId, now: now, random: random);
  }

  /// Replaces any pending ticket with a fresh one ("New command").
  Future<AgentsInstallTicket> mintAndSave({
    required String userId,
    required DateTime now,
    Random? random,
  }) async {
    final AgentsInstallTicket ticket = AgentsInstallTicket.mint(
      userId: userId,
      now: now,
      random: random,
    );
    await save(ticket);
    return ticket;
  }
}
