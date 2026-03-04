// lib/tool_handlers/chat_search_tools.dart
//
// Two-step chat search tool:
// 1) find_chats: broad search and return candidate chat IDs.
// 2) search_in_chat: focused search inside one selected chat.

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/encryption_service.dart';

const int _defaultChatLimit = 10;
const int _maxChatLimit = 50;
const int _defaultMessageLimit = 8;
const int _maxMessageLimit = 50;
const int _maxDeepScanChats = 12;
const int _snippetRadius = 120;

const String _actionFindChats = 'find_chats';
const String _actionSearchInChat = 'search_in_chat';

Future<String> executeSearchChats(Map<String, dynamic> args) async {
  try {
    final query = (args['query'] as String? ?? '').trim();
    if (query.isEmpty) {
      return 'Error: "query" parameter is required';
    }

    final chatId = (args['chat_id'] as String? ?? '').trim();
    final action = _resolveAction(args['action'], chatId: chatId);
    if (action == null) {
      return 'Error: Invalid action. Use "find_chats" or "search_in_chat"';
    }

    if (!await _ensureEncryptionKey()) {
      return 'Error: Encryption key not available. '
          'The user needs to sign in first.';
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

  if (action == _actionFindChats || action == _actionSearchInChat) {
    return action;
  }

  return null;
}

Future<bool> _ensureEncryptionKey() async {
  if (EncryptionService.hasKey) {
    return true;
  }

  return EncryptionService.tryLoadKey();
}

Future<String> _findChats({required String query, required int limit}) async {
  final chats = ChatStorageState.chatsById.values.toList();
  if (chats.isEmpty) {
    return 'No chats are available for searching yet.';
  }

  final queryLower = query.toLowerCase();
  final candidates = <_ChatCandidate>[];
  final includedChatIds = <String>{};

  for (final chat in chats) {
    final messages = chat.messagesOrNull;
    final title = _chatTitle(chat, messages);
    final titleMatch = title.toLowerCase().contains(queryLower);

    var matchCount = 0;
    String? firstSnippet;
    if (messages != null && messages.isNotEmpty) {
      for (final message in messages) {
        if (message.text.toLowerCase().contains(queryLower)) {
          matchCount++;
          firstSnippet ??= _extractSnippet(message.text, queryLower);
        }
      }
    }

    if (titleMatch && firstSnippet == null) {
      firstSnippet = title;
    }

    if (!titleMatch && matchCount == 0) {
      continue;
    }

    candidates.add(
      _ChatCandidate(
        chatId: chat.id,
        title: title,
        titleMatch: titleMatch,
        matchCount: matchCount,
        previewSnippet: firstSnippet ?? '',
        messageCount: messages?.length ?? 0,
        updatedAt: chat.updatedAt ?? chat.createdAt,
      ),
    );
    includedChatIds.add(chat.id);
  }

  if (candidates.length < limit) {
    final deepMatches = await _scanUnloadedChatsForQuery(
      chats: chats,
      queryLower: queryLower,
      remaining: limit - candidates.length,
      excludedChatIds: includedChatIds,
    );
    for (final candidate in deepMatches) {
      if (includedChatIds.contains(candidate.chatId)) {
        continue;
      }
      candidates.add(candidate);
      includedChatIds.add(candidate.chatId);
    }
  }

  if (candidates.isEmpty) {
    return 'No chats found for "$query".';
  }

  candidates.sort((a, b) {
    final titleCompare = (b.titleMatch ? 1 : 0).compareTo(a.titleMatch ? 1 : 0);
    if (titleCompare != 0) {
      return titleCompare;
    }

    final countCompare = b.matchCount.compareTo(a.matchCount);
    if (countCompare != 0) {
      return countCompare;
    }

    return b.updatedAt.compareTo(a.updatedAt);
  });

  final selected = candidates.take(limit).toList();
  return _formatChatCandidates(
    query: query,
    totalSearched: chats.length,
    candidates: selected,
  );
}

Future<List<_ChatCandidate>> _scanUnloadedChatsForQuery({
  required List<StoredChat> chats,
  required String queryLower,
  required int remaining,
  required Set<String> excludedChatIds,
}) async {
  if (remaining <= 0) {
    return const <_ChatCandidate>[];
  }

  final unloaded = chats.where((chat) => !chat.isFullyLoaded).toList()
    ..sort(
      (a, b) =>
          (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt),
    );

  final candidates = <_ChatCandidate>[];
  var scanned = 0;

  for (final chat in unloaded) {
    if (scanned >= _maxDeepScanChats || candidates.length >= remaining) {
      break;
    }
    if (excludedChatIds.contains(chat.id)) {
      continue;
    }
    scanned++;

    final loaded = await ChatStorageService.loadFullChat(chat.id);
    final messages = loaded?.messagesOrNull;
    if (loaded == null || messages == null || messages.isEmpty) {
      continue;
    }

    var matchCount = 0;
    String? firstSnippet;
    for (final message in messages) {
      if (message.text.toLowerCase().contains(queryLower)) {
        matchCount++;
        firstSnippet ??= _extractSnippet(message.text, queryLower);
      }
    }

    final title = _chatTitle(loaded, messages);
    final titleMatch = title.toLowerCase().contains(queryLower);
    if (!titleMatch && matchCount == 0) {
      continue;
    }
    if (titleMatch && firstSnippet == null) {
      firstSnippet = title;
    }

    candidates.add(
      _ChatCandidate(
        chatId: loaded.id,
        title: title,
        titleMatch: titleMatch,
        matchCount: matchCount,
        previewSnippet: firstSnippet ?? '',
        messageCount: messages.length,
        updatedAt: loaded.updatedAt ?? loaded.createdAt,
      ),
    );
  }

  return candidates;
}

Future<String> _searchInChat({
  required String query,
  required String chatId,
  required int messageLimit,
}) async {
  var chat = ChatStorageState.chatsById[chatId];
  if (chat == null || !chat.isFullyLoaded) {
    final loaded = await ChatStorageService.loadFullChat(chatId);
    if (loaded == null || !loaded.isFullyLoaded) {
      return 'Error: Chat "$chatId" not found or could not be loaded';
    }
    chat = loaded;
  }

  final messages = chat.messagesOrNull;
  if (messages == null || messages.isEmpty) {
    return 'No messages found in chat "$chatId".';
  }

  final queryLower = query.toLowerCase();
  final shownMatches = <_MessageMatch>[];
  var totalMatches = 0;

  for (int i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (!message.text.toLowerCase().contains(queryLower)) {
      continue;
    }

    totalMatches++;
    if (shownMatches.length < messageLimit) {
      shownMatches.add(
        _MessageMatch(
          index: i,
          role: message.role,
          snippet: _extractSnippet(message.text, queryLower),
        ),
      );
    }
  }

  final title = _chatTitle(chat, messages);
  if (totalMatches == 0) {
    return 'No matches for "$query" in chat "$title" (chat_id: $chatId).';
  }

  return _formatChatDetails(
    query: query,
    chatId: chatId,
    title: title,
    messageCount: messages.length,
    totalMatches: totalMatches,
    shownMatches: shownMatches,
  );
}

String _chatTitle(StoredChat chat, [List<ChatMessage>? messages]) {
  final explicit = (chat.customName ?? chat.title ?? '').trim();
  if (explicit.isNotEmpty) {
    return explicit;
  }

  if (messages == null) {
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
    'Pick one chat_id and call search_chats again with '
    'action="search_in_chat" and a more specific query.',
  );
  buffer.writeln();

  for (int i = 0; i < candidates.length; i++) {
    final item = candidates[i];
    buffer.writeln(
      '${i + 1}) chat_id=${item.chatId} | title="${item.title}" | '
      'title_match=${item.titleMatch ? "yes" : "no"} | '
      'message_matches=${item.matchCount} | '
      'messages=${item.messageCount} | '
      'updated=${item.updatedAt.toIso8601String().substring(0, 10)}',
    );
    if (item.previewSnippet.isNotEmpty) {
      buffer.writeln('   preview: ${item.previewSnippet}');
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
    buffer.writeln(
      '- Message #${match.index + 1} (${match.role}): ${match.snippet}',
    );
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

class _ChatCandidate {
  const _ChatCandidate({
    required this.chatId,
    required this.title,
    required this.titleMatch,
    required this.matchCount,
    required this.previewSnippet,
    required this.messageCount,
    required this.updatedAt,
  });

  final String chatId;
  final String title;
  final bool titleMatch;
  final int matchCount;
  final String previewSnippet;
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
