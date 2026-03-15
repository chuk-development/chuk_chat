// lib/platform_specific/chat/handlers/audio_recording_handler.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/permission_handler_stub.dart'
    if (dart.library.io) 'package:permission_handler/permission_handler.dart';
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/streaming_transcription_service.dart';
import 'package:http/http.dart' as http;

/// Handles audio recording functionality including permissions, recording,
/// and transcription.
///
/// Supports two modes:
///
/// **Streaming mode** (preferred) — when [startRecording] is called with
/// an [accessToken], audio is captured as a PCM-16 stream and each chunk
/// is forwarded to the server over a WebSocket *as the user speaks*. When
/// [transcribeLastRecording] is called the server already has the audio, so
/// only the Groq inference latency remains.
///
/// **File mode** (fallback) — when [startRecording] is called without an
/// access token, or when the WebSocket connection fails, audio is recorded
/// to a local file and uploaded via HTTP when transcription is requested.
class AudioRecordingHandler {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final List<double> _audioLevels = List<double>.filled(
    32,
    0.0,
    growable: true,
  );

  // --- common state ---
  StreamSubscription<Amplitude>? _amplitudeSub;
  bool _isMicActive = false;
  bool _isTranscribingAudio = false;

  // --- file-mode state ---
  String? _lastRecordedFilePath;
  Uint8List? _lastRecordedBytes;
  String? _activeRecordingPath;

  // --- streaming-mode state ---
  StreamingTranscriptionService? _streamingService;
  StreamSubscription<Uint8List>? _pcmStreamSub;
  bool _isStreamingMode = false;

  // Getters
  bool get isMicActive => _isMicActive;
  bool get isTranscribingAudio => _isTranscribingAudio;
  List<double> get audioLevels => _audioLevels;

  /// Whether the handler is using the fast WebSocket streaming path.
  bool get isStreamingMode => _isStreamingMode;

  /// Allow UI to set transcribing state for immediate feedback.
  void setTranscribing(bool value) {
    _isTranscribingAudio = value;
  }

