// lib/services/prompt_cache/prompt_context.dart
//
// Keeps the request prefix of a chat stable, so the provider's prompt cache
// hits. Providers cache the prefix byte by byte: system prompt, tools[], then
// the history. The first byte that changes makes everything after it a cache
// miss at full price. The rules (docs/GOTCHAS.md, "Prompt cache: keep the
// prefix stable"):
//
// * The system prompt holds nothing that changes during a chat. The date is
//   not in it: each user message carries its own `[Sent: …]` line, made from
//   that message's stored `sentAt`, so the same message always gives the same
//   bytes.
// * Soul, user info, memory and the MCP server list are a snapshot, taken
//   when the chat sends its first request and stored with that user message
//   (`modelContext`). A later change is not written into the system prompt;
//   it rides as a tagged note (`[memory updated]`, `[connectors updated]`)
//   at the head of the next user message, stored with that message.
// * An activated skill's body is a `<skill_content>` user message at the
//   point where it was loaded, stored with the user message of that turn.
//
// Pure Dart: no Flutter, no storage. The tool loop and the history builder
// call into it.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Explains the `[Sent: …]` line to the model. Static text: it sits in the
/// system prompt and must never change.
const String kSentStampSystemLine =
    'Each user message starts with a line like [Sent: Wed 2026-11-04 14:32]. '
    'It is the time the user sent that message, in the user\'s local time '
    '(a zone is named when it is known). Use the newest one as the current '
    'date and time. Never write such a line yourself.';

const List<String> _weekdays = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

final RegExp _isoStamp = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})'
  r'(?::\d{2}(?:[.,]\d+)?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$',
);

/// The `[Sent: …]` line for a stored `sentAt`, or null when there is no
/// usable stamp.
///
/// Made from the string alone, never from the device clock or time zone:
/// the wall-clock fields are taken as written. A stamp with `Z` is named
/// `UTC`, one with an offset `UTC+hh:mm`; a stamp without either (what
/// `DateTime.now().toIso8601String()` writes) is local time and gets no zone.
/// So the same stored message renders the same bytes on every device and
/// after every restart.
String? sentStampLine(String? sentAt) {
  final raw = sentAt?.trim() ?? '';
  if (raw.isEmpty) return null;
  final m = _isoStamp.firstMatch(raw);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final weekday = DateTime.utc(year, month, day).weekday;
  final zone = _zoneLabel(m.group(6));
  final date =
      '${m.group(1)}-${m.group(2)}-${m.group(3)} ${m.group(4)}:${m.group(5)}';
  return '[Sent: ${_weekdays[weekday - 1]} $date${zone.isEmpty ? '' : ' $zone'}]';
}

String _zoneLabel(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  if (raw == 'Z') return 'UTC';
  final sign = raw[0];
  final digits = raw.substring(1).replaceAll(':', '');
  final hh = digits.substring(0, 2);
  final mm = digits.length >= 4 ? digits.substring(2, 4) : '00';
  if (hh == '00' && mm == '00') return 'UTC';
  return 'UTC$sign$hh:$mm';
}

/// The text a user message has when it is sent to the model: the tagged
/// notes, then the `[Sent: …]` line, then the message. Used for the turn
/// being sent now and for the same message in every later history, so both
/// are byte-identical. Trimmed, because the server trims history text too.
String renderUserTurnForModel({
  required String text,
  String? sentAt,
  List<String> notes = const <String>[],
}) {
  final parts = <String>[
    for (final note in notes)
      if (note.trim().isNotEmpty) note.trim(),
  ];
  final stamp = sentStampLine(sentAt);
  final body = text.trim();
  final head = stamp == null ? body : (body.isEmpty ? stamp : '$stamp\n$body');
  if (head.isNotEmpty) parts.add(head);
  return parts.join('\n\n');
}

