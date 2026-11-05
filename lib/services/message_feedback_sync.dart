// lib/services/message_feedback_sync.dart
//
// Thumbs feedback to the api_server (api_server CLAUDE.md, "Message
// feedback"): `POST /v1/feedback` sets the verdict on one answer,
// `DELETE /v1/feedback/{message_id}` takes it back.
//
// The request is never on the UI path: a verdict is stored on the device
// first, then queued here. A send that fails on the network, on a 5xx or on a
// 429 stays queued and is tried again later (a short backoff, the next
// verdict, the next load of the store). A refusal the server will repeat (a
// bad field, 4xx) drops the job. The queue is small, per user, and only ever
// holds the newest job per message.
//
// Never sent: the message text. The chat is named only by `chat_hash`, the
// first 16 hex digits of sha256(chat id), the same value as `x_chuk`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// A send the server did not take. [status] 0 is a network failure.
class FeedbackSendException implements Exception {
  const FeedbackSendException(this.status, [this.detail = '']);

  final int status;
  final String detail;

  /// Not signed in: nothing went out, the job waits for a session.
  static const int notSignedIn = -1;

  /// Worth another try later: the network, a timeout, a rate limit, the
  /// server, or no session yet.
  bool get retryable =>
      status == 0 ||
      status == notSignedIn ||
      status == 401 ||
      status == 408 ||
      status == 429 ||
      status >= 500;

  @override
  String toString() => 'FeedbackSendException($status, $detail)';
}

/// The live Supabase access token, or null when nobody is signed in.
Future<String?> _supabaseToken() async {
  if (!SupabaseService.isInitialized) return null;
  try {
    return SupabaseService.auth.currentSession?.accessToken;
  } catch (_) {
    return null;
  }
}

/// The two feedback routes. Injectable: a test passes a `MockClient`.
class MessageFeedbackApi {
  MessageFeedbackApi({
    this._client,
    this._baseUrl,
    Future<String?> Function()? token,
    this.timeout = const Duration(seconds: 15),
  }) : _token = token ?? _supabaseToken;

  static final MessageFeedbackApi instance = MessageFeedbackApi();

  final http.Client? _client;
  final String? _baseUrl;
  final Future<String?> Function() _token;
  final Duration timeout;

  Uri _uri(String path) =>
      Uri.parse('${_baseUrl ?? ApiConfigService.apiBaseUrl}/v1/feedback$path');

  /// `POST /v1/feedback` with [body] (see [feedbackRequestBody]).
  Future<void> post(Map<String, dynamic> body) =>
      _send('POST', _uri(''), body: body);

  /// `DELETE /v1/feedback/{message_id}`. Always 200 on the server, also
  /// when there was no row.
  Future<void> delete(String messageId) =>
      _send('DELETE', _uri('/${Uri.encodeComponent(messageId)}'));

  Future<void> _send(String method, Uri uri, {Object? body}) async {
    final String? token = await _token();
    if (token == null || token.isEmpty) {
      throw const FeedbackSendException(FeedbackSendException.notSignedIn);
    }
    final http.Request request = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final bool owned = _client == null;
    final http.Client client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      ).timeout(timeout);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('feedback: $method failed (${error.runtimeType})');
      }
      throw const FeedbackSendException(0, 'network');
    } finally {
      if (owned) client.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (kDebugMode) debugPrint('feedback: $method -> ${response.statusCode}');
      throw FeedbackSendException(response.statusCode, _detail(response));
    }
  }

  static String _detail(http.Response response) {
    try {
      final Object? data = jsonDecode(response.body);
      if (data is Map && data['detail'] is String) {
        return data['detail'] as String;
      }
    } catch (_) {}
    return 'http_${response.statusCode}';
  }
}

/// The server's body for one verdict, or null when it cannot be sent (no
/// chat hash: the server requires it).
///
/// [rating] is `positive` / `negative`; [categories] are the app's hyphen
/// ids, which the server accepts. The note is trimmed and cut to 1000
/// characters, the model and provider to 200.
Map<String, dynamic>? feedbackRequestBody({
  required String messageId,
  required String? chatHash,
  required bool positive,
  required List<String> categories,
  String? note,
  String? modelId,
  String? provider,
}) {
  final String id = messageId.trim();
  if (id.isEmpty || id.length > 128) return null;
  final String hash = (chatHash ?? '').trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(hash)) return null;
  String? cut(String? value, int max) {
    final String text = (value ?? '').trim();
    if (text.isEmpty) return null;
    return text.length > max ? text.substring(0, max) : text;
  }

  return <String, dynamic>{
    'message_id': id,
    'chat_hash': hash,
    'rating': positive ? 'positive' : 'negative',
    if (categories.isNotEmpty) 'categories': categories,
    'note': ?cut(note, 1000),
    'model_id': ?cut(modelId, 200),
    'provider': ?cut(provider, 200),
  };
}

/// One queued job: set a verdict ([body] not null) or remove it.
@immutable
class FeedbackJob {
  const FeedbackJob.set(this.messageId, Map<String, dynamic> this.body);
  const FeedbackJob.remove(this.messageId) : body = null;

  final String messageId;
  final Map<String, dynamic>? body;

  bool get isRemove => body == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message_id': messageId,
    'body': ?body,
  };

  static FeedbackJob? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['message_id'];
    if (id is! String || id.isEmpty) return null;
    final Object? body = raw['body'];
    if (body is Map) {
      return FeedbackJob.set(
        id,
        body.map((Object? k, Object? v) => MapEntry('$k', v)),
      );
    }
    return FeedbackJob.remove(id);
  }
}

