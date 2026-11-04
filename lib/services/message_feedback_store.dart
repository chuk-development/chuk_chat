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

  static const String prefsKey = 'message_feedback_v1';

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

  bool get isLoaded => _loaded;

  /// Read the stored entries once. Safe to call many times.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(prefsKey);
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
      prefsKey,
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
  }
}
