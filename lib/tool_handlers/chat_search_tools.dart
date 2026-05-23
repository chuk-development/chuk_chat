// lib/tool_handlers/chat_search_tools.dart
//
// Two-step chat search tool:
// 1) find_chats: broad search and return candidate chat IDs.
// 2) search_in_chat: focused search inside one selected chat.

import 'dart:convert';
import 'dart:math' as math;

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

const int _defaultChatLimit = 10;
const int _maxChatLimit = 50;
const int _defaultMessageLimit = 8;
const int _maxMessageLimit = 50;
const int _snippetRadius = 180;
const int _minLocalScanChats = 60;
const int _maxLocalScanChats = 250;
const int _localScanMultiplier = 6;
// Step 1 inlines a few snippets per candidate so the AI can answer
// without a follow-up search_in_chat call for simple lookups.
const int _previewSnippetsTop = 5;
const int _previewSnippetsRest = 1;
const int _topCandidatesWithPreview = 3;
// recent_messages action defaults.
const int _defaultRecentLimit = 10;
const int _maxRecentLimit = 50;
const int _recentSnippetChars = 500;

const String _actionFindChats = 'find_chats';
const String _actionSearchInChat = 'search_in_chat';
const String _actionRecentMessages = 'recent_messages';
const Set<String> _validRoles = {'user', 'assistant', 'ai', 'all'};

Future<String> executeSearchChats(Map<String, dynamic> args) async {
  try {
    final chatId = (args['chat_id'] as String? ?? '').trim();
    final action = _resolveAction(args['action'], chatId: chatId);
    if (action == null) {
      return 'Error: Invalid action. Use "find_chats", "search_in_chat", or '
          '"recent_messages"';
    }

    if (action == _actionRecentMessages) {
      final effectiveChatId = chatId.isNotEmpty
          ? chatId
          : (ChatStorageState.selectedChatId ?? '');
      if (effectiveChatId.isEmpty) {
        return 'Error: "chat_id" is required for recent_messages (no active '
            'chat selected)';
      }

      final limit = _coerceInt(
        args['limit'],
        fallback: _defaultRecentLimit,
      ).clamp(1, _maxRecentLimit).toInt();
      final role = _normalizeRole(args['role']);
      if (role == null) {
        return 'Error: "role" must be one of: user, assistant, ai, all';
      }

      return _recentMessages(chatId: effectiveChatId, limit: limit, role: role);
    }

    final query = (args['query'] as String? ?? '').trim();
    if (query.isEmpty) {
      return 'Error: "query" parameter is required for $action';
    }

    if (action == _actionSearchInChat) {
      if (chatId.isEmpty) {
        return 'Error: "chat_id" is required when action is "search_in_chat"';
      }

      final messageLimit = _coerceInt(
        args['message_limit'],
        fallback: _defaultMessageLimit,
      ).clamp(1, _maxMessageLimit).toInt();

      return _searchInChat(
        query: query,
        chatId: chatId,
        messageLimit: messageLimit,
      );
    }

    final chatLimit = _coerceInt(
      args['limit'],
      fallback: _defaultChatLimit,
    ).clamp(1, _maxChatLimit).toInt();

    return _findChats(query: query, limit: chatLimit);
  } catch (error) {
    return 'Error: search_chats failed: $error';
  }
}

String? _resolveAction(dynamic rawAction, {required String chatId}) {
  final action = (rawAction as String? ?? '').trim().toLowerCase();
  if (action.isEmpty) {
    return chatId.isNotEmpty ? _actionSearchInChat : _actionFindChats;
  }

  if (action == _actionFindChats ||
      action == _actionSearchInChat ||
      action == _actionRecentMessages) {
    return action;
  }

  return null;
}

String? _normalizeRole(dynamic raw) {
  final value = (raw as String? ?? '').trim().toLowerCase();
  if (value.isEmpty) {
    return 'all';
  }
  if (!_validRoles.contains(value)) {
    return null;
  }
  // Treat "ai" as an alias for "assistant".
  return value == 'ai' ? 'assistant' : value;
}

