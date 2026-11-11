// lib/services/voice_outbox_preparer.dart
//
// The outbox step that turns a queued voice row into a text row: reads the
// saved recording ([VoiceSpoolService]), transcribes it over HTTP, writes the
// transcript into the bubble and into the row's payload. The send then runs
// as for any text row. Design: docs/OFFLINE_SEND.md.
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/voice_spool_service.dart';
import 'package:chuk_chat/utils/exponential_backoff.dart';

/// Turns raw WAV bytes into a transcript. Throws on failure.
typedef VoiceTranscriber = Future<String> Function(Uint8List wav);

abstract final class VoiceOutboxPreparer {
  static const String name = 'voice';

  /// Test seam: the access token of the current session, or null.
  @visibleForTesting
  static Future<String?> Function() accessToken = _defaultAccessToken;

  /// Test seam: the transcription call. The default uploads to
  /// `/v1/ai/transcribe-audio` and retries once with a fresh token on 401.
  @visibleForTesting
  static VoiceTranscriber transcribe = _defaultTranscribe;

  /// Test seam: writes the transcript into the chat bubble.
  @visibleForTesting
  static Future<bool> Function(String chatId, String queueId, String text)
  applyTranscript = OfflineSendCoordinator.applyTranscript;

  /// Registers the step with [OfflineRetryManager]. Call once at app start.
  static void register() {
    OfflineRetryManager.instance.registerPreparer(preparer);
  }

  static OutboxPreparer get preparer => OutboxPreparer(
    name: name,
    appliesTo: appliesTo,
    prepare: prepare,
    onDone: onDone,
  );

  static String? _voicePath(QueuedMessage row) {
    final Object? raw = row.sendPayload['voicePath'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  /// A voice row whose recording is not transcribed yet.
  static bool appliesTo(QueuedMessage row) {
    if (!row.isVoice) return false;
    final Object? text = row.sendPayload['messageText'];
    if (text is String && text.trim().isNotEmpty) return false;
    return _voicePath(row) != null;
  }

  static Future<PrepareResult> prepare(QueuedMessage row) async {
    final String? path = _voicePath(row);
    if (path == null) return const PrepareResult.failure('recording missing');

    final String? token = await accessToken();
    if (token == null || token.isEmpty) {
      return const PrepareResult.deferred('no session');
    }

    Uint8List wav;
    try {
      if (!await VoiceSpoolService.exists(path)) {
        return const PrepareResult.failure('recording missing');
      }
      wav = await VoiceSpoolService.read(path);
    } catch (_) {
      return const PrepareResult.failure('recording missing');
    }
    if (wav.isEmpty) return const PrepareResult.failure('recording missing');

    String text;
    try {
      text = (await transcribe(wav)).trim();
    } catch (error) {
      if (_isNetworkError(error)) {
        // "network" in the message makes the manager retry with backoff.
        return PrepareResult.failure('network: ${_short(error)}');
      }
      return PrepareResult.failure('transcription failed: ${_short(error)}');
    }
    if (text.isEmpty) return const PrepareResult.failure('empty transcription');

    if (kDebugMode) {
      debugPrint(
        '[VoicePreparer] transcribed row ${row.id} len=${text.length}',
      );
    }
    try {
      await applyTranscript(row.chatId, row.id, text);
    } catch (_) {
      // The payload still gets the text; the bubble catches up on reload.
      if (kDebugMode) debugPrint('[VoicePreparer] bubble update failed');
    }
    return PrepareResult.ok(
      payload: <String, dynamic>{...row.sendPayload, 'messageText': text},
      hold: row.sendPayload['autoSend'] == false,
    );
  }

  /// The row is gone (sent, deleted, wiped): delete its recording.
  static Future<void> onDone(QueuedMessage row) async {
    final String? path = _voicePath(row);
    if (path != null) await VoiceSpoolService.delete(path);
  }

  static bool _isNetworkError(Object error) {
    if (error is TranscriptionException) {
      final int? code = error.statusCode;
      if (code != null) return code == 408 || code == 429 || code >= 500;
    }
    return NetworkStatusService.isNetworkError(error) ||
        ExponentialBackoff.shouldRetryError(error);
  }

  /// Error text without the message content; capped for the row's
  /// `last_error` column.
  static String _short(Object error) {
    final String s = error is TranscriptionException
        ? (error.statusCode != null
              ? 'HTTP ${error.statusCode}: ${error.message}'
              : error.message)
        : '$error';
    return s.length > 160 ? s.substring(0, 160) : s;
  }

  static Future<String?> _defaultAccessToken() async {
    try {
      if (!SupabaseService.isInitialized) return null;
      final session = await SupabaseService.refreshSession();
      return session?.accessToken;
    } catch (_) {
      return null;
    }
  }

  static Future<String> _defaultTranscribe(Uint8List wav) async {
    final String? token = await accessToken();
    if (token == null || token.isEmpty) {
      throw const TranscriptionException('Network error: no session');
    }
    final api = ChatApiService();
    try {
      final result = await api.transcribeAudioBytes(
        bytes: wav,
        filename: 'recording.wav',
        accessToken: token,
      );
      return result.text;
    } on TranscriptionException catch (error) {
      if (error.statusCode != 401) rethrow;
      // A stale token, not a revoked account: renew it and retry once.
      final session = await SupabaseService.refreshSession(force: true);
      final String? fresh = session?.accessToken;
      if (fresh == null || fresh.isEmpty || fresh == token) rethrow;
      final result = await api.transcribeAudioBytes(
        bytes: wav,
        filename: 'recording.wav',
        accessToken: fresh,
      );
      return result.text;
    }
  }

  @visibleForTesting
  static void reset() {
    accessToken = _defaultAccessToken;
    transcribe = _defaultTranscribe;
    applyTranscript = OfflineSendCoordinator.applyTranscript;
  }
}