/// The multimodal content of a user message: its text, then one
/// `image_url` part per image reference (storage path or data URL), in
/// order. The send resolves the references (`ImageBudget`). One function for
/// the history and for the turn's own entry on later passes of a turn, so
/// both have the same shape.
List<Map<String, dynamic>> userContentWithImages(
  String text,
  List<String> imageRefs,
) => <Map<String, dynamic>>[
  if (text.isNotEmpty) {'type': 'text', 'text': text},
  for (final url in imageRefs)
    {
      'type': 'image_url',
      'image_url': {'url': url},
    },
];

/// The user-role message that carries an activated skill's instructions.
String skillContentMessage(String name, String body) =>
    '<skill_content name="$name">\n${body.trim()}\n</skill_content>';

/// Whether [history] already holds the `<skill_content>` message of [name].
bool historyHasSkillContent(List<Map<String, dynamic>> history, String name) {
  final marker = '<skill_content name="$name">';
  for (final entry in history) {
    if (entry['role'] != 'user') continue;
    final content = entry['content'];
    // `contains`, not `startsWith`: in prompt-based mode the body rides
    // inside the tool-results message of its round.
    if (content is String && content.contains(marker)) return true;
  }
  return false;
}

/// The row left where a skill body is no longer sent (a turn whose tool
/// rounds are not replayed any more). The model then knows to load it again;
/// the `skill` tool sends the body again because the history no longer
/// holds it ([historyHasSkillContent]).
String skillDroppedMarker(String name) =>
    '[skill $name was loaded earlier; call skill again if needed]';

/// One entry of the skills catalog as the system prompt lists it.
class SkillCatalogEntry {
  const SkillCatalogEntry(this.name, this.description);
  final String name;
  final String description;

  @override
  bool operator ==(Object other) =>
      other is SkillCatalogEntry &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(name, description);
}

/// The parts of the system prompt that can change while a chat runs. Frozen
/// per chat: the snapshot taken at the first request builds every system
/// prompt of the chat.
class PromptState {
  const PromptState({
    this.identity = false,
    this.soul = '',
    this.user = '',
    this.memory = '',
    this.mcpConnected = const <String>[],
    this.mcpUnconnected = const <String>[],
    this.skills,
    this.toolHistory,
  });

  /// Whether the identity section (soul, user info, memory) is on.
  final bool identity;
  final String soul;
  final String user;
  final String memory;

  /// Names of the connected MCP servers (and the Chukdoo connector).
  final List<String> mcpConnected;

  /// Catalogue ids of the servers that can be connected.
  final List<String> mcpUnconnected;

  /// The skills catalog (name + description). Null: not recorded (a
  /// snapshot from before the catalog was frozen); the live catalog is used.
  final List<SkillCatalogEntry>? skills;

  /// Snapshot only: whether earlier turns' tool rounds are replayed in the
  /// history of this chat (the `includeToolResultsInHistory` setting when
  /// the chat started). Frozen, so the history form never flips mid-chat.
  final bool? toolHistory;

  /// A copy with [skills] and [toolHistory] replaced.
  PromptState withExtras({
    List<SkillCatalogEntry>? skills,
    bool? toolHistory,
  }) => PromptState(
    identity: identity,
    soul: soul,
    user: user,
    memory: memory,
    mcpConnected: mcpConnected,
    mcpUnconnected: mcpUnconnected,
    skills: skills ?? this.skills,
    toolHistory: toolHistory ?? this.toolHistory,
  );

  /// Equal catalogs. An unrecorded catalog ([skills] null) never differs:
  /// there is nothing to compare against.
  bool sameSkillsAs(PromptState other) {
    final a = skills;
    final b = other.skills;
    if (a == null || b == null) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool sameIdentityAs(PromptState other) =>
      identity == other.identity &&
      soul == other.soul &&
      user == other.user &&
      memory == other.memory;

  bool sameMcpAs(PromptState other) =>
      _sameList(mcpConnected, other.mcpConnected) &&
      _sameList(mcpUnconnected, other.mcpUnconnected);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'identity': identity,
    if (soul.isNotEmpty) 'soul': soul,
    if (user.isNotEmpty) 'user': user,
    if (memory.isNotEmpty) 'memory': memory,
    if (mcpConnected.isNotEmpty) 'mcp': mcpConnected,
    if (mcpUnconnected.isNotEmpty) 'mcpAvailable': mcpUnconnected,
    if (skills != null)
      'skills': [
        for (final s in skills!)
          <String, String>{'n': s.name, 'd': s.description},
      ],
    'toolHistory': ?toolHistory,
  };

