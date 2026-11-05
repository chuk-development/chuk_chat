// lib/services/message_feedback_store.dart
//
// Thumbs up / down on an answer, with optional reasons and a note, kept on
// this device and keyed by the answer's message id.
//
// The api_server has no feedback route yet (bead "feedback endpoint"), so
// nothing leaves the device: [MessageFeedbackStore.sendToBackend] stays null
// until that route exists. The shape below is the body it would POST.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/supabase_service.dart';

/// The reasons a reader can pick, in the order the sheet shows them.
/// The ids are the wire values.
enum FeedbackCategory {
  taskResult('task-result'),
  instructionFollowing('instruction-following'),
  productInteraction('product-interaction'),
  serviceStability('service-stability'),
  resourceCost('resource-cost'),
  securityPrivacy('security-privacy-permission'),
  other('other');

  const FeedbackCategory(this.id);

  final String id;

  static FeedbackCategory? fromId(String id) {
    for (final FeedbackCategory c in values) {
      if (c.id == id) return c;
    }
    return null;
  }
}

enum FeedbackRating { up, down }

/// One reader's verdict on one answer.
@immutable
class MessageFeedback {
  const MessageFeedback({
    required this.messageId,
    required this.rating,
    this.categories = const <FeedbackCategory>[],
    this.note,
    this.modelId,
    required this.createdAt,
  });

  final String messageId;
  final FeedbackRating rating;
  final List<FeedbackCategory> categories;
  final String? note;
  final String? modelId;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message_id': messageId,
    'rating': rating.name,
    'categories': <String>[for (final c in categories) c.id],
    if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
    if (modelId != null && modelId!.isNotEmpty) 'model_id': modelId,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  static MessageFeedback? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['message_id'];
    final Object? rating = raw['rating'];
    if (id is! String || id.isEmpty) return null;
    final FeedbackRating? r = switch (rating) {
      'up' => FeedbackRating.up,
      'down' => FeedbackRating.down,
      _ => null,
    };
    if (r == null) return null;
    final Object? cats = raw['categories'];
    return MessageFeedback(
      messageId: id,
      rating: r,
      categories: <FeedbackCategory>[
        if (cats is List)
          for (final Object? c in cats)
            if (c is String && FeedbackCategory.fromId(c) != null)
              FeedbackCategory.fromId(c)!,
      ],
      note: raw['note'] as String?,
      modelId: raw['model_id'] as String?,
      createdAt:
          DateTime.tryParse(raw['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Local store of [MessageFeedback], newest [maxEntries] kept.
class MessageFeedbackStore extends ChangeNotifier {
  MessageFeedbackStore._();

  static final MessageFeedbackStore instance = MessageFeedbackStore._();

  /// The legacy key (no owner). Its rows go to the first signed-in user
  /// that loads them; every user's own rows live under [prefsKeyFor].
  static const String prefsKey = 'message_feedback_v1';

  /// The preference key of [userId]'s verdicts.
  static String prefsKeyFor(String? userId) => '$prefsKey:${userId ?? 'anon'}';

  /// The signed-in user. Tests set their own.
  static String? Function() userIdReader = _currentUserId;

  static String? _currentUserId() => SupabaseService.isInitialized
      ? SupabaseService.auth.currentUser?.id
      : null;

  /// Oldest entries are dropped above this. A few hundred short JSON rows
  /// stay well inside the SharedPreferences budget (CLAUDE.md, ~200 KB).
  static const int maxEntries = 500;

  /// Posts one verdict to the server. Null: there is no route yet, so the
  /// verdict stays on this device only.
  static Future<void> Function(MessageFeedback feedback)? sendToBackend;

  /// Insertion order = age; the last entry is the newest.
  final Map<String, MessageFeedback> _entries = <String, MessageFeedback>{};
  Future<void>? _loading;
  bool _loaded = false;

  /// The user whose verdicts [_entries] holds.
  String? _owner;

  bool get isLoaded => _loaded;

  /// Read the signed-in user's stored entries once. Safe to call many
  /// times; another user signing in reads theirs.
  Future<void> ensureLoaded() {
    final String? user = userIdReader();
    if (_loading != null && user != _owner) {
      _entries.clear();
      _loading = null;
      _loaded = false;
    }
    _owner = user;
    return _loading ??= _load(user);
  }

  /// Sign-out: the verdicts leave memory and this device's storage.
  Future<void> clearForSignOut(String? userId) async {
    _entries.clear();
    _loading = null;
    _loaded = false;
    _owner = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKeyFor(userId));
      await prefs.remove(prefsKey);
    } catch (error) {
      if (kDebugMode) debugPrint('MessageFeedbackStore clear failed: $error');
    }
  }

  Future<void> _load(String? user) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? raw = prefs.getString(prefsKeyFor(user));
      final String? legacy = prefs.getString(prefsKey);
      if (legacy != null && user != null) {
        // Rows from before the per-user key: the first signed-in user
        // claims them, once.
        raw ??= legacy;
        await prefs.setString(prefsKeyFor(user), raw);
        await prefs.remove(prefsKey);
      }
      if (raw != null && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final Object? row in decoded) {
            final MessageFeedback? fb = MessageFeedback.fromJson(row);
            if (fb != null) _entries[fb.messageId] = fb;
          }
        }
      }
    } catch (error) {
      if (kDebugMode) debugPrint('MessageFeedbackStore load failed: $error');
    }
    _loaded = true;
    notifyListeners();
  }

  /// The stored verdict on [messageId], when loaded and present.
  MessageFeedback? peek(String? messageId) =>
      messageId == null ? null : _entries[messageId];

  Future<void> save(MessageFeedback feedback) async {
    await ensureLoaded();
    _entries.remove(feedback.messageId);
    _entries[feedback.messageId] = feedback;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    notifyListeners();
    await _persist();
    final Future<void> Function(MessageFeedback)? send = sendToBackend;
    if (send != null) {
      try {
        await send(feedback);
      } catch (error) {
        if (kDebugMode) debugPrint('Feedback send failed: $error');
      }
    }
  }

  Future<void> remove(String messageId) async {
    await ensureLoaded();
    if (_entries.remove(messageId) == null) return;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKeyFor(_owner),
      jsonEncode(<Map<String, dynamic>>[
        for (final MessageFeedback fb in _entries.values) fb.toJson(),
      ]),
    );
  }

  /// Tests only: forget the in-memory state so the next call reads prefs.
  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _loading = null;
    _loaded = false;
    _owner = null;
  }
}
