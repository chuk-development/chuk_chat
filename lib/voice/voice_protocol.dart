// lib/voice/voice_protocol.dart
//
// The wire contract between this app and the voice worker (agents/voice/,
// agent_name `chuk-voice`): the token request, the dispatch metadata, and the
// RPC payloads. Pure functions, no LiveKit, so every payload is unit-tested.
//
// Keep the names in step with the worker. They are its API.

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/voice/voice_call_models.dart';

abstract final class VoiceProtocol {
  /// The worker's LiveKit agent name (explicit dispatch).
  static const String agentName = 'chuk-voice';

  static const String roomPrefix = 'chuk-voice-';
  static const String identityPrefix = 'chuk-';

  /// Worker -> app: start a task through the delegate.
  static const String delegateMethod = 'chuk.delegate';

  /// App -> worker: a delegated task finished.
  static const String taskResultMethod = 'chuk.task_result';

  /// Worker -> app device tools (names from the prototype's
  /// `agent_ui_bridge.dart`).
  static const String openLinkMethod = 'open_link';
  static const String getLocationMethod = 'get_location';
  static const String getDeviceStatusMethod = 'get_device_status';

  static const List<String> appMethods = <String>[
    delegateMethod,
    openLinkMethod,
    getLocationMethod,
    getDeviceStatusMethod,
  ];

  /// The worker waits 10 s for the delegate answer; answer a little before
  /// that so a slow `startTask` still gets an error back instead of a
  /// caller-side timeout.
  static const Duration delegateAnswerTimeout = Duration(seconds: 9);

  /// The failed result (and delegate error) when the chat that owned the
  /// delegate is gone.
  static const String chatClosed = 'the chat was closed';

  static const int maxContextChars = 4000;
  static const int maxResultChars = 6000;

  /// LiveKit caps an RPC payload at 15 KiB. A result that fits in
  /// [maxResultChars] can still exceed it in UTF-8 (emoji, CJK), so the
  /// payload is also held under this byte budget.
  static const int maxRpcPayloadBytes = 15000;

  /// The metadata JSON the worker reads from its job (`ctx.job.metadata`).
  ///
  /// `initiated_by` / `call_id` / `call_reason` are for the call the agent
  /// starts (spec §6.3): the incoming-call layer passes them through
  /// `VoiceCallController.start`. A call the user starts sends
  /// `initiated_by: "user"` and nulls.
  static Map<String, dynamic> dispatchMetadata({
    required String userId,
    required VoiceCallMode mode,
    String? chatTitle,
    String? agentName,
    String context = '',
    String? sttLanguage,
    required bool delegateAvailable,
    bool initiatedByAgent = false,
    String? callId,
    String? callReason,
  }) => <String, dynamic>{
    'user_id': userId,
    'mode': mode.name,
    'chat_title': chatTitle,
    'agent_name': agentName,
    'context': truncateRunes(context.trim(), maxContextChars),
    'stt_language': sttLanguage,
    'delegate_available': delegateAvailable,
    'voice_id': null,
    'llm_model': null,
    'initiated_by': initiatedByAgent ? 'agent' : 'user',
    'call_id': callId,
    'call_reason': callReason,
  };

  /// The STT language for the worker: the one the caller asked for, else the
  /// device language (`de`, `en`, ...), else null (the worker detects it).
  static String? resolveSttLanguage(String? requested, String? deviceLanguage) {
    final String? asked = requested?.trim();
    if (asked != null && asked.isNotEmpty) return asked;
    final String? device = deviceLanguage?.trim().toLowerCase();
    if (device == null || device.isEmpty || device == 'und') return null;
    return device;
  }

  /// The POST body for the token server (see new-voicemode's
  /// `token_server.py`; LiveKit's `EndpointTokenSource` shape).
  static Map<String, dynamic> tokenRequest({
    required String roomName,
    required String participantIdentity,
    required String participantName,
    required Map<String, dynamic> metadata,
  }) => <String, dynamic>{
    'room_name': roomName,
    'participant_identity': participantIdentity,
    'participant_name': participantName,
    'room_config': <String, dynamic>{
      'agents': <Map<String, dynamic>>[
        <String, dynamic>{
          'agent_name': agentName,
          'metadata': jsonEncode(metadata),
        },
      ],
    },
  };

  /// Reads `{server_url, participant_token}` from the token server's answer.
  /// Throws [FormatException] when either is missing.
  static VoiceCredentials parseTokenResponse(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('token response is not an object');
    }
    String? pick(String snake, String camel) {
      final Object? value = decoded[snake] ?? decoded[camel];
      return value is String && value.isNotEmpty ? value : null;
    }

