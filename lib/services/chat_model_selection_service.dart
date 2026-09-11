import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cowork/services/supabase_service.dart';

@immutable
class ChatModelSelection {
  const ChatModelSelection({required this.modelId, required this.providerSlug});
  final String modelId;
  final String providerSlug;

  Map<String, String> toJson() => {
    'modelId': modelId,
    'providerSlug': providerSlug,
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
    return ChatModelSelection(modelId: model, providerSlug: provider);
  }
}

/// A model AND provider belong to one account/chat, never just to a model ID.
/// Legacy chats have no override and continue using the existing defaults.
class ChatModelSelectionService extends ChangeNotifier {
  ChatModelSelectionService();
  static final instance = ChatModelSelectionService();
  final Map<String, ChatModelSelection?> _cache = {};
  final Map<String, Future<void>> _writes = {};

  @visibleForTesting
  void clearMemoryForTesting() => _cache.clear();

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
