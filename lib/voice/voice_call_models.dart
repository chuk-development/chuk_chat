// lib/voice/voice_call_models.dart
//
// The plain data of a voice call: its mode and phase, one spoken turn, the
// record a finished call leaves in the chat, and the delegate contract that
// lets the voice worker hand work to the chat model or the host agent.
//
// Nothing here imports LiveKit, so the chat screens and the tests can use
// these types without a room.

import 'dart:async';

/// Which kind of chat the call belongs to. The worker reads it from the
/// dispatch metadata (`"mode": "chat" | "agents"`).
enum VoiceCallMode { chat, agents }

/// Where the one app-wide call is in its life.
enum VoiceCallPhase { idle, connecting, live, ending, ended, failed }

/// One spoken turn of the live transcript.
///
/// [role] is `'user'` (the local participant) or `'assistant'` (the voice
/// agent). A partial turn ([isFinal] false) is replaced by its final text
/// when the transcription segment closes.
class VoiceTurn {
  const VoiceTurn({
    required this.role,
    required this.text,
    required this.at,
    required this.isFinal,
  });

  factory VoiceTurn.fromJson(Map<String, dynamic> json) => VoiceTurn(
    role: json['role'] == roleUser ? roleUser : roleAssistant,
    text: json['text'] is String ? json['text'] as String : '',
    at: _parseTime(json['at']),
    isFinal: json['is_final'] != false,
  );

  static const String roleUser = 'user';
  static const String roleAssistant = 'assistant';

  /// `'user'` or `'assistant'`.
  final String role;
  final String text;

  /// When the segment started.
  final DateTime at;
  final bool isFinal;

  bool get isUser => role == roleUser;

  VoiceTurn copyWith({String? text, bool? isFinal}) => VoiceTurn(
    role: role,
    text: text ?? this.text,
    at: at,
    isFinal: isFinal ?? this.isFinal,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': role,
    'text': text,
    'at': at.toUtc().toIso8601String(),
    'is_final': isFinal,
  };

  @override
  bool operator ==(Object other) =>
      other is VoiceTurn &&
      other.role == role &&
      other.text == text &&
      other.at == at &&
      other.isFinal == isFinal;

  @override
  int get hashCode => Object.hash(role, text, at, isFinal);
}

/// What a finished call leaves behind in its chat: when it ran and what was
/// said. Stored locally by `VoiceCallStore` and drawn by
/// `VoiceCallRecordCard`.
class VoiceCallRecord {
  VoiceCallRecord({
    required this.chatId,
    required this.mode,
    required this.startedAt,
    required this.endedAt,
    required List<VoiceTurn> turns,
    List<VoiceCard> cards = const <VoiceCard>[],
  }) : turns = List<VoiceTurn>.unmodifiable(turns),
       cards = List<VoiceCard>.unmodifiable(cards);

  factory VoiceCallRecord.fromJson(Map<String, dynamic> json) {
    final Object? rawTurns = json['turns'];
    final Object? rawCards = json['cards'];
    return VoiceCallRecord(
      chatId: json['chat_id'] is String ? json['chat_id'] as String : '',
      mode: json['mode'] == VoiceCallMode.agents.name
          ? VoiceCallMode.agents
          : VoiceCallMode.chat,
      startedAt: _parseTime(json['started_at']),
      endedAt: _parseTime(json['ended_at']),
      turns: <VoiceTurn>[
        if (rawTurns is List)
          for (final Object? turn in rawTurns)
            if (turn is Map) VoiceTurn.fromJson(turn.cast<String, dynamic>()),
      ],
      cards: <VoiceCard>[
        if (rawCards is List)
          for (final Object? card in rawCards)
            if (card is Map) VoiceCard.fromJson(card.cast<String, dynamic>()),
      ],
    );
  }

  final String chatId;
  final VoiceCallMode mode;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<VoiceTurn> turns;

  /// What the agent showed on screen during the call (`ui.card`), oldest
  /// first. Records written before cards existed read as empty.
  final List<VoiceCard> cards;

  Duration get duration {
    final Duration d = endedAt.difference(startedAt);
    return d.isNegative ? Duration.zero : d;
  }

  /// The number of turns that finished (partials cut off by the hang-up are
  /// kept in [turns] but not counted here).
  int get finalTurnCount => turns.where((VoiceTurn t) => t.isFinal).length;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chat_id': chatId,
    'mode': mode.name,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'turns': <Map<String, dynamic>>[
      for (final VoiceTurn turn in turns) turn.toJson(),
    ],
    'cards': <Map<String, dynamic>>[
      for (final VoiceCard card in cards) card.toJson(),
    ],
  };
}

