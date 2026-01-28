// lib/platform_specific/chat/handlers/audio_recording_handler.dart
import 'dart:async';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/record_stub.dart'
    if (dart.library.io) 'package:record/record.dart';
import 'package:chuk_chat/utils/permission_handler_stub.dart'
    if (dart.library.io) 'package:permission_handler/permission_handler.dart';
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';

/// Handles audio recording functionality including permissions, recording, and transcription
class AudioRecordingHandler {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final List<double> _audioLevels = List<double>.filled(32, 0.0, growable: true);

  StreamSubscription<Amplitude>? _amplitudeSub;
  String? _lastRecordedFilePath;
  String? _activeRecordingPath;
  bool _isMicActive = false;
  bool _isTranscribingAudio = false;

  // Getters
  bool get isMicActive => _isMicActive;
  bool get isTranscribingAudio => _isTranscribingAudio;
  List<double> get audioLevels => _audioLevels;

  /// Start microphone recording
  Future<bool> startRecording() async {
    try {
      if (!await _ensureMicPermission()) {
        return false;
      }

      if (!await _audioRecorder.hasPermission()) {
        debugPrint('Microphone permission required');
        return false;
      }

      if (await _audioRecorder.isRecording()) {
        return true;
      }

      final String path = await _createRecordingPath();
      _activeRecordingPath = path;

      _resetAudioLevels();
      _amplitudeSub?.cancel();

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          bitRate: 64000,
        ),
        path: path,
      );

      // More responsive audio visualization (30ms instead of 80ms)
      _amplitudeSub = _audioRecorder
          .onAmplitudeChanged(const Duration(milliseconds: 30))
          .listen(_handleAmplitudeSample);

      _isMicActive = true;
      return true;
    } catch (error, stackTrace) {
      debugPrint('Failed to start microphone: $error\n$stackTrace');
      return false;
    }
  }

  /// Stop microphone recording
  Future<void> stopRecording({bool keepFile = false}) async {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    try {
      if (!await _audioRecorder.isRecording()) {
        if (!keepFile) {
          _lastRecordedFilePath = null;
          await _deleteRecordingFile(_activeRecordingPath);
        }
        _activeRecordingPath = null;
        return;
      }

      final String? path = await _audioRecorder.stop();
      final String? effectivePath = path ?? _activeRecordingPath;
      _activeRecordingPath = null;

      if (keepFile) {
        _lastRecordedFilePath = effectivePath;
      } else {
        _lastRecordedFilePath = null;
        await _deleteRecordingFile(effectivePath);
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to stop microphone: $error\n$stackTrace');
    }
    _isMicActive = false;
  }

  /// Transcribe the last recorded audio file
  Future<TranscriptionResult> transcribeLastRecording({
    required ChatApiService apiService,
    required String accessToken,
  }) async {
    _isTranscribingAudio = true;

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
          return TranscriptionResult(success: false, error: 'Session expired', requiresLogout: true);
        case 502:
          return TranscriptionResult(success: false, error: 'Service unavailable');
        default:
          final String message = error.message.isNotEmpty ? error.message : 'Transcription failed';
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

  /// Reset audio levels to zero
  void resetAudioLevels() {
    _resetAudioLevels();
  }

  void _resetAudioLevels() {
    for (int i = 0; i < _audioLevels.length; i++) {
      _audioLevels[i] = 0.0;
    }
  }

  void _handleAmplitudeSample(Amplitude amplitude) {
    final double decibels = amplitude.current;
    const double minDb = -60.0;
    const double maxDb = 0.0;
    final double normalized = ((decibels - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);

    if (_audioLevels.isNotEmpty) {
      _audioLevels.removeAt(0);
    }
    _audioLevels.add(normalized);
  }

  Future<bool> _ensureMicPermission() async {
    final PermissionStatus status = await Permission.microphone.request();
    if (status.isGranted) {
      return true;
    }
    if (status.isPermanentlyDenied) {
      debugPrint('Enable mic in settings');
      return false;
    }
    debugPrint('Mic permission required');
    return false;
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
      debugPrint('Failed to delete audio file: $error\n$stackTrace');
    }
  }

  /// Clean up resources
  Future<void> dispose() async {
    await stopRecording();
    _amplitudeSub?.cancel();
    await _audioRecorder.dispose();
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
