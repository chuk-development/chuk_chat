import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// A coworker's own model: the model, the provider it runs on, and how hard
/// it thinks.
///
/// In the Agents build a coworker has one permanent thread, and its thread key
/// is the chat id this is stored under, so "this chat's model" and "this
/// coworker's model" are the same record. A chat with no record follows the
/// app default (the composer's Fast / Thinking / Custom mode).
@immutable
class ChatModelSelection {
  const ChatModelSelection({
    required this.modelId,
    required this.providerSlug,
    this.reasoningEffort,
  });
  final String modelId;
  final String providerSlug;

  /// The reasoning level the coworker runs at (`none`, `low`, `high`, …).
  /// Null on a record written before the level was part of it: the send then
  /// keeps the composer's level, as it always did.
  final String? reasoningEffort;

  ChatModelSelection copyWith({
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
  }) => ChatModelSelection(
    modelId: modelId ?? this.modelId,
    providerSlug: providerSlug ?? this.providerSlug,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
  );

  Map<String, String> toJson() => {
    'modelId': modelId,
    'providerSlug': providerSlug,
    if (reasoningEffort != null && reasoningEffort!.isNotEmpty)
      'reasoningEffort': reasoningEffort!,
  };

  static ChatModelSelection? fromJson(Object? value) {
    if (value is! Map) return null;
    final model = value['modelId'];
    final provider = value['providerSlug'];
    if (model is! String ||
        model.isEmpty ||
        provider is! String ||
        provider.isEmpty) {
      return null;
    }
    final effort = value['reasoningEffort'];
    return ChatModelSelection(
      modelId: model,
      providerSlug: provider,
      reasoningEffort: effort is String && effort.isNotEmpty ? effort : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatModelSelection &&
      other.modelId == modelId &&
      other.providerSlug == providerSlug &&
      other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(modelId, providerSlug, reasoningEffort);
}

/// A model AND provider belong to one account/chat, never just to a model ID.
/// Legacy chats have no override and continue using the existing defaults.
///
/// The record lives on this device (SharedPreferences, per account): the host
/// stores no coworker model, every task names the model it runs on.
class ChatModelSelectionService extends ChangeNotifier {
  ChatModelSelectionService();
  static final instance = ChatModelSelectionService();
  final Map<String, ChatModelSelection?> _cache = {};
  final Map<String, Future<void>> _writes = {};

  /// Forgets the memory and the write chains. A chain left from an earlier
  /// widget test belongs to that test's zone, which nothing drains any more:
  /// a write queued behind it would never run.
  @visibleForTesting
  void clearMemoryForTesting() {
    _cache.clear();
    _writes.clear();
  }

  String _account(String? userId) {
    if (userId != null) return userId;
    try {
      return SupabaseService.client.auth.currentUser?.id ?? 'local';
    } catch (_) {
      return 'local';
    }
  }

  String _key(String chatId, String? userId) =>
      'cowork.chat_model.v1.${Uri.encodeComponent(_account(userId))}.${Uri.encodeComponent(chatId)}';

  ChatModelSelection? peek(String chatId, {String? userId}) =>
      _cache[_key(chatId, userId)];

  Future<ChatModelSelection?> load(String chatId, {String? userId}) {
    final key = _key(chatId, userId);
    if (_cache.containsKey(key)) return Future.value(_cache[key]);
    return _loadKey(key);
  }

  Future<ChatModelSelection?> _loadKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    // A picker can save while disk loading is suspended; the new choice wins.
    if (_cache.containsKey(key)) return _cache[key];
    ChatModelSelection? selection;
    try {
      final raw = prefs.getString(key);
      if (raw != null) selection = ChatModelSelection.fromJson(jsonDecode(raw));
    } on FormatException {
      // A corrupt optional preference does not prevent sending a chat.
    }
    _cache[key] = selection;
    notifyListeners();
    return selection;
  }

  Future<void> save(
    String chatId,
    ChatModelSelection selection, {
    String? userId,
  }) async {
    if (chatId.isEmpty ||
        selection.modelId.isEmpty ||
        selection.providerSlug.isEmpty ||
        selection.providerSlug == '__auto_cheapest__') {
      throw ArgumentError('Chat, model and provider must be non-empty');
    }
    final key = _key(chatId, userId);
    final pending = _writes[key] ?? Future<void>.value();
    final operation = pending.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString(key, jsonEncode(selection.toJson()));
      if (!saved) throw StateError('Could not save this chat model');
      _cache[key] = selection;
      notifyListeners();
    });
    _writes[key] = operation;
    await operation;
  }

  /// Drops the chat's own model, so it follows the app default again.
  Future<void> clear(String chatId, {String? userId}) async {
    if (chatId.isEmpty) return;
    final key = _key(chatId, userId);
    final pending = _writes[key] ?? Future<void>.value();
    final operation = pending.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
      _cache[key] = null;
      notifyListeners();
    });
    _writes[key] = operation;
    await operation;
  }

  /// Capture this choice BEFORE awaiting transport setup or switching chats.
  Future<ChatModelSelection> resolveForSend(
    String chatId, {
    required String modelId,
    required String providerSlug,
    String? userId,
  }) {
    final fallback = ChatModelSelection(
      modelId: modelId,
      providerSlug: providerSlug,
    );
    return load(chatId, userId: userId).then((choice) => choice ?? fallback);
  }
}
