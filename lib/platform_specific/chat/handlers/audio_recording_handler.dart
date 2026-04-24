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
import 'package:chuk_chat/services/streaming_transcription_service.dart';

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

  /// Called whenever audio levels update, so the UI can rebuild.
  VoidCallback? onLevelsChanged;

  // PCM capture.
  StreamSubscription<Uint8List>? _pcmStreamSub;
  final BytesBuilder _pcmBuffer = BytesBuilder(copy: false);

  // Streaming (WebSocket) state.
  StreamingTranscriptionService? _streamingService;
  bool _isStreamingMode = false;

  bool get isMicActive => _isMicActive;
  bool get isTranscribingAudio => _isTranscribingAudio;
  List<double> get audioLevels => _audioLevels;

  /// Whether a WebSocket streaming session is active.
  bool get isStreamingMode => _isStreamingMode;

  /// Allow UI to set transcribing state for immediate feedback.
  void setTranscribing(bool value) {
    _isTranscribingAudio = value;
  }

  /// Start microphone recording.
  ///
  /// Recording begins **instantly** — PCM chunks are captured from the
  /// moment this method returns. If [accessToken] is provided a WebSocket
  /// connection is opened in the background; once ready the buffered audio
  /// is flushed and live chunks are forwarded. The caller does not wait for
  /// the WebSocket — recording never blocks on network.
  Future<bool> startRecording({String? accessToken}) async {
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

  /// Stop microphone recording.
  ///
  /// If [keepFile] is `true`, the captured audio is retained so the next
  /// [transcribeLastRecording] call can use it. Otherwise everything is
  /// discarded.
  Future<void> stopRecording({bool keepFile = false}) async {
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

    if (!keepFile) {
      _pcmBuffer.clear();
      if (_streamingService != null) {
        await _streamingService!.abort();
      }
      _streamingService = null;
      _isStreamingMode = false;
    }
  }

  /// Transcribe the last recorded audio.
  ///
  /// If the WebSocket was upgraded mid-recording, the server already has
  /// the audio — this only waits for the Whisper result. Otherwise the
  /// buffered PCM is wrapped as WAV and uploaded via HTTP.
  Future<TranscriptionResult> transcribeLastRecording({
    required ChatApiService apiService,
    required String accessToken,
  }) async {
    _isTranscribingAudio = true;

    if (_isStreamingMode && _streamingService != null) {
      return _transcribeStreaming();
    }
    return _transcribeBufferedPcm(
      apiService: apiService,
      accessToken: accessToken,
    );
  }

  void resetAudioLevels() {
    _resetAudioLevels();
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
    // If WS is live forward the chunk directly; otherwise keep it in the
    // buffer so nothing is lost while the WS is still connecting (or in
    // case it never connects).
    if (_isStreamingMode && _streamingService != null) {
      _streamingService!.sendAudioChunk(data);
    } else {
      _pcmBuffer.add(data);
    }
  }

  /// Connect the WebSocket in the background. On success, flush any PCM
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

      // Flush buffered audio before flipping the flag, so chunks that arrive
      // after the flip (but before this method finishes) go to the socket
      // and are not re-appended to the buffer.
      final Uint8List buffered = _pcmBuffer.toBytes();
      _pcmBuffer.clear();
      _streamingService = service;
      _isStreamingMode = true;

      if (buffered.isNotEmpty) {
        service.sendAudioChunk(buffered);
      }
      if (kDebugMode) {
        debugPrint(
          'WS ready — flushed ${buffered.length} buffered PCM bytes, '
          'forwarding live',
        );
      }
    } catch (error) {
      if (kDebugMode) debugPrint('WS upgrade error: $error');
      await service?.dispose();
      // Buffer still intact — HTTP fallback will handle it on stop.
    }
  }

  Future<TranscriptionResult> _transcribeStreaming() async {
    final service = _streamingService;
    if (service == null) {
      _isTranscribingAudio = false;
      _isStreamingMode = false;
      return TranscriptionResult(
        success: false,
        error: 'No streaming session',
      );
    }

    try {
      final result = await service.finishAndTranscribe();

      _streamingService = null;
      _isStreamingMode = false;
      _isTranscribingAudio = false;
      _pcmBuffer.clear();

      if (result == null) {
        return TranscriptionResult(success: false, error: 'No response');
      }
      if (result.containsKey('error')) {
        return TranscriptionResult(
          success: false,
          error: result['error'] as String,
        );
      }

      final text = (result['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        return TranscriptionResult(success: false, error: 'No text found');
      }
      return TranscriptionResult(success: true, text: text);
    } catch (error) {
      _streamingService = null;
      _isStreamingMode = false;
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Error: $error');
    }
  }

  Future<TranscriptionResult> _transcribeBufferedPcm({
    required ChatApiService apiService,
    required String accessToken,
  }) async {
    final Uint8List pcm = _pcmBuffer.toBytes();
    _pcmBuffer.clear();

    if (pcm.isEmpty) {
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'No audio');
    }

    final Uint8List wav = _pcmToWav(
      pcm,
      sampleRate: _sampleRate,
      channels: _channels,
    );

    try {
      final transcription = await apiService.transcribeAudioBytes(
        bytes: wav,
        filename: 'recording.wav',
        accessToken: accessToken,
      );
      final String text = transcription.text.trim();
      _isTranscribingAudio = false;

      if (text.isEmpty) {
        return TranscriptionResult(success: false, error: 'No text found');
      }
      return TranscriptionResult(success: true, text: text);
    } on TranscriptionException catch (error) {
      _isTranscribingAudio = false;
      switch (error.statusCode) {
        case 401:
          return TranscriptionResult(
            success: false,
            error: 'Session expired',
            requiresLogout: true,
          );
        case 502:
          return TranscriptionResult(
            success: false,
            error: 'Service unavailable',
          );
        default:
          final String message = error.message.isNotEmpty
              ? error.message
              : 'Transcription failed';
          return TranscriptionResult(success: false, error: message);
      }
    } on TimeoutException {
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Timed out');
    } catch (error) {
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Error: $error');
    }
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
    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows)) {
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
  final bool requiresLogout;

  TranscriptionResult({
    required this.success,
    this.text,
    this.error,
    this.requiresLogout = false,
  });
}