  static PromptState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    List<String> strings(Object? v) => v is List
        ? v.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    return PromptState(
      identity: raw['identity'] == true,
      soul: raw['soul']?.toString() ?? '',
      user: raw['user']?.toString() ?? '',
      memory: raw['memory']?.toString() ?? '',
      mcpConnected: strings(raw['mcp']),
      mcpUnconnected: strings(raw['mcpAvailable']),
      skills: raw['skills'] is List
          ? [
              for (final e in raw['skills'] as List)
                if (e is Map && e['n'] is String)
                  SkillCatalogEntry(e['n'] as String, e['d']?.toString() ?? ''),
            ]
          : null,
      toolHistory: raw['toolHistory'] is bool
          ? raw['toolHistory'] as bool
          : null,
    );
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A skill body that was loaded in a turn.
class SkillContent {
  const SkillContent(this.name, this.body);
  final String name;
  final String body;
}

/// What the model was told around one user message, stored on that message
/// as `modelContext` (JSON). Rebuilding the history from it gives the bytes
/// that were sent, after a restart and on another device too.
class TurnPromptContext {
  TurnPromptContext({
    this.snapshot,
    this.state,
    List<String>? notes,
    List<SkillContent>? skills,
    this.sent,
    this.transcript,
  }) : notes = notes ?? <String>[],
       skills = skills ?? <SkillContent>[];

  /// Set on the user message whose request took the chat's snapshot.
  PromptState? snapshot;

  /// The state after this message's notes; set when [notes] is not empty.
  PromptState? state;

  /// Tagged notes sent at the head of this user message.
  final List<String> notes;

  /// Skills loaded during this turn, in load order.
  final List<SkillContent> skills;

  /// The user text this turn sent, before its notes and `[Sent: …]` line,
  /// when it differs from the stored display text (a turn with documents:
  /// `Document: … User query: …`). In storage, each document body is a
  /// [kDocBodyMarkerStart] marker that points into the message's
  /// attachments ([PromptContextLedger.storedContextOf]).
  String? sent;

  /// Everything this turn's tool loop sent after its user message, in the
  /// form it was sent: native assistant `tool_calls` + `tool` messages with
  /// the capped results, `<skill_content>` messages, the prompt-based
  /// rounds and the user message of the last pass. Null for a one-pass
  /// turn. The next turn's history replays it as it is, so it starts with
  /// this turn's last request, byte for byte.
  List<Map<String, dynamic>>? transcript;

  bool get isEmpty =>
      snapshot == null &&
      state == null &&
      notes.isEmpty &&
      skills.isEmpty &&
      sent == null &&
      (transcript == null || transcript!.isEmpty);

  /// The names of the skills whose bodies the [transcript] carries.
  List<String> get transcriptSkillNames {
    final names = <String>[];
    final pattern = RegExp(r'<skill_content name="([^"]+)">');
    for (final entry in transcript ?? const <Map<String, dynamic>>[]) {
      final content = entry['content'];
      if (entry['role'] != 'user' || content is! String) continue;
      for (final m in pattern.allMatches(content)) {
        if (!names.contains(m.group(1)!)) names.add(m.group(1)!);
      }
    }
    return names;
  }

  String encode() => jsonEncode(<String, dynamic>{
    'v': 1,
    if (snapshot != null) 'snapshot': snapshot!.toJson(),
    if (state != null) 'state': state!.toJson(),
    if (notes.isNotEmpty) 'notes': notes,
    if (skills.isNotEmpty)
      'skills': [
        for (final s in skills)
          <String, String>{'name': s.name, 'body': s.body},
      ],
    'sent': ?sent,
    if (transcript != null && transcript!.isNotEmpty) 'transcript': transcript,
  });