    final String? serverUrl = pick('server_url', 'serverUrl');
    final String? token = pick('participant_token', 'participantToken');
    if (serverUrl == null || token == null) {
      throw const FormatException('token response lacks url or token');
    }
    return VoiceCredentials(serverUrl: serverUrl, participantToken: token);
  }

  /// Answers a `chuk.delegate` call: `{"task": str}` ->
  /// `{"task_id": id, "status": "started"}` or `{"error": msg}`.
  ///
  /// Never throws; every failure is an `error` answer the worker can speak.
  ///
  /// [onStarted] gets the id of every task that started, before the answer
  /// goes out, so the caller can track it until its result is sent. When it
  /// returns false (the chat closed while the task was starting) the worker
  /// gets `{"error": "the chat was closed"}` instead of a task id it would
  /// wait on forever.
  static Future<String> handleDelegate(
    String payload,
    VoiceTaskDelegate? delegate, {
    Duration timeout = delegateAnswerTimeout,
    bool Function(String taskId)? onStarted,
  }) async {
    if (delegate == null) return _error('no delegate');
    final Map<String, dynamic> args = decodeObject(payload);
    final Object? rawTask = args['task'];
    final String task = rawTask is String ? rawTask.trim() : '';
    if (task.isEmpty) return _error('missing task');
    try {
      final String taskId = await delegate.startTask(task).timeout(timeout);
      if (onStarted != null && !onStarted(taskId)) {
        return _error(chatClosed);
      }
      return jsonEncode(<String, dynamic>{
        'task_id': taskId,
        'status': 'started',
      });
    } on TimeoutException {
      return _error('delegate timed out');
    } catch (e) {
      return _error(truncateRunes(e.toString(), 300));
    }
  }

  /// The `chuk.task_result` payload: `{"task_id", "status", "result"}`, the
  /// result cut to [maxResultChars] runes and the whole payload held under
  /// [maxRpcPayloadBytes].
  static String taskResultPayload(VoiceTaskResult result) {
    String text = truncateRunes(result.result, maxResultChars);
    while (true) {
      final String payload = jsonEncode(<String, dynamic>{
        'task_id': result.taskId,
        'status': result.status == VoiceTaskResult.statusDone
            ? VoiceTaskResult.statusDone
            : VoiceTaskResult.statusFailed,
        'result': text,
      });
      final int bytes = utf8.encode(payload).length;
      if (bytes <= maxRpcPayloadBytes || text.isEmpty) return payload;
      final int runes = text.runes.length;
      // Shrink by the overshoot ratio plus a margin; converges in a few steps.
      final int keep = (runes * maxRpcPayloadBytes / bytes * 0.95).floor();
      text = truncateRunes(text, keep < runes ? keep : runes - 1);
    }
  }

  /// `open_link` wants `{"url": str}`. Only web links are opened: the agent
  /// is model-driven, and a scheme like `intent:` or `tel:` would act on the
  /// phone. Returns null for anything else.
  static Uri? openLinkTarget(String payload) {
    final Object? raw = decodeObject(payload)['url'];
    if (raw is! String || raw.trim().isEmpty) return null;
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return uri;
  }

  static String openLinkAnswer({required bool ok, String? error}) =>
      jsonEncode(<String, dynamic>{'ok': ok, 'error': ?error});

  /// The answer for device tools this app does not offer in a call.
  static String notAvailable() => _error('not available');

  /// Worker -> app data topics (new-voicemode `server/ui_bridge.py`).
  static const String cardTopic = 'ui.card';
  static const String toolTopic = 'ui.tool';

  /// Parses a `ui.card` packet. Null for anything malformed or from a
  /// protocol version this build does not read.
  static VoiceCard? parseCard(List<int> bytes, {DateTime? at}) {
    final Map<String, dynamic>? json = _decodeVersioned(bytes);
    if (json == null) return null;
    final Object? id = json['id'];
    final Object? kind = json['kind'];
    if (id is! String || id.isEmpty || kind is! String || kind.isEmpty) {
      return null;
    }
    return VoiceCard.fromJson(<String, dynamic>{
      ...json,
      'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
    });
  }

  /// Parses a `ui.tool` packet (`{v, call_id, name?, status?}`).
  static VoiceToolActivity? parseToolActivity(List<int> bytes, {DateTime? at}) {
    final Map<String, dynamic>? json = _decodeVersioned(bytes);
    if (json == null) return null;
    final Object? callId = json['call_id'];
    if (callId is! String || callId.isEmpty) return null;
    final Object? name = json['name'];
    final Object? status = json['status'];
    return VoiceToolActivity(
      callId: callId,
      name: name is String ? name : '',
      status: status is String && status.isNotEmpty ? status : 'running',
      at: at ?? DateTime.now(),
    );
  }

  static Map<String, dynamic>? _decodeVersioned(List<int> bytes) {
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final Object? v = decoded['v'];
      if (v is! num || v.toInt() != VoiceCard.supportedVersion) return null;
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Decodes a JSON object payload; anything else is an empty map.
  static Map<String, dynamic> decodeObject(String payload) {
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return const <String, dynamic>{};
  }

  static String _error(String message) =>
      jsonEncode(<String, dynamic>{'error': message});
}

/// Where and how to join: the LiveKit server URL and the room token.
class VoiceCredentials {
  const VoiceCredentials({
    required this.serverUrl,
    required this.participantToken,
  });

  final String serverUrl;
  final String participantToken;
}

/// Cuts [text] to at most [maxRunes] Unicode code points, never splitting a
/// surrogate pair.
String truncateRunes(String text, int maxRunes) {
  if (maxRunes <= 0) return '';
  // Fast path: fewer UTF-16 units than the limit means fewer runes too.
  if (text.length <= maxRunes) return text;
  final Iterator<int> it = text.runes.iterator;
  final StringBuffer out = StringBuffer();
  int count = 0;
  while (count < maxRunes && it.moveNext()) {
    out.writeCharCode(it.current);
    count++;
  }
  return out.toString();
}