String? _currentUserId() {
  try {
    return SupabaseService.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

Future<String> _findChats({required String query, required int limit}) async {
  final queryLower = query.toLowerCase();
  final candidatesById = <String, _ChatCandidate>{};
  var totalSearched = ChatStorageState.chatsById.length;
  final currentChatId = ChatStorageState.selectedChatId;

  final userId = _currentUserId();
  if (userId != null) {
    final cachedCount = await LocalChatCacheService.count(userId);
    totalSearched = math.max(totalSearched, cachedCount);

    final localScanLimit = (limit * _localScanMultiplier)
        .clamp(_minLocalScanChats, _maxLocalScanChats)
        .toInt();
    final rows = await LocalChatCacheService.search(
      userId,
      query,
      limit: localScanLimit,
    );
    for (final row in rows) {
      final candidate = _candidateFromCacheRow(row, queryLower);
      if (candidate != null && candidate.chatId != currentChatId) {
        _upsertCandidate(candidatesById, candidate);
      }
    }
  }

  // Include in-memory chats (covers unsynced/new chats).
  for (final chat in ChatStorageState.chatsById.values) {
    if (chat.id == currentChatId) {
      continue;
    }
    final candidate = _candidateFromStoredChat(chat, queryLower);
    if (candidate != null) {
      _upsertCandidate(candidatesById, candidate);
    }
  }

  if (candidatesById.isEmpty) {
    final excludedNote = currentChatId != null
        ? ' (current chat excluded)'
        : '';
    return 'No chats found for "$query"$excludedNote.';
  }

  final candidates = candidatesById.values.toList()..sort(_compareCandidates);
  final selected = candidates.take(limit).toList(growable: false);
  return _formatChatCandidates(
    query: query,
    totalSearched: totalSearched,
    candidates: selected,
  );
}

_ChatCandidate? _candidateFromStoredChat(StoredChat chat, String queryLower) {
  final messages = chat.messagesOrNull;
  final title = _chatTitle(chat, messages);
  final titleMatch = title.toLowerCase().contains(queryLower);
  final idMatch = chat.id.toLowerCase().contains(queryLower);

  var matchCount = 0;
  var previewSnippets = const <String>[];
  if (messages != null && messages.isNotEmpty) {
    final summary = _summarizeMatches(messages, queryLower);
    matchCount = summary.matchCount;
    previewSnippets = summary.snippets;
  }

  if (!idMatch && !titleMatch && matchCount == 0) {
    return null;
  }

  if (previewSnippets.isEmpty) {
    if (titleMatch) {
      previewSnippets = <String>[title];
    } else if (idMatch) {
      previewSnippets = <String>['chat_id: ${chat.id}'];
    }
  }

  return _ChatCandidate(
    chatId: chat.id,
    title: title,
    idMatch: idMatch,
    titleMatch: titleMatch,
    matchCount: matchCount,
    previewSnippets: previewSnippets,
    messageCount: messages?.length ?? 0,
    updatedAt: chat.updatedAt ?? chat.createdAt,
  );
}

_ChatCandidate? _candidateFromCacheRow(
  Map<String, dynamic> row,
  String queryLower,
) {
  final chatId = (row['id'] as String? ?? '').trim();
  if (chatId.isEmpty) {
    return null;
  }

  final parsed = _parsePayload(row['payload'] as String?);
  final messages = parsed?.messages;
  final title = _rowTitle(row, messages, customName: parsed?.customName);
  final titleMatch = title.toLowerCase().contains(queryLower);
  final idMatch = chatId.toLowerCase().contains(queryLower);

  var matchCount = 0;
  var previewSnippets = const <String>[];
  if (messages != null && messages.isNotEmpty) {
    final summary = _summarizeMatches(messages, queryLower);
    matchCount = summary.matchCount;
    previewSnippets = summary.snippets;
  }

  if (!idMatch && !titleMatch && matchCount == 0) {
    return null;
  }

  if (previewSnippets.isEmpty) {
    if (titleMatch) {
      previewSnippets = <String>[title];
    } else if (idMatch) {
      previewSnippets = <String>['chat_id: $chatId'];
    }
  }

  return _ChatCandidate(
    chatId: chatId,
    title: title,
    idMatch: idMatch,
    titleMatch: titleMatch,
    matchCount: matchCount,
    previewSnippets: previewSnippets,
    messageCount: messages?.length ?? 0,
    updatedAt: _rowTimestamp(row),
  );
}

Future<String> _searchInChat({
  required String query,
  required String chatId,
  required int messageLimit,
}) async {
  final loaded = await _loadChatContent(chatId);
  if (loaded == null) {
    return 'Error: Chat "$chatId" not found or could not be loaded';
  }

  final messages = loaded.messages;
  if (messages.isEmpty) {
    return 'No messages found in chat "$chatId".';
  }

  final queryLower = query.toLowerCase();
  final shownMatches = <_MessageMatch>[];
  var totalMatches = 0;

  for (int i = 0; i < messages.length; i++) {
    final match = _buildMessageMatch(
      message: messages[i],
      queryLower: queryLower,
      index: i,
    );
    if (match == null) {
      continue;
    }

    totalMatches++;
    if (shownMatches.length < messageLimit) {
      shownMatches.add(match);
    }
  }

  if (totalMatches == 0) {
    return 'No matches for "$query" in chat "${loaded.title}" '
        '(chat_id: $chatId).';
  }

  return _formatChatDetails(
    query: query,
    chatId: chatId,
    title: loaded.title,
    messageCount: messages.length,
    totalMatches: totalMatches,
    shownMatches: shownMatches,
  );
}

Future<String> _recentMessages({
  required String chatId,
  required int limit,
  required String role,
}) async {
  final loaded = await _loadChatContent(chatId);
  if (loaded == null) {
    return 'Error: Chat "$chatId" not found or could not be loaded';
  }

  final messages = loaded.messages;
  if (messages.isEmpty) {
    return 'No messages found in chat "$chatId".';
  }

  final filtered = <_RecentMessageEntry>[];
  for (int i = messages.length - 1; i >= 0; i--) {
    final msg = messages[i];
    if (role != 'all' && msg.role != role) {
      continue;
    }
    final text = _renderMessageText(msg);
    if (text.isEmpty) {
      continue;
    }
    filtered.add(_RecentMessageEntry(index: i, role: msg.role, text: text));
    if (filtered.length >= limit) {
      break;
    }
  }

  if (filtered.isEmpty) {
    final roleLabel = role == 'all' ? 'any role' : '"$role"';
    return 'No recent messages with role $roleLabel in chat "${loaded.title}" '
        '(chat_id: $chatId).';
  }

  final buffer = StringBuffer();
  buffer.writeln(
    'Recent messages from "${loaded.title}" (chat_id: $chatId, '
    'total messages: ${messages.length}, role filter: $role, '
    'returned: ${filtered.length}).',
  );
  buffer.writeln('Listed newest first.');
  buffer.writeln();

  for (final entry in filtered) {
    final truncated = entry.text.length > _recentSnippetChars
        ? '${entry.text.substring(0, _recentSnippetChars)}...'
        : entry.text;
    buffer.writeln('- #${entry.index + 1} [${entry.role}]: $truncated');
  }

  return buffer.toString().trimRight();
}

String _renderMessageText(ChatMessage message) {
  final parts = <String>[];
  if (message.text.trim().isNotEmpty) {
    parts.add(message.text.trim());
  }
  if (parts.isEmpty && (message.reasoning ?? '').trim().isNotEmpty) {
    parts.add('[reasoning] ${message.reasoning!.trim()}');
  }
  if (parts.isEmpty && (message.toolCalls ?? '').trim().isNotEmpty) {
    parts.add('[toolCalls] ${message.toolCalls!.trim()}');
  }
  return parts.join('\n').replaceAll(RegExp(r'\s+'), ' ').trim();
}

// Local-only chat read for the AI search tool.
//
// Searching other chats must never hit Supabase: it can't write to them
// (no persistence path here) and it must not pull from them either. Local
// cache holds all synced chats in plaintext, so in-memory + SQLite cache
// are the only sources.
Future<_LoadedChatContent?> _loadChatContent(String chatId) async {
  final inMemory = ChatStorageState.chatsById[chatId];
  if (inMemory != null && inMemory.isFullyLoaded) {
    final messages = inMemory.messagesOrNull ?? const <ChatMessage>[];
    return _LoadedChatContent(
      title: _chatTitle(inMemory, messages),
      messages: messages,
    );
  }

  final userId = _currentUserId();
  if (userId != null) {
    final cached = await LocalChatCacheService.loadById(userId, chatId);
    if (cached != null) {
      final parsed = _parsePayload(cached['payload'] as String?);
      if (parsed != null) {
        final title = _rowTitle(
          cached,
          parsed.messages,
          customName: parsed.customName,
        );
        return _LoadedChatContent(title: title, messages: parsed.messages);
      }
    }
  }

  return null;
}

_ParsedPayload? _parsePayload(String? payload) {
  if (payload == null || payload.isEmpty) {
    return null;
  }

  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      return null;
    }

    final map = _coerceStringMap(decoded);
    final customName = (map['customName'] as String?)?.trim();
    final rawMessages = map['messages'];
    if (rawMessages is! List) {
      return const _ParsedPayload(messages: <ChatMessage>[]);
    }

    final messages = <ChatMessage>[];
    for (final rawMessage in rawMessages) {
      if (rawMessage is! Map) {
        continue;
      }
      messages.add(ChatMessage.fromJson(_coerceStringMap(rawMessage)));
    }

    return _ParsedPayload(messages: messages, customName: customName);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _coerceStringMap(Map raw) {
  final map = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = entry.key?.toString();
    if (key == null || key.isEmpty) {
      continue;
    }
    map[key] = entry.value;
  }
  return map;
}

DateTime _rowTimestamp(Map<String, dynamic> row) {
  final updated = _parseDate(row['updated_at']);
  if (updated != null) {
    return updated;
  }
  final created = _parseDate(row['created_at']);
  if (created != null) {
    return created;
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

DateTime? _parseDate(dynamic value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  try {
    return DateTime.parse(value);
  } catch (_) {
    return null;
  }
}

_MessageMatchSummary _summarizeMatches(
  List<ChatMessage> messages,
  String queryLower,
) {
  var matchCount = 0;
  final snippets = <String>[];

  for (int i = 0; i < messages.length; i++) {
    final match = _buildMessageMatch(
      message: messages[i],
      queryLower: queryLower,
      index: i,
    );
    if (match == null) {
      continue;
    }

    matchCount++;
    if (snippets.length < _previewSnippetsTop) {
      snippets.add(match.snippet);
    }
  }

  return _MessageMatchSummary(matchCount: matchCount, snippets: snippets);
}

_MessageMatch? _buildMessageMatch({
  required ChatMessage message,
  required String queryLower,
  required int index,
}) {
  for (final field in _messageFields(message)) {
    if (!field.text.toLowerCase().contains(queryLower)) {
      continue;
    }

    var snippet = _extractSnippet(field.text, queryLower);
    if (field.label != 'text') {
      snippet = '[${field.label}] $snippet';
    }

    final prefixed = '#${index + 1} [${message.role}]: $snippet';
    return _MessageMatch(index: index, role: message.role, snippet: prefixed);
  }

  return null;
}

List<_SearchField> _messageFields(ChatMessage message) {
  final fields = <_SearchField>[];

  void add(String label, String? value) {
    if (value == null || value.trim().isEmpty) {
      return;
    }
    fields.add(_SearchField(label: label, text: value));
  }

  add('text', message.text);
  add('reasoning', message.reasoning);
  add('replyContext', message.replyContext);
  add('images', message.images);
  add('attachments', message.attachments);
  add('attachedFilesJson', message.attachedFilesJson);
  add('toolCalls', message.toolCalls);
  add('contentBlocks', message.contentBlocks);
  add('modelId', message.modelId);
  add('provider', message.provider);

  return fields;
}

String _rowTitle(
  Map<String, dynamic> row,
  List<ChatMessage>? messages, {
  String? customName,
}) {
  final explicitCustom = (customName ?? '').trim();
  if (explicitCustom.isNotEmpty) {
    return explicitCustom;
  }

  final explicitTitle = (row['title'] as String? ?? '').trim();
  if (explicitTitle.isNotEmpty) {
    return explicitTitle;
  }

  return _titleFromMessages(messages);
}

String _chatTitle(StoredChat chat, [List<ChatMessage>? messages]) {
  final explicit = (chat.customName ?? chat.title ?? '').trim();
  if (explicit.isNotEmpty) {
    return explicit;
  }

  return _titleFromMessages(messages);
}

String _titleFromMessages(List<ChatMessage>? messages) {
  if (messages == null || messages.isEmpty) {
    return '(untitled chat)';
  }

  for (final message in messages) {
    if (message.role == 'user' && message.text.trim().isNotEmpty) {
      final text = message.text.trim();
      return text.length > 80 ? '${text.substring(0, 80)}...' : text;
    }
  }

  return '(untitled chat)';
}

String _extractSnippet(String text, String queryLower) {
  final textLower = text.toLowerCase();
  final index = textLower.indexOf(queryLower);
  if (index < 0) {
    return text.length > 200 ? '${text.substring(0, 200)}...' : text;
  }

  final start = (index - _snippetRadius).clamp(0, text.length).toInt();
  final end = (index + queryLower.length + _snippetRadius)
      .clamp(0, text.length)
      .toInt();

  final prefix = start > 0 ? '...' : '';
  final suffix = end < text.length ? '...' : '';
  return '$prefix${text.substring(start, end)}$suffix';
}

void _upsertCandidate(
  Map<String, _ChatCandidate> candidatesById,
  _ChatCandidate candidate,
) {
  final existing = candidatesById[candidate.chatId];
  if (existing == null || _compareCandidates(candidate, existing) < 0) {
    candidatesById[candidate.chatId] = candidate;
  }
}

int _compareCandidates(_ChatCandidate a, _ChatCandidate b) {
  final idCompare = (b.idMatch ? 1 : 0).compareTo(a.idMatch ? 1 : 0);
  if (idCompare != 0) {
    return idCompare;
  }

  final titleCompare = (b.titleMatch ? 1 : 0).compareTo(a.titleMatch ? 1 : 0);
  if (titleCompare != 0) {
    return titleCompare;
  }

  final countCompare = b.matchCount.compareTo(a.matchCount);
  if (countCompare != 0) {
    return countCompare;
  }

  return b.updatedAt.compareTo(a.updatedAt);
}

String _formatChatCandidates({
  required String query,
  required int totalSearched,
  required List<_ChatCandidate> candidates,
}) {
  final buffer = StringBuffer();
  buffer.writeln(
    'Step 1 complete for "$query": matched ${candidates.length} chat(s) '
    'out of $totalSearched searched.',
  );
  buffer.writeln();
  buffer.writeln(
    'Top snippets are inlined below. Call search_chats with '
    'action="search_in_chat" and a chat_id only if you need more context.',
  );
  buffer.writeln();

  for (int i = 0; i < candidates.length; i++) {
    final item = candidates[i];
    buffer.writeln(
      '${i + 1}) chat_id=${item.chatId} | title="${item.title}" | '
      'id_match=${item.idMatch ? "yes" : "no"} | '
      'title_match=${item.titleMatch ? "yes" : "no"} | '
      'message_matches=${item.matchCount} | '
      'messages=${item.messageCount} | '
      'updated=${item.updatedAt.toIso8601String().substring(0, 10)}',
    );

    final maxSnippets = i < _topCandidatesWithPreview
        ? _previewSnippetsTop
        : _previewSnippetsRest;
    final snippets = item.previewSnippets.take(maxSnippets).toList();
    for (final snippet in snippets) {
      buffer.writeln('   preview: $snippet');
    }
  }

  return buffer.toString().trimRight();
}

String _formatChatDetails({
  required String query,
  required String chatId,
  required String title,
  required int messageCount,
  required int totalMatches,
  required List<_MessageMatch> shownMatches,
}) {
  final buffer = StringBuffer();
  buffer.writeln('Step 2 detailed search for "$query" in "$title".');
  buffer.writeln('chat_id=$chatId | messages=$messageCount');
  buffer.writeln(
    'Found $totalMatches matching message(s); showing ${shownMatches.length}.',
  );
  buffer.writeln();

  for (final match in shownMatches) {
    buffer.writeln('- ${match.snippet}');
  }

  return buffer.toString().trimRight();
}

int _coerceInt(dynamic value, {required int fallback}) {
  if (value == null) {
    return fallback;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  final parsed = int.tryParse(value.toString().trim());
  return parsed ?? fallback;
}

class _LoadedChatContent {
  const _LoadedChatContent({required this.title, required this.messages});

  final String title;
  final List<ChatMessage> messages;
}

class _ParsedPayload {
  const _ParsedPayload({required this.messages, this.customName});

  final List<ChatMessage> messages;
  final String? customName;
}

class _SearchField {
  const _SearchField({required this.label, required this.text});

  final String label;
  final String text;
}

class _MessageMatchSummary {
  const _MessageMatchSummary({required this.matchCount, required this.snippets});

  final int matchCount;
  final List<String> snippets;
}

class _ChatCandidate {
  const _ChatCandidate({
    required this.chatId,
    required this.title,
    required this.idMatch,
    required this.titleMatch,
    required this.matchCount,
    required this.previewSnippets,
    required this.messageCount,
    required this.updatedAt,
  });

  final String chatId;
  final String title;
  final bool idMatch;
  final bool titleMatch;
  final int matchCount;
  final List<String> previewSnippets;
  final int messageCount;
  final DateTime updatedAt;
}

class _MessageMatch {
  const _MessageMatch({
    required this.index,
    required this.role,
    required this.snippet,
  });

  final int index;
  final String role;
  final String snippet;
}

class _RecentMessageEntry {
  const _RecentMessageEntry({
    required this.index,
    required this.role,
    required this.text,
  });

  final int index;
  final String role;
  final String text;
}