  /// Start microphone recording.
  ///
  /// When [accessToken] is provided the handler attempts to open a WebSocket
  /// to the server and stream PCM audio in real-time (streaming mode). If the
  /// WebSocket connection fails, it falls back to file-based recording
  /// transparently.
  ///
  /// When [accessToken] is `null`, file-based recording is used directly.
  Future<bool> startRecording({String? accessToken}) async {
    try {
      if (!await _ensureMicPermission()) {
        return false;
      }

      if (!await _audioRecorder.hasPermission()) {
        if (kDebugMode) {
          debugPrint('Microphone permission required');
        }
        return false;
      }

      if (await _audioRecorder.isRecording()) {
        return true;
      }

      _resetAudioLevels();
      _amplitudeSub?.cancel();

      // --- Try streaming mode if we have a token ---
      if (accessToken != null) {
        final connected = await _tryStartStreaming(accessToken);
        if (connected) {
          _isMicActive = true;
          return true;
        }
        // Streaming failed — fall through to file mode.
        if (kDebugMode) {
          debugPrint(
            'Streaming transcription unavailable, falling back to file mode',
          );
        }
      }

      // --- File mode (original behaviour) ---
      return _startFileRecording();
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to start microphone: $error\n$stackTrace');
      }
      return false;
    }
  }

  /// Stop microphone recording.
  Future<void> stopRecording({bool keepFile = false}) async {
    if (_isStreamingMode) {
      await _stopStreamingRecording(keepFile: keepFile);
    } else {
      await _stopFileRecording(keepFile: keepFile);
    }
    _isMicActive = false;
  }

  /// Transcribe the last recorded audio.
  ///
  /// In streaming mode the server already has the audio — this just waits
  /// for the Groq result (fast). In file mode the recording is uploaded
  /// via HTTP (slower).
  Future<TranscriptionResult> transcribeLastRecording({
    required ChatApiService apiService,
    required String accessToken,
  }) async {
    _isTranscribingAudio = true;

    if (_isStreamingMode && _streamingService != null) {
      return _transcribeStreaming();
    }

    // Fall back to the original HTTP-based transcription.
    if (kIsWeb) {
      return _transcribeWebRecording(
        apiService: apiService,
        accessToken: accessToken,
      );
    }
    return _transcribeFileRecording(
      apiService: apiService,
      accessToken: accessToken,
    );
  }

  /// Reset audio levels to zero.
  void resetAudioLevels() {
    _resetAudioLevels();
  }

  /// Clean up resources.
  Future<void> dispose() async {
    await stopRecording();
    _amplitudeSub?.cancel();
    _pcmStreamSub?.cancel();
    await _streamingService?.dispose();
    await _audioRecorder.dispose();
  }

  // =====================================================================
  // STREAMING MODE
  // =====================================================================

  /// Attempt to start a streaming-mode recording session.
  ///
  /// Returns `true` if the WebSocket connected and the PCM audio stream
  /// started successfully. Returns `false` on any failure.
  Future<bool> _tryStartStreaming(String accessToken) async {
    try {
      _streamingService = StreamingTranscriptionService();
      final connected = await _streamingService!.connect(
        accessToken: accessToken,
      );
      if (!connected) {
        await _streamingService?.dispose();
        _streamingService = null;
        return false;
      }

      // Start the recorder in PCM-16 streaming mode.
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      );
      final Stream<Uint8List> pcmStream = await _audioRecorder.startStream(
        config,
      );

      // Forward every PCM chunk to the server and compute amplitude.
      _pcmStreamSub = pcmStream.listen((Uint8List data) {
        _streamingService?.sendAudioChunk(data);
        _computeAmplitudeFromPcm(data);
      });

      _isStreamingMode = true;
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Streaming start failed: $e');
      }
      _pcmStreamSub?.cancel();
      _pcmStreamSub = null;
      await _streamingService?.dispose();
      _streamingService = null;
      _isStreamingMode = false;
      return false;
    }
  }

  /// Stop a streaming-mode recording session.
  Future<void> _stopStreamingRecording({bool keepFile = false}) async {
    _pcmStreamSub?.cancel();
    _pcmStreamSub = null;

    try {
      await _audioRecorder.stop();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error stopping streaming recorder: $e');
      }
    }

    if (!keepFile) {
      // User cancelled — abort the WebSocket without transcribing.
      await _streamingService?.abort();
      _streamingService = null;
      _isStreamingMode = false;
    }
    // When keepFile is true we keep _streamingService alive so
    // transcribeLastRecording() can call finishAndTranscribe().
  }

  /// Get the transcription result from the streaming WebSocket.
  Future<TranscriptionResult> _transcribeStreaming() async {
    final service = _streamingService;
    if (service == null) {
      _isTranscribingAudio = false;
      _isStreamingMode = false;
      return TranscriptionResult(success: false, error: 'No streaming session');
    }

    try {
      final result = await service.finishAndTranscribe();

      _streamingService = null;
      _isStreamingMode = false;
      _isTranscribingAudio = false;

      if (result == null) {
        return TranscriptionResult(success: false, error: 'No response');
      }
      if (result.containsKey('error')) {
        final error = result['error'] as String;
        return TranscriptionResult(success: false, error: error);
      }

      final text = (result['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        return TranscriptionResult(success: false, error: 'No text found');
      }
      return TranscriptionResult(success: true, text: text);
    } catch (e) {
      _streamingService = null;
      _isStreamingMode = false;
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Error: $e');
    }
  }

  /// Compute a normalised amplitude value from raw PCM-16 LE samples.
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
  }

  // =====================================================================
  // FILE MODE (original implementation)
  // =====================================================================

  Future<bool> _startFileRecording() async {
    if (kIsWeb) {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.opus,
          sampleRate: 16000,
          bitRate: 64000,
        ),
        path: '',
      );
    } else {
      final String path = await _createRecordingPath();
      _activeRecordingPath = path;

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          bitRate: 64000,
        ),
        path: path,
      );
    }

    // Audio visualisation via the recorder's amplitude stream.
    _amplitudeSub = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 30))
        .listen(_handleAmplitudeSample);

    _isStreamingMode = false;
    _isMicActive = true;
    return true;
  }

  Future<void> _stopFileRecording({bool keepFile = false}) async {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    try {
      if (!await _audioRecorder.isRecording()) {
        if (!keepFile) {
          _lastRecordedFilePath = null;
          _lastRecordedBytes = null;
          if (!kIsWeb) await _deleteRecordingFile(_activeRecordingPath);
        }
        _activeRecordingPath = null;
        return;
      }

      final String? path = await _audioRecorder.stop();

      if (kIsWeb) {
        if (keepFile && path != null) {
          try {
            final response = await http.get(Uri.parse(path));
            _lastRecordedBytes = response.bodyBytes;
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to fetch web audio blob: $e');
            }
            _lastRecordedBytes = null;
          }
        } else {
          _lastRecordedBytes = null;
        }
        _lastRecordedFilePath = null;
      } else {
        final String? effectivePath = path ?? _activeRecordingPath;
        _activeRecordingPath = null;

        if (keepFile) {
          _lastRecordedFilePath = effectivePath;
        } else {
          _lastRecordedFilePath = null;
          await _deleteRecordingFile(effectivePath);
        }
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to stop microphone: $error\n$stackTrace');
      }
    }
  }

  Future<TranscriptionResult> _transcribeFileRecording({
    required ChatApiService apiService,
    required String accessToken,
  }) async {
    final String? audioPath = _lastRecordedFilePath;
    if (audioPath == null) {
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'No audio');
    }

    final File audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Audio missing');
    }

    try {
      final transcription = await apiService.transcribeAudioFile(
        file: audioFile,
        accessToken: accessToken,
      );
      final String text = transcription.text.trim();

      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _isTranscribingAudio = false;

      if (text.isEmpty) {
        return TranscriptionResult(success: false, error: 'No text found');
      }
      return TranscriptionResult(success: true, text: text);
    } on TranscriptionException catch (error) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
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
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Timed out');
    } catch (error) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Error: $error');
    }
  }

  Future<TranscriptionResult> _transcribeWebRecording({
    required ChatApiService apiService,
    required String accessToken,
  }) async {
    final Uint8List? bytes = _lastRecordedBytes;
    if (bytes == null || bytes.isEmpty) {
      _isTranscribingAudio = false;
      _lastRecordedBytes = null;
      return TranscriptionResult(success: false, error: 'No audio');
    }

    try {
      final transcription = await apiService.transcribeAudioBytes(
        bytes: bytes,
        filename: 'recording.webm',
        accessToken: accessToken,
      );
      final String text = transcription.text.trim();
      _lastRecordedBytes = null;
      _isTranscribingAudio = false;

      if (text.isEmpty) {
        return TranscriptionResult(success: false, error: 'No text found');
      }
      return TranscriptionResult(success: true, text: text);
    } on TranscriptionException catch (error) {
      _lastRecordedBytes = null;
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
      _lastRecordedBytes = null;
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Timed out');
    } catch (error) {
      _lastRecordedBytes = null;
      _isTranscribingAudio = false;
      return TranscriptionResult(success: false, error: 'Error: $error');
    }
  }

  // =====================================================================
  // Shared helpers
  // =====================================================================

  void _resetAudioLevels() {
    for (int i = 0; i < _audioLevels.length; i++) {
      _audioLevels[i] = 0.0;
    }
  }

  void _handleAmplitudeSample(Amplitude amplitude) {
    final double decibels = amplitude.current;
    const double minDb = -60.0;
    const double maxDb = 0.0;
    final double normalized = ((decibels - minDb) / (maxDb - minDb)).clamp(
      0.0,
      1.0,
    );

    if (_audioLevels.isNotEmpty) {
      _audioLevels.removeAt(0);
    }
    _audioLevels.add(normalized);
  }

  Future<bool> _ensureMicPermission() async {
    if (kIsWeb) return true; // Browser handles permission via record package

    // permission_handler only supports Android, iOS, macOS, and Windows.
    // On Linux (and any other desktop), skip — the record package handles
    // audio permissions natively via PulseAudio/PipeWire.
    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows)) {
      return true;
    }

    try {
      final PermissionStatus status = await Permission.microphone.request();
      if (status.isGranted) {
        return true;
      }
      if (status.isPermanentlyDenied) {
        if (kDebugMode) {
          debugPrint('Enable mic in settings');
        }
        return false;
      }
      if (kDebugMode) {
        debugPrint('Mic permission required');
      }
      return false;
    } on MissingPluginException {
      // Plugin unavailable on this platform — proceed without it.
      if (kDebugMode) {
        debugPrint('permission_handler plugin unavailable; skipping request.');
      }
      return true;
    }
  }

  Future<String> _createRecordingPath() async {
    final Directory tempDir = await getTemporaryDirectory();
    final Directory audioDir = Directory('${tempDir.path}/chuk_chat_audio');
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    return '${audioDir.path}/rec_$timestamp.m4a';
  }

  Future<void> _deleteRecordingFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to delete audio file: $error\n$stackTrace');
      }
    }
  }
}

/// Result of audio transcription
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
