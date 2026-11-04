// lib/platform_specific/chat/handlers/audio_recording_handler.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'package:chuk_chat/utils/permission_handler_stub.dart'
    if (dart.library.io) 'package:permission_handler/permission_handler.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/dictation_tracker.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/streaming_transcription_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/voice_spool_service.dart';
import 'package:chuk_chat/utils/exponential_backoff.dart';

enum AudioRecordingChange { started, stopped, failed, busy }

/// Handles microphone recording + transcription.
///
/// Recording starts **instantly** on mic press: the recorder is opened as a
/// raw PCM-16 stream and every chunk is appended to an in-memory buffer from
/// byte zero. In parallel a WebSocket connection to the transcription service
/// is attempted; when it becomes ready the buffered audio is flushed to the
/// socket and subsequent chunks are forwarded live. If the WebSocket never
/// becomes ready (offline, auth fails, timeout) the buffered PCM is wrapped
/// as a WAV file at stop time and uploaded via HTTP. Either way the full
/// audio from the moment of mic press is sent — nothing is discarded.
class AudioRecordingHandler {
  static const int _sampleRate = 16000;
  static const int _channels = 1;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final List<double> _audioLevels = List<double>.filled(
    32,
    0.0,
    growable: true,
  );

  // Shared state.
  bool _isMicActive = false;
  bool _isTranscribingAudio = false;
  bool _isChangingRecordingState = false;

  /// Called whenever audio levels update, so the UI can rebuild.
  VoidCallback? onLevelsChanged;

  // PCM capture.
  StreamSubscription<Uint8List>? _pcmStreamSub;
  final BytesBuilder _pcmBuffer = BytesBuilder(copy: false);

  /// Runs from mic press to stop: the length of the dictation, which the
  /// sent message shows on its voice bubble. No audio is kept for it.
  final Stopwatch _recordingClock = Stopwatch();

  // Streaming (WebSocket) state.
  StreamingTranscriptionService? _streamingService;
  bool _isStreamingMode = false;

  bool get isMicActive => _isMicActive;
  bool get isTranscribingAudio => _isTranscribingAudio;
  List<double> get audioLevels => _audioLevels;

  /// Whether a WebSocket streaming session is active.
  bool get isStreamingMode => _isStreamingMode;

