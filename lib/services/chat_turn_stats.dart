// lib/services/chat_turn_stats.dart
//
// The numbers of the last reply in each chat: its speed (tok/s) and its token
// usage. The streaming manager writes them as the frames arrive; the stats row
// under the composer reads them. Kept apart from the message maps so the row
// updates the moment the reply ends, without a rebuild of the chat screen.

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/turn_usage.dart';
import 'package:chuk_chat/services/model_cache_service.dart';

/// The last reply's numbers in one chat.
@immutable
class ChatTurnStatsEntry {
  const ChatTurnStatsEntry({this.tps, this.usage});

  /// Tokens per second of the last reply. Null when unknown.
  final double? tps;

  /// Token usage of the last reply. Null when the server sent none.
  final TurnUsage? usage;

  bool get isEmpty => tps == null && usage == null;

  ChatTurnStatsEntry copyWith({double? tps, TurnUsage? usage}) =>
      ChatTurnStatsEntry(tps: tps ?? this.tps, usage: usage ?? this.usage);
}

/// Per-chat last tok/s and last usage. One process-wide instance.
class ChatTurnStats extends ChangeNotifier {
  ChatTurnStats._();

  static final ChatTurnStats instance = ChatTurnStats._();

  /// Most chats kept. The oldest entry goes first.
  static const int _maxChats = 64;

  final Map<String, ChatTurnStatsEntry> _byChat =
      <String, ChatTurnStatsEntry>{};

  /// The last reply's numbers in [chatId], or null when none are known.
  ChatTurnStatsEntry? of(String? chatId) =>
      chatId == null ? null : _byChat[chatId];

  /// The last usage in [chatId], or null.
  TurnUsage? usageOf(String? chatId) => of(chatId)?.usage;

  /// Record the speed of the reply that is running in [chatId].
  void recordTps(String chatId, double tps) {
    if (!tps.isFinite || tps <= 0) return;
    _put(
      chatId,
      (_byChat[chatId] ?? const ChatTurnStatsEntry()).copyWith(tps: tps),
    );
  }

  /// Record a server `usage` object for [chatId]. The last value wins: a
  /// stream can send several, and the final one has the full counts.
  void recordUsage(String chatId, Map<String, dynamic> raw) {
    final TurnUsage? usage = TurnUsage.fromServer(raw);
    if (usage == null) return;
    _put(
      chatId,
      (_byChat[chatId] ?? const ChatTurnStatsEntry()).copyWith(usage: usage),
    );
  }

  /// Move the numbers of [fromChatId] to [toChatId] (a new chat gets its id
  /// after the first reply started).
  void rename(String fromChatId, String toChatId) {
    final ChatTurnStatsEntry? entry = _byChat.remove(fromChatId);
    if (entry == null || fromChatId == toChatId) return;
    _put(toChatId, entry);
  }

  void _put(String chatId, ChatTurnStatsEntry entry) {
    _byChat.remove(chatId);
    _byChat[chatId] = entry;
    while (_byChat.length > _maxChats) {
      _byChat.remove(_byChat.keys.first);
    }
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _byChat.clear();
    _contextLengths.clear();
    notifyListeners();
  }

  // ── Context length of a model ──────────────────────────────────────

  /// `modelId|providerSlug` → context length, read once from the catalogue.
  final Map<String, int?> _contextLengths = <String, int?>{};

  /// The cached context length, or null when it was not read yet.
  int? cachedContextLength(String modelId, String? providerSlug) =>
      _contextLengths['$modelId|${providerSlug ?? ''}'];

  /// The context length of [modelId] on [providerSlug] (else the largest
  /// any provider offers), from the stored model catalogue. Null when the
  /// catalogue does not list it.
  Future<int?> contextLengthFor(String modelId, String? providerSlug) async {
    if (modelId.isEmpty) return null;
    final String key = '$modelId|${providerSlug ?? ''}';
    if (_contextLengths.containsKey(key)) return _contextLengths[key];
    List<Map<String, dynamic>> models;
    try {
      models = await ModelCacheService.loadAvailableModels();
    } catch (_) {
      return null;
    }
    final int? length = contextLengthFromCatalogue(
      models,
      modelId,
      providerSlug,
    );
    _contextLengths[key] = length;
    if (length != null) notifyListeners();
    return length;
  }

  /// Pure lookup over a catalogue list (`/v1/models_info` entries).
  @visibleForTesting
  static int? contextLengthFromCatalogue(
    List<Map<String, dynamic>> models,
    String modelId,
    String? providerSlug,
  ) {
    for (final Map<String, dynamic> model in models) {
      if (model['id'] != modelId) continue;
      final Object? providers = model['providers'];
      int? best;
      if (providers is List) {
        for (final Object? p in providers) {
          if (p is! Map) continue;
          final int? length = _int(p['context_length']);
          if (length == null || length <= 0) continue;
          if (providerSlug != null && p['slug'] == providerSlug) return length;
          if (best == null || length > best) best = length;
        }
      }
      return best ?? _int(model['context_length']);
    }
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
