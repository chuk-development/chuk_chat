// lib/services/streaming_transcription_service.dart
//
// Streams audio to the server via WebSocket as the user speaks,
// eliminating the upload latency that occurs with the traditional
// record-then-upload approach. The server accumulates PCM chunks and
// sends them to Groq Whisper as soon as the client signals "stop".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/websocket_connector.dart' as ws_connector;

/// Manages a WebSocket connection for streaming audio chunks to the
/// server for real-time transcription.
///
/// Usage:
/// 1. [connect] with an access token — opens the WS and authenticates.
/// 2. [sendAudioChunk] for every PCM chunk from the recorder's stream.
/// 3. [finishAndTranscribe] when recording stops — tells the server to
///    transcribe and waits for the result (fast, audio is already there).
/// 4. [abort] to cancel without transcribing.
class StreamingTranscriptionService {
  /// Timeout for establishing the WebSocket connection.
  /// Non-blocking — runs in background while file recording is already active.
  static const _connectionTimeout = Duration(seconds: 5);

  /// Timeout for the Groq transcription after signalling "stop".
  static const _transcriptionTimeout = Duration(seconds: 60);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Completer<bool>? _readyCompleter;
  Completer<Map<String, dynamic>>? _resultCompleter;
  bool _isConnected = false;
  bool _disposed = false;


  /// Construct the WebSocket URL from the HTTP API base URL.
  static Uri get _wsUrl {
    final httpUrl = ApiConfigService.apiBaseUrl;
    final uri = Uri.parse(httpUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: wsScheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/v1/ai/transcribe-audio/ws',
    );
  }

  /// Open a WebSocket connection and authenticate.
  ///
  /// Returns `true` if the server acknowledged readiness, `false` on
  /// any failure (timeout, auth error, network error). The caller
  /// should fall back to HTTP upload when this returns `false`.
  Future<bool> connect({
    required String accessToken,
    int sampleRate = 16000,
    int channels = 1,
  }) async {
    if (_disposed) return false;

    try {
      _readyCompleter = Completer<bool>();
      _resultCompleter = Completer<Map<String, dynamic>>();

      _channel = await ws_connector
          .connectWebSocket(_wsUrl)
          .timeout(_connectionTimeout);
      await _channel!.ready.timeout(_connectionTimeout);

      // Listen for server responses.
      _streamSub = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      // Send authentication + audio config.
      _channel!.sink.add(
        jsonEncode({
          'token': accessToken,
          'config': {
            'sample_rate': sampleRate,
            'channels': channels,
            'encoding': 'pcm16',
          },
        }),
      );

      // Wait for the server's {"status": "ready"} response.
      final ready = await _readyCompleter!.future.timeout(_connectionTimeout);
      _isConnected = ready;
      return ready;
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('StreamingTranscription: connection/auth timed out');
      }
      await _cleanup();
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('StreamingTranscription: connect failed: $e');
      }
      await _cleanup();
      return false;
    }
  }

  /// Send a PCM audio chunk to the server.
  ///
  /// Call this for every [Uint8List] chunk emitted by the recorder's
  /// `startStream()`. No-op if not connected.
  void sendAudioChunk(Uint8List pcmData) {
    if (!_isConnected || _channel == null || _disposed) return;
    try {
      _channel!.sink.add(pcmData);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('StreamingTranscription: sendAudioChunk error: $e');
      }
    }
  }

  /// Signal the server that recording is finished, wait for the
  /// transcription result.
  ///
  /// Returns a map like `{"text": "...", "billing": {...}}` on success,
  /// or `{"error": "..."}` on failure. Returns `null` if not connected.
  Future<Map<String, dynamic>?> finishAndTranscribe() async {
    if (!_isConnected || _channel == null || _disposed) return null;

    try {
      // Tell the server we're done recording.
      _channel!.sink.add(jsonEncode({'action': 'stop'}));

      // Wait for the transcription result.
      final result = await _resultCompleter!.future.timeout(
        _transcriptionTimeout,
      );
      return result;
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('StreamingTranscription: transcription timed out');
      }
      return {'error': 'Transcription timed out. Please try again.'};
    } catch (e) {
      if (kDebugMode) {
        debugPrint('StreamingTranscription: finishAndTranscribe error: $e');
      }
      return {'error': 'Transcription error: $e'};
    } finally {
      await _cleanup();
    }
  }

  /// Cancel streaming without transcribing.
  Future<void> abort() async {
    await _cleanup();
  }

  /// Release all resources. Call when the service is no longer needed.
  Future<void> dispose() async {
    _disposed = true;
    await _cleanup();
  }

  // --------------- private helpers ---------------

  void _onMessage(dynamic message) {
    if (message is! String) return;
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;

      // Handle the "ready" handshake response.
      if (data.containsKey('status') && data['status'] == 'ready') {
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.complete(true);
        }
        return;
      }

      // Handle errors during the handshake phase.
      if (data.containsKey('error') &&
          _readyCompleter != null &&
          !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete(false);
        return;
      }

      // Handle transcription result or error.
      if (data.containsKey('text') || data.containsKey('error')) {
        if (_resultCompleter != null && !_resultCompleter!.isCompleted) {
          _resultCompleter!.complete(data);
        }
      }
    } on FormatException catch (e) {
      if (kDebugMode) {
        debugPrint('StreamingTranscription: invalid JSON from server: $e');
      }
    }
  }

  void _onError(dynamic error) {
    if (kDebugMode) {
      debugPrint('StreamingTranscription: WS error: $error');
    }
    _isConnected = false;
    _completeWithError('WebSocket error: $error');
  }

  void _onDone() {
    _isConnected = false;
    _completeWithError('WebSocket closed unexpectedly');
  }

  void _completeWithError(String message) {
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.complete(false);
    }
    if (_resultCompleter != null && !_resultCompleter!.isCompleted) {
      _resultCompleter!.complete({'error': message});
    }
  }

  Future<void> _cleanup() async {
    _isConnected = false;
    _streamSub?.cancel();
    _streamSub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }
}