  /// Start microphone recording.
  ///
  /// Recording begins **instantly** — PCM chunks are captured from the
  /// moment this method returns. If [accessToken] is provided a WebSocket
  /// connection is opened in the background; once ready the buffered audio
  /// is flushed and live chunks are forwarded. The caller does not wait for
  /// the WebSocket — recording never blocks on network.
  Future<bool> _startRecording({String? accessToken}) async {
    try {
      if (!await _ensureMicPermission()) return false;

      if (!await _audioRecorder.hasPermission()) {
        if (kDebugMode) debugPrint('Microphone permission required');
        return false;
      }

      if (await _audioRecorder.isRecording()) return true;

      _resetAudioLevels();
      _pcmBuffer.clear();
      _pcmStreamSub?.cancel();

      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: _channels,
      );
      final Stream<Uint8List> pcmStream = await _audioRecorder.startStream(
        config,
      );

      _pcmStreamSub = pcmStream.listen(_handlePcmChunk);
      _isMicActive = true;
      _recordingClock
        ..reset()
        ..start();
      _isStreamingMode = false;

      if (accessToken != null) {
        unawaited(_tryConnectStreaming(accessToken));
      }
      return true;
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to start microphone: $error\n$stackTrace');
      }
      await _pcmStreamSub?.cancel();
      _pcmStreamSub = null;
      _pcmBuffer.clear();
      return false;
    }
  }

  /// Toggles recording while keeping recorder state transitions identical on
  /// desktop and mobile.
  Future<AudioRecordingChange> toggleRecording({
    required String? accessToken,
    required VoidCallback handleLevelsChanged,
  }) async {
    if (_isChangingRecordingState) return AudioRecordingChange.busy;
    _isChangingRecordingState = true;
    try {
      if (_isMicActive) {
        await stopRecording();
        _resetAudioLevels();
        return AudioRecordingChange.stopped;
      }

      onLevelsChanged = null;
      final started = await _startRecording(accessToken: accessToken);
      if (!started) return AudioRecordingChange.failed;

      _resetAudioLevels();
      onLevelsChanged = handleLevelsChanged;
      return AudioRecordingChange.started;
    } finally {
      _isChangingRecordingState = false;
    }
  }

  /// Stop microphone recording.
  ///
  /// If [keepFile] is `true`, the captured audio is retained so the next
  /// [stopAndTranscribe] call can use it. Otherwise everything is
  /// discarded.
  Future<void> stopRecording({bool keepFile = false}) async {
    onLevelsChanged = null;
    await _pcmStreamSub?.cancel();
    _pcmStreamSub = null;

    try {
      await _audioRecorder.stop();
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to stop microphone: $error\n$stackTrace');
      }
    }

    _isMicActive = false;
    _recordingClock.stop();

    if (!keepFile) {
      _pcmBuffer.clear();
      if (_streamingService != null) {
        await _streamingService!.abort();
      }
      _streamingService = null;
      _isStreamingMode = false;
    }
  }

  /// Stops the active recording, resolves authentication, and transcribes it.
  ///
  /// Desktop and mobile supply their own session lookup but share the state
  /// transitions here. A null result means no recording was eligible.
  ///
  /// The whole recording is written to [VoiceSpoolService] BEFORE any
  /// transcription attempt, so a bad connection never loses it. When the
  /// transcription cannot run for a network reason (offline, no token, the
  /// socket dropped and the upload failed) the result is
  /// [TranscriptionResult.queueable] with the [TranscriptionResult.savedPath]
  /// kept on disk: the caller queues it in the outbox. On success, and on a
  /// hard failure (4xx, empty transcript), the file is deleted again.
  Future<TranscriptionResult?> stopAndTranscribe({
    required ChatApiService apiService,
    required Future<String?> Function() getAccessToken,
    VoidCallback? onStateChanged,
  }) async {
    if (_isChangingRecordingState || !_isMicActive || _isTranscribingAudio) {
      return null;
    }
    _isChangingRecordingState = true;
    try {
      await stopRecording(keepFile: true);
      _resetAudioLevels();
      onStateChanged?.call();

      final int durationMs = _recordingClock.elapsedMilliseconds;
      final StreamingTranscriptionService? streamingService = _streamingService;
      final bool wasStreaming = _isStreamingMode && streamingService != null;
      _streamingService = null;
      _isStreamingMode = false;

      // The full recording, also in streaming mode (_handlePcmChunk keeps a
      // copy of every chunk). Cleared only after it is on disk.
      final Uint8List pcm = _pcmBuffer.toBytes();
      if (pcm.isEmpty) {
        _pcmBuffer.clear();
        await streamingService?.abort();
        onStateChanged?.call();
        return TranscriptionResult(success: false, error: 'No audio');
      }

      _isTranscribingAudio = true;
      onStateChanged?.call();

      final Uint8List wav = _pcmToWav(
        pcm,
        sampleRate: _sampleRate,
        channels: _channels,
      );
      final String? savedPath = await _spool(wav);
      _pcmBuffer.clear();

      TranscriptionResult? result;
      try {
        final accessToken = await getAccessToken();
        // Known offline with the recording on disk: queue it at once instead
        // of waiting for an upload that cannot work (up to 60 s).
        final bool skipNetwork =
            savedPath != null && !NetworkStatusService.isOnline;
        if (accessToken == null || accessToken.isEmpty || skipNetwork) {
          await streamingService?.abort();
          result = await finishWav(
            wav: wav,
            savedPath: savedPath,
            durationMs: durationMs,
            accessToken: null,
            upload: (bytes, token) => _upload(apiService, bytes, token),
          );
        } else {
          if (wasStreaming && streamingService.isHealthy) {
            result = await _transcribeStreaming(
              streamingService,
              savedPath: savedPath,
              durationMs: durationMs,
            );
          } else {
            await streamingService?.abort();
          }
          // No socket, the socket dropped, or it failed for a network
          // reason: upload the saved recording over HTTP instead.
          result ??= await finishWav(
            wav: wav,
            savedPath: savedPath,
            durationMs: durationMs,
            accessToken: accessToken,
            upload: (bytes, token) => _upload(apiService, bytes, token),
            refreshToken: () => _freshToken(accessToken),
          );
        }
      } finally {
        _isTranscribingAudio = false;
      }

      final String? text = result.text;
      if (result.success && text != null && text.isNotEmpty) {
        // The composer gets this text next; the send marks it as dictated.
        DictationTracker.instance.record(
          text,
          duration: Duration(milliseconds: durationMs),
        );
      }
      onStateChanged?.call();
      return result;
    } finally {
      _isChangingRecordingState = false;
    }
  }

  /// Saves [wav] to the voice spool. Null on web or when the write fails;
  /// the recording then lives only in memory, as before.
  Future<String?> _spool(Uint8List wav) async {
    if (!VoiceSpoolService.isSupported) return null;
    try {
      return await VoiceSpoolService.saveWav(
        wav,
        userId: OutboxCipher.currentUserId(),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('Voice spool write failed: $error');
      return null;
    }
  }

  static Future<String> _upload(
    ChatApiService apiService,
    Uint8List wav,
    String accessToken,
  ) async {
    final transcription = await apiService.transcribeAudioBytes(
      bytes: wav,
      filename: 'recording.wav',
      accessToken: accessToken,
    );
    return transcription.text;
  }

  /// A fresh access token after a 401, or null when there is none.
  ///
  /// The access token aged out while the app sat open. That is a stale
  /// token, not a revoked account: refresh it and retry once. Signing the
  /// user out here throws away a perfectly good session over a routine
  /// token rotation.
  static Future<String?> _freshToken(String staleToken) async {
    try {
      final session = await SupabaseService.refreshSession();
      final String? fresh = session?.accessToken;
      if (fresh == null || fresh.isEmpty || fresh == staleToken) return null;
      return fresh;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Transcription token refresh failed: $error');
      }
      return null;
    }
  }

  /// Whether [error] means "the network or the service is not reachable
  /// right now" (retry later) rather than "this request is wrong".
  @visibleForTesting
  static bool isQueueableError(Object error) {
    if (error is TranscriptionException) {
      final int? code = error.statusCode;
      if (code != null) {
        return code == 408 || code == 429 || code >= 500;
      }
    }
    if (error is TimeoutException || error is SocketException) return true;
    return NetworkStatusService.isNetworkError(error) ||
        ExponentialBackoff.shouldRetryError(error);
  }

  /// The HTTP path for a recording already built as [wav] and (when
  /// [savedPath] is set) already on disk. Decides whether the file is kept
  /// (queueable) or deleted. [accessToken] null means no session right now.
  ///
  /// Static and free of the recorder so tests can drive it.
  @visibleForTesting
  static Future<TranscriptionResult> finishWav({
    required Uint8List wav,
    required String? savedPath,
    required int durationMs,
    required String? accessToken,
    required Future<String> Function(Uint8List wav, String token) upload,
    Future<String?> Function()? refreshToken,
  }) async {
    TranscriptionResult queued(String reason) {
      if (savedPath == null) {
        return TranscriptionResult(
          success: false,
          error: reason,
          durationMs: durationMs,
        );
      }
      return TranscriptionResult(
        success: false,
        error: reason,
        savedPath: savedPath,
        durationMs: durationMs,
        queueable: true,
      );
    }

    Future<TranscriptionResult> hardFailure(String message) async {
      if (savedPath != null) await VoiceSpoolService.delete(savedPath);
      return TranscriptionResult(
        success: false,
        error: message,
        durationMs: durationMs,
      );
    }

    Future<TranscriptionResult> fromText(String raw) async {
      final String text = raw.trim();
      if (text.isEmpty) return hardFailure('No text found');
      if (savedPath != null) await VoiceSpoolService.delete(savedPath);
      return TranscriptionResult(
        success: true,
        text: text,
        durationMs: durationMs,
      );
    }

    if (accessToken == null || accessToken.isEmpty) {
      return savedPath == null
          ? TranscriptionResult(
              success: false,
              error: 'Session expired',
              durationMs: durationMs,
            )
          : queued('Offline');
    }

    try {
      return await fromText(await upload(wav, accessToken));
    } on TranscriptionException catch (error) {
      if (error.statusCode == 401) {
        final String? fresh = await refreshToken?.call();
        if (fresh == null) {
          // The token could not be renewed now (often: no network). Keep
          // the recording; the outbox retries with a new session.
          return savedPath == null
              ? hardFailure('Session expired. Please try again.')
              : queued('Session expired');
        }
        try {
          return await fromText(await upload(wav, fresh));
        } catch (retryError) {
          if (kDebugMode) {
            debugPrint('Transcription retry after refresh failed: $retryError');
          }
          if (isQueueableError(retryError)) return queued('Offline');
          return hardFailure('Session expired. Please try again.');
        }
      }
      if (isQueueableError(error)) {
        return savedPath == null
            ? TranscriptionResult(
                success: false,
                error: error.statusCode == 502
                    ? 'Service unavailable'
                    : error.message,
                durationMs: durationMs,
              )
            : queued('Offline');
      }
      return hardFailure(
        error.message.isNotEmpty ? error.message : 'Transcription failed',
      );
    } on TimeoutException {
      return savedPath == null
          ? TranscriptionResult(
              success: false,
              error: 'Timed out',
              durationMs: durationMs,
            )
          : queued('Timed out');
    } catch (error) {
      if (isQueueableError(error)) {
        return savedPath == null
            ? TranscriptionResult(
                success: false,
                error: 'Error: $error',
                durationMs: durationMs,
              )
            : queued('Offline');
      }
      return hardFailure('Error: $error');
    }
  }

  Future<void> dispose() async {
    await stopRecording();
    await _pcmStreamSub?.cancel();
    await _streamingService?.dispose();
    await _audioRecorder.dispose();
  }

  // =====================================================================
  // Internals
  // =====================================================================

  void _handlePcmChunk(Uint8List data) {
    _computeAmplitudeFromPcm(data);
    // Every chunk is kept, also while the socket is live: the full recording
    // is saved to disk at stop, and it is the HTTP fallback when the socket
    // drops mid-recording.
    _pcmBuffer.add(data);
    if (_isStreamingMode && _streamingService != null) {
      _streamingService!.sendAudioChunk(data);
    }
  }

  /// Connect the WebSocket in the background. On success, send the PCM
  /// buffered since mic press and switch future chunks to the live path.
  Future<void> _tryConnectStreaming(String accessToken) async {
    StreamingTranscriptionService? service;
    try {
      service = StreamingTranscriptionService();
      final bool connected = await service.connect(
        accessToken: accessToken,
        sampleRate: _sampleRate,
        channels: _channels,
      );

      // If the user already stopped, or we already have a streaming
      // session, discard this connection.
      if (!connected || !_isMicActive || _isStreamingMode) {
        await service.dispose();
        if (kDebugMode && !connected) {
          debugPrint('WS connect failed — staying in buffered/HTTP fallback');
        }
        return;
      }

      // Send the buffered audio and flip the flag with no await in between,
      // so no chunk can fall between the two. The buffer itself stays: it
      // is the full recording that is saved at stop.
      final Uint8List buffered = _pcmBuffer.toBytes();
      _streamingService = service;
      _isStreamingMode = true;

      if (buffered.isNotEmpty) {
        service.sendAudioChunk(buffered);
      }
      if (kDebugMode) {
        debugPrint(
          'WS ready — sent ${buffered.length} buffered PCM bytes, '
          'forwarding live',
        );
      }
    } catch (error) {
      if (kDebugMode) debugPrint('WS upgrade error: $error');
      await service?.dispose();
      // Buffer still intact — HTTP fallback will handle it on stop.
    }
  }

  /// Waits for the socket's transcript. Returns null when the socket broke
  /// or failed for a network reason: the caller then uploads the saved
  /// recording over HTTP.
  Future<TranscriptionResult?> _transcribeStreaming(
    StreamingTranscriptionService service, {
    required String? savedPath,
    required int durationMs,
  }) async {
    Map<String, dynamic>? result;
    try {
      result = await service.finishAndTranscribe();
    } catch (error) {
      if (kDebugMode) debugPrint('WS transcription error: $error');
      return null;
    }
    if (result == null || service.hasDropped) return null;
    final Object? error = result['error'];
    if (error != null) {
      final String message = '$error';
      if (isQueueableError(message) ||
          message.contains('WebSocket') ||
          message.contains('timed out')) {
        return null;
      }
      if (savedPath != null) await VoiceSpoolService.delete(savedPath);
      return TranscriptionResult(
        success: false,
        error: message,
        durationMs: durationMs,
      );
    }
    final text = (result['text'] as String?)?.trim() ?? '';
    if (savedPath != null) await VoiceSpoolService.delete(savedPath);
    if (text.isEmpty) {
      return TranscriptionResult(
        success: false,
        error: 'No text found',
        durationMs: durationMs,
      );
    }
    return TranscriptionResult(
      success: true,
      text: text,
      durationMs: durationMs,
    );
  }

  /// Wrap raw PCM-16 LE mono samples in a minimal WAV (RIFF) container so
  /// the server's multipart transcription endpoint can decode them.
  static Uint8List _pcmToWav(
    Uint8List pcm, {
    required int sampleRate,
    required int channels,
  }) {
    const int bitsPerSample = 16;
    final int byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final int blockAlign = channels * (bitsPerSample ~/ 8);
    final int dataSize = pcm.length;
    final int riffSize = 36 + dataSize;

    final header = ByteData(44);
    // RIFF header.
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, riffSize, Endian.little);
    _writeAscii(header, 8, 'WAVE');
    // fmt chunk.
    _writeAscii(header, 12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data chunk.
    _writeAscii(header, 36, 'data');
    header.setUint32(40, dataSize, Endian.little);

    final out = Uint8List(44 + dataSize);
    out.setRange(0, 44, header.buffer.asUint8List());
    out.setRange(44, 44 + dataSize, pcm);
    return out;
  }

  static void _writeAscii(ByteData buf, int offset, String value) {
    final bytes = ascii.encode(value);
    for (int i = 0; i < bytes.length; i++) {
      buf.setUint8(offset + i, bytes[i]);
    }
  }

  void _computeAmplitudeFromPcm(Uint8List data) {
    if (data.length < 2) return;
    final byteData = ByteData.sublistView(data);
    double maxSample = 0;
    for (int i = 0; i + 1 < data.length; i += 2) {
      final sample = byteData.getInt16(i, Endian.little).abs().toDouble();
      if (sample > maxSample) maxSample = sample;
    }
    final double normalized = (maxSample / 32768.0).clamp(0.0, 1.0);

    if (_audioLevels.isNotEmpty) {
      _audioLevels.removeAt(0);
    }
    _audioLevels.add(normalized);
    onLevelsChanged?.call();
  }

  void _resetAudioLevels() {
    for (int i = 0; i < _audioLevels.length; i++) {
      _audioLevels[i] = 0.0;
    }
  }

  Future<bool> _ensureMicPermission() async {
    if (kIsWeb) return true; // Browser handles permission via record package.

    // permission_handler only supports Android, iOS, macOS, Windows.
    final bool supportsPermissionHandler =
        !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS ||
            Platform.isWindows);
    if (!supportsPermissionHandler) {
      return true;
    }

    try {
      final PermissionStatus status = await Permission.microphone.request();
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) {
        if (kDebugMode) debugPrint('Enable mic in settings');
        return false;
      }
      if (kDebugMode) debugPrint('Mic permission required');
      return false;
    } on MissingPluginException {
      if (kDebugMode) {
        debugPrint('permission_handler plugin unavailable; skipping request.');
      }
      return true;
    }
  }
}

/// Result of audio transcription.
class TranscriptionResult {
  final bool success;
  final String? text;
  final String? error;

  /// The recording on disk ([VoiceSpoolService]). Set only when
  /// [queueable]; the caller then owns the file (queue it or delete it).
  final String? savedPath;

  /// Length of the recording.
  final int? durationMs;

  /// The transcription could not run for a network reason, and the
  /// recording is kept at [savedPath]. The caller queues it in the outbox
  /// instead of showing an error.
  final bool queueable;

  TranscriptionResult({
    required this.success,
    this.text,
    this.error,
    this.savedPath,
    this.durationMs,
    this.queueable = false,
  });
}