  /// Null for a missing or unreadable value: an old message, or one from a
  /// newer format, is sent as a plain message.
  static TurnPromptContext? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != 1) return null;
      final notes = decoded['notes'];
      final skills = decoded['skills'];
      return TurnPromptContext(
        snapshot: PromptState.fromJson(decoded['snapshot']),
        state: PromptState.fromJson(decoded['state']),
        notes: notes is List ? notes.map((e) => e.toString()).toList() : null,
        skills: skills is List
            ? [
                for (final s in skills)
                  if (s is Map && s['name'] is String && s['body'] is String)
                    SkillContent(s['name'] as String, s['body'] as String),
              ]
            : null,
        sent: decoded['sent'] is String ? decoded['sent'] as String : null,
        transcript: decoded['transcript'] is List
            ? [
                for (final e in decoded['transcript'] as List)
                  if (e is Map) Map<String, dynamic>.from(e),
              ]
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The prompt context that a built history carries: the chat's snapshot and
/// the state after every stored note. Attached to the history list itself
/// (an [Expando], so nothing extra goes over the wire) by
/// `ChatHistoryBuilder.build` and read by the tool loop's `createSession`.
class HistoryPromptContext {
  const HistoryPromptContext({
    this.snapshot,
    this.effective,
    this.toolHistory = true,
  });

  final PromptState? snapshot;
  final PromptState? effective;

  /// Whether this history replays earlier turns' tool rounds. A chat that
  /// takes its snapshot now stores it ([PromptState.toolHistory]).
  final bool toolHistory;

  static final Expando<HistoryPromptContext> _byHistory =
      Expando<HistoryPromptContext>('HistoryPromptContext');

  static HistoryPromptContext? of(List<Map<String, dynamic>> history) =>
      _byHistory[history];

  static void attach(
    List<Map<String, dynamic>> history,
    HistoryPromptContext context,
  ) {
    _byHistory[history] = context;
  }
}

/// The `modelContext` of user messages whose turn is still in memory only,
/// keyed by the message's `sentAt` (unique to the microsecond). The chat
/// save reads it (`ChatStorageService`) and stores it on the message; the
/// history builder reads it for a message whose map has not been saved and
/// reloaded yet.
class PromptContextLedger {
  PromptContextLedger._();

  static const int _cap = 256;
  static final Map<String, String> _bySentAt = <String, String>{};

  /// Records the context of the turn that sends the user message stamped
  /// [sentAt]. An empty context is recorded too: it says "this message has
  /// no context any more" and hides a stale stored one (a resend).
  static void put(String? sentAt, TurnPromptContext context) {
    final key = sentAt?.trim() ?? '';
    if (key.isEmpty) return;
    _bySentAt.remove(key);
    _bySentAt[key] = context.isEmpty ? '' : context.encode();
    while (_bySentAt.length > _cap) {
      _bySentAt.remove(_bySentAt.keys.first);
    }
  }

  /// The `modelContext` of [message]: the one this app session recorded for
  /// it (it wins: a resend replaces the stored one), else the stored one.
  /// Null when there is none.
  static String? contextOf(Map<String, dynamic> message) {
    final key = message['sentAt']?.toString().trim() ?? '';
    if (key.isNotEmpty && _bySentAt.containsKey(key)) {
      final recorded = _bySentAt[key]!;
      return recorded.isEmpty ? null : recorded;
    }
    final stored = message['modelContext'];
    if (stored is String && stored.isNotEmpty) return stored;
    return null;
  }

  /// The `modelContext` to store on [message]: [contextOf], with the
  /// turn's sent text dropped when it equals the display text, and each
  /// document body in it replaced by a marker that points into the
  /// message's `attachments` (the bodies are stored there already).
  static String? storedContextOf(Map<String, dynamic> message) {
    final raw = contextOf(message);
    final context = TurnPromptContext.decode(raw);
    if (context == null || context.sent == null) return raw;
    final display = message['text']?.toString().trim() ?? '';
    if (context.sent!.trim() == display) {
      context.sent = null;
    } else {
      context.sent = compactDocBodies(
        context.sent!,
        documentBodies(message['attachments']?.toString()),
      );
    }
    return context.isEmpty ? null : context.encode();
  }

  static void clearForTesting() => _bySentAt.clear();
}

// ─── Document bodies in the sent text ───────────────────────────────────

/// Start and end of a document-body marker in a stored sent text. Private
/// use code points: they never come from a keyboard or a converted file.
const String kDocBodyMarkerStart = '\u{E000}doc:';
const String kDocBodyMarkerEnd = '\u{E001}';

/// The markdown bodies of a message's document attachments, in order.
List<String> documentBodies(String? attachmentsJson) {
  if (attachmentsJson == null || attachmentsJson.trim().isEmpty) {
    return const <String>[];
  }
  try {
    final decoded = jsonDecode(attachmentsJson);
    if (decoded is! List) return const <String>[];
    return [
      for (final entry in decoded)
        if (entry is Map &&
            entry['markdownContent'] is String &&
            (entry['markdownContent'] as String).isNotEmpty)
          entry['markdownContent'] as String,
    ];
  } catch (_) {
    return const <String>[];
  }
}

/// [sent] with each of [bodies] (first occurrence) replaced by a marker.
/// Unchanged when the text already holds a marker character.
String compactDocBodies(String sent, List<String> bodies) {
  if (sent.contains('\u{E000}') || sent.contains('\u{E001}')) return sent;
  var out = sent;
  for (var i = 0; i < bodies.length; i++) {
    final at = out.indexOf(bodies[i]);
    if (at < 0) continue;
    out = out.replaceRange(
      at,
      at + bodies[i].length,
      '$kDocBodyMarkerStart$i$kDocBodyMarkerEnd',
    );
  }
  return out;
}

/// The inverse of [compactDocBodies].
String expandDocBodies(String sent, List<String> bodies) {
  if (!sent.contains(kDocBodyMarkerStart)) return sent;
  return sent.replaceAllMapped(
    RegExp('\u{E000}doc:(\\d+)\u{E001}', unicode: true),
    (m) {
      final i = int.parse(m.group(1)!);
      return i < bodies.length ? bodies[i] : m.group(0)!;
    },
  );
}

// ─── Tool results ────────────────────────────────────────────────────────

/// Code points of a tool result's head that the model sees.
const int kToolResultHeadCodePoints = 4096;

/// Code points of a tool result's tail that the model sees.
const int kToolResultTailCodePoints = 1024;

/// Put between head and tail of a cut tool result.
const String kToolResultPrunedMarker =
    '\n\n[... tool result middle pruned ...]\n\n';

/// Caps a tool result for the model: head + marker + tail, counted in code
/// points (runes), so a cut never splits a surrogate pair. Applied ONCE, when
/// the result first goes into the history; the capped text is what is stored
/// and re-sent on every later pass, so a result never changes after it was
/// sent. Idempotent: a capped result is short enough to come back unchanged.
/// The api_server must use the same numbers (`chat/tool_history.py`).
String capToolResultForModel(
  String content, {
  int head = kToolResultHeadCodePoints,
  int tail = kToolResultTailCodePoints,
}) {
  final runes = content.runes;
  final length = runes.length;
  final markerRunes = kToolResultPrunedMarker.runes.length;
  if (length <= head + tail + markerRunes) return content;
  final list = runes.toList(growable: false);
  return String.fromCharCodes(list.sublist(0, head)) +
      kToolResultPrunedMarker +
      String.fromCharCodes(list.sublist(length - tail));
}

// ─── Request metadata ────────────────────────────────────────────────────

/// First 16 hex digits of the SHA-256 of [chatId]. Never the id itself, and
/// never anything about the user.
String chatIdHash(String chatId) =>
    sha256.convert(utf8.encode(chatId)).toString().substring(0, 16);

/// The `x_chuk` object of a chat request. The server reads it for its own
/// bookkeeping (cache affinity, logs) and strips it before the upstream call.
Map<String, dynamic> xChukMetadata({
  required String purpose,
  String? chatId,
  int? pass,
}) => <String, dynamic>{
  'purpose': purpose,
  if (chatId != null && chatId.isNotEmpty) 'chat_hash': chatIdHash(chatId),
  'pass': ?pass,
};