/// A rich payload the agent pushed to the screen during a call (`ui.card`
/// data topic): the forecast, the sources, the chart that speech cannot
/// carry. Wire format: new-voicemode `server/ui_bridge.py`, version 1.
class VoiceCard {
  VoiceCard({
    required this.id,
    required this.kind,
    required this.title,
    required this.at,
    this.subtitle,
    this.source,
    Map<String, dynamic> data = const <String, dynamic>{},
  }) : data = Map<String, dynamic>.unmodifiable(data);

  factory VoiceCard.fromJson(Map<String, dynamic> json) => VoiceCard(
    id: _string(json['id']) ?? '',
    kind: _string(json['kind']) ?? '',
    title: _string(json['title']) ?? '',
    subtitle: _string(json['subtitle']),
    source: _string(json['source']),
    data: json['data'] is Map
        ? (json['data'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{},
    at: _parseTime(json['at']),
  );

  /// The only `ui.card` protocol version this build reads.
  static const int supportedVersion = 1;

  /// Server id, stable across re-sends of the same card.
  final String id;

  /// Which renderer: `weather`, `search`, `news`, `article`, `stock`, `map`,
  /// `currency`, `calc`, `time`, `memory`, `task`, `reminder`, `device`;
  /// anything else draws as a key/value list.
  final String kind;
  final String title;
  final String? subtitle;

  /// Attribution, e.g. "Open-Meteo".
  final String? source;

  /// Kind-specific payload. Renderers read what they know and skip the rest.
  final Map<String, dynamic> data;

  /// When the card arrived.
  final DateTime at;

  double? number(String key) {
    final Object? v = data[key];
    return v is num ? v.toDouble() : null;
  }

  String? text(String key) {
    final Object? v = data[key];
    if (v == null) return null;
    final String s = v.toString();
    return s.isEmpty ? null : s;
  }

  List<Map<String, dynamic>> list(String key) {
    final Object? v = data[key];
    if (v is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final Object? e in v)
        if (e is Map) e.cast<String, dynamic>(),
    ];
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind,
    'title': title,
    'subtitle': subtitle,
    'source': source,
    'data': data,
    'at': at.toUtc().toIso8601String(),
  };
}

/// The live state of one tool call on the worker (`ui.tool` data topic).
class VoiceToolActivity {
  const VoiceToolActivity({
    required this.callId,
    required this.name,
    required this.status,
    required this.at,
  });

  final String callId;
  final String name;

  /// `running`, `done`, `error` or `cancelled`.
  final String status;
  final DateTime at;

  bool get isRunning => status == 'running';

  /// A follow-up update carries no name; keep the one the start gave.
  VoiceToolActivity mergedWith(VoiceToolActivity update) => VoiceToolActivity(
    callId: callId,
    name: update.name.isNotEmpty ? update.name : name,
    status: update.status,
    at: update.at,
  );

  /// The status line while it runs, e.g. `search_web` -> "Searching the web".
  String get label => switch (name) {
    'get_weather' => 'Checking the weather',
    'search_web' => 'Searching the web',
    'read_page' => 'Reading the page',
    'get_news' => 'Reading the news',
    'calculate' => 'Calculating',
    'get_time' => 'Checking the time',
    'convert_currency' => 'Converting',
    'get_stock' => 'Checking the price',
    'show_place' => 'Finding the place',
    'remember' => 'Remembering',
    'recall' => 'Recalling',
    'open_link' => 'Opening the link',
    'get_device_location' => 'Finding you',
    'get_device_status' => 'Checking the device',
    'delegate_task' => 'Handing it over',
    _ => name.isEmpty ? 'Working' : name.replaceAll('_', ' '),
  };
}

String? _string(Object? raw) => raw is String ? raw : null;

/// A result for a task the worker started through the delegate.
class VoiceTaskResult {
  const VoiceTaskResult({
    required this.taskId,
    required this.status,
    required this.result,
  });

  static const String statusDone = 'done';
  static const String statusFailed = 'failed';

  final String taskId;

  /// `'done'` or `'failed'`.
  final String status;
  final String result;
}

/// Hands work from the voice worker to the chat model (normal chat) or the
/// host agent (Agents thread). Implemented by the chat screen that owns the
/// call.
abstract class VoiceTaskDelegate {
  /// Start a task; return an id at once. Do not wait for the result.
  Future<String> startTask(String task);

  /// Results for started tasks: (taskId, status 'done'|'failed', resultText).
  Stream<VoiceTaskResult> get results;
}

DateTime _parseTime(Object? raw) {
  if (raw is String) {
    final DateTime? parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toLocal();
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