/// The per-user queue of feedback jobs waiting for the server.
class MessageFeedbackSync {
  MessageFeedbackSync({
    Future<void> Function(Map<String, dynamic> body)? post,
    Future<void> Function(String messageId)? delete,
    this.backoff = const <Duration>[
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
      Duration(minutes: 10),
    ],
  }) : _post = post ?? MessageFeedbackApi.instance.post,
       _delete = delete ?? MessageFeedbackApi.instance.delete;

  final Future<void> Function(Map<String, dynamic> body) _post;
  final Future<void> Function(String messageId) _delete;

  /// The waits between two failed flushes, the last one repeating.
  final List<Duration> backoff;

  /// At most this many jobs are kept; the oldest go first.
  static const int maxJobs = 50;

  static const String prefsKey = 'message_feedback_outbox_v1';
  static String prefsKeyFor(String? userId) => '$prefsKey:${userId ?? 'anon'}';

  String? _owner;
  bool _ownerKnown = false;
  final List<FeedbackJob> _jobs = <FeedbackJob>[];
  Future<void>? _loading;
  Future<void>? _flushing;
  bool _again = false;
  Timer? _retry;
  int _failures = 0;

  /// The jobs still waiting, oldest first. Tests read it.
  List<FeedbackJob> get pending => List<FeedbackJob>.unmodifiable(_jobs);

  /// True while a retry is scheduled.
  bool get retryScheduled => _retry?.isActive ?? false;

  /// Switches to [userId]'s queue and tries to send what it holds.
  Future<void> attach(String? userId) async {
    if (_ownerKnown && userId == _owner) {
      await (_loading ?? Future<void>.value());
      unawaited(flush());
      return;
    }
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    _owner = userId;
    _ownerKnown = true;
    _jobs.clear();
    final Future<void> load = _load(userId);
    _loading = load;
    await load;
    unawaited(flush());
  }

  Future<void> _load(String? userId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(prefsKeyFor(userId));
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      if (userId != _owner) return;
      for (final Object? row in decoded) {
        final FeedbackJob? job = FeedbackJob.fromJson(row);
        if (job != null) _put(job);
      }
    } catch (error) {
      if (kDebugMode) debugPrint('feedback queue load failed: $error');
    }
  }

  /// Queues [job] (replacing any older job for the same message) and sends
  /// in the background. Never throws, never waits for the network.
  Future<void> enqueue(FeedbackJob job) async {
    await (_loading ?? Future<void>.value());
    _put(job);
    await _persist();
    unawaited(flush());
  }

  void _put(FeedbackJob job) {
    _jobs.removeWhere((FeedbackJob j) => j.messageId == job.messageId);
    _jobs.add(job);
    while (_jobs.length > maxJobs) {
      _jobs.removeAt(0);
    }
  }

  /// Sends the queue, oldest first. One flush at a time; a call during a
  /// flush runs it once more afterwards.
  Future<void> flush() {
    final Future<void>? running = _flushing;
    if (running != null) {
      _again = true;
      return running;
    }
    final Future<void> run = _flushOnce().whenComplete(() {
      _flushing = null;
      if (_again) {
        _again = false;
        unawaited(flush());
      }
    });
    _flushing = run;
    return run;
  }

  Future<void> _flushOnce() async {
    final String? owner = _owner;
    while (_jobs.isNotEmpty) {
      if (owner != _owner) return;
      final FeedbackJob job = _jobs.first;
      try {
        final Map<String, dynamic>? body = job.body;
        if (body == null) {
          await _delete(job.messageId);
        } else {
          await _post(body);
        }
      } on FeedbackSendException catch (error) {
        if (owner != _owner) return;
        if (!error.retryable) {
          // The server will refuse it again: drop it, keep the rest going.
          _jobs.remove(job);
          await _persist();
          continue;
        }
        // No session yet: wait for the next trigger, no timer.
        if (error.status != FeedbackSendException.notSignedIn) {
          _scheduleRetry();
        }
        return;
      } catch (error) {
        if (kDebugMode) debugPrint('feedback send failed: $error');
        _scheduleRetry();
        return;
      }
      if (owner != _owner) return;
      _jobs.remove(job);
      _failures = 0;
      await _persist();
    }
  }

  void _scheduleRetry() {
    if (_retry?.isActive ?? false) return;
    final Duration wait =
        backoff[_failures < backoff.length ? _failures : backoff.length - 1];
    _failures++;
    _retry = Timer(wait, () {
      _retry = null;
      unawaited(flush());
    });
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String key = prefsKeyFor(_owner);
      if (_jobs.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(
          key,
          jsonEncode(<Map<String, dynamic>>[
            for (final FeedbackJob job in _jobs) job.toJson(),
          ]),
        );
      }
    } catch (error) {
      if (kDebugMode) debugPrint('feedback queue save failed: $error');
    }
  }

  /// Sign-out: [userId]'s queue leaves memory and the device.
  Future<void> clearForSignOut(String? userId) async {
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    if (userId == _owner) _jobs.clear();
    _ownerKnown = false;
    _owner = null;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKeyFor(userId));
    } catch (_) {}
  }

  /// Tests only: forget the in-memory state and stop the retry timer.
  @visibleForTesting
  void resetForTest() {
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    _jobs.clear();
    _owner = null;
    _ownerKnown = false;
    _loading = null;
    _flushing = null;
    _again = false;
  }
}
