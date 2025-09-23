import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

/// Default model, base URL and API key can be configured with dart-defines.
const String kLifeKitDefaultModel = String.fromEnvironment(
  'LIFEKIT_MODEL',
  defaultValue: 'gpt-4o-realtime-preview-2024-12-17',
);
const String kLifeKitBaseUrl = String.fromEnvironment(
  'OPENAI_BASE_URL',
  defaultValue: 'https://api.openai.com',
);
const String kLifeKitApiKey = String.fromEnvironment('OPENAI_API_KEY');

/// Represents the lifecycle state of the LifeKit realtime session.
enum LifeKitConnectionState { disconnected, connecting, connected, error }

/// Basic exception wrapper so UI can distinguish LifeKit failures from generic ones.
class LifeKitException implements Exception {
  final String message;

  LifeKitException(this.message);

  @override
  String toString() => 'LifeKitException: $message';
}

/// Encapsulates the realtime WebRTC session used for "voice mode" via LifeKit.
///
/// The class is intentionally lightweight – it only manages a single peer connection,
/// dispatches key high-level events (transcripts, reply text, generated images) and
/// exposes helpers to tweak the session (voice, instructions, playback speed, mic state).
class LifeKitClient {
  LifeKitClient({String? apiKey, String? model, String? baseUrl})
    : apiKey = (apiKey ?? kLifeKitApiKey).trim(),
      model = (model ?? kLifeKitDefaultModel).trim(),
      baseUrl = _normalizeBaseUrl(baseUrl ?? kLifeKitBaseUrl);

  final String apiKey;
  final String model;
  final String baseUrl;

  bool get hasValidApiKey => apiKey.isNotEmpty;

  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _rendererInitialized = false;

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _eventChannel;
  Completer<void>? _eventChannelReadyCompleter;

  final _transcriptController = StreamController<String>.broadcast();
  final _replyController = StreamController<String>.broadcast();
  final _imageController = StreamController<String?>.broadcast();
  final _thinkingController = StreamController<bool>.broadcast();
  final _connectionStateController =
      StreamController<LifeKitConnectionState>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  LifeKitConnectionState _currentState = LifeKitConnectionState.disconnected;
  String _replyBuffer = '';
  bool _disposed = false;
  bool _micEnabled = true;

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'https://api.openai.com';
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// Must be called once before the renderer is used.
  Future<void> initialize() async {
    if (_rendererInitialized) return;
    await _remoteRenderer.initialize();
    _rendererInitialized = true;
  }

  bool get isRendererInitialized => _rendererInitialized;

  RTCVideoRenderer get renderer => _remoteRenderer;

  Stream<String> get transcripts => _transcriptController.stream;

  Stream<String> get replies => _replyController.stream;

  Stream<String?> get images => _imageController.stream;

  Stream<bool> get thinking => _thinkingController.stream;

  Stream<LifeKitConnectionState> get connectionState =>
      _connectionStateController.stream;

  Stream<String> get errors => _errorController.stream;

  LifeKitConnectionState get state => _currentState;

  /// Connects to the realtime API and starts streaming microphone audio.
  Future<void> connect({
    String? instructions,
    String? voice,
    double? playbackRate,
    bool microphoneEnabled = true,
  }) async {
    if (!hasValidApiKey) {
      throw LifeKitException('Missing OPENAI_API_KEY dart-define for LifeKit.');
    }
    if (_disposed) {
      throw LifeKitException(
        'LifeKitClient was disposed. Instantiate a new client.',
      );
    }

    await initialize();

    _updateState(LifeKitConnectionState.connecting);
    _replyBuffer = '';
    _thinkingController.add(false);

    try {
      await _ensureMicrophonePermission();
      await _ensureLocalStream();
      _setMicEnabledInternal(microphoneEnabled);
      await _createPeerConnection();
      await _setupLocalTracks();
      await _negotiateSdp();
      await _waitForDataChannel();

      if (instructions != null || voice != null || playbackRate != null) {
        await updateSession(
          instructions: instructions,
          voice: voice,
          playbackRate: playbackRate,
        );
      }

      _updateState(LifeKitConnectionState.connected);
    } catch (error) {
      await _teardownConnection();
      _updateState(LifeKitConnectionState.error);
      _errorController.add(error.toString());
      rethrow;
    }
  }

  /// Sends a `session.update` payload to adjust instructions, voice or playback speed.
  Future<void> updateSession({
    String? instructions,
    String? voice,
    double? playbackRate,
  }) async {
    if (_eventChannel == null) return;
    final Map<String, dynamic> session = <String, dynamic>{};
    if (instructions != null) {
      session['instructions'] = instructions;
    }
    if (voice != null) {
      session['voice'] = voice;
    }
    if (playbackRate != null) {
      session['audio'] = {
        'output': {'rate': playbackRate},
      };
    }
    if (session.isEmpty) return;
    await _sendEvent({'type': 'session.update', 'session': session});
  }

  /// Enables or disables the microphone track without dropping the connection.
  Future<void> setMicEnabled(bool enabled) async {
    _setMicEnabledInternal(enabled);
    _micEnabled = enabled;
  }

  bool get isMicEnabled => _micEnabled;

  Future<void> disconnect() async {
    await _teardownConnection();
    _updateState(LifeKitConnectionState.disconnected);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _localStream?.dispose();
    await _remoteRenderer.dispose();
    await _transcriptController.close();
    await _replyController.close();
    await _imageController.close();
    await _thinkingController.close();
    await _connectionStateController.close();
    await _errorController.close();
  }

  Future<void> _ensureLocalStream() async {
    if (_localStream != null) return;
    final mediaConstraints = {
      'audio': {'echoCancellation': true, 'noiseSuppression': true},
      'video': false,
    };
    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
  }

  Future<void> _ensureMicrophonePermission() async {
    if (kIsWeb) {
      // Browser will prompt through getUserMedia.
      return;
    }
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw LifeKitException('Microphone permission was denied.');
    }
  }

  Future<void> _createPeerConnection() async {
    await _peerConnection?.close();
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };
    final constraints = {'mandatory': {}, 'optional': []};
    _peerConnection = await createPeerConnection(configuration, constraints);

    _peerConnection!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _updateState(LifeKitConnectionState.error);
      }
    };

    _peerConnection!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _updateState(LifeKitConnectionState.error);
      }
    };

    _peerConnection!.onTrack = (event) {
      if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams.first;
      }
    };

    _peerConnection!.onDataChannel = (channel) {
      _registerEventChannel(channel);
    };

    final localChannel = await _peerConnection!.createDataChannel(
      'oai-events',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = 0,
    );
    _registerEventChannel(localChannel);
  }

  Future<void> _setupLocalTracks() async {
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await _peerConnection?.addTrack(track, stream);
    }
  }

  Future<void> _negotiateSdp() async {
    final pc = _peerConnection;
    if (pc == null) {
      throw LifeKitException('Peer connection missing when negotiating SDP.');
    }

    final offer = await pc.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await pc.setLocalDescription(offer);
    await _waitForIceGatheringComplete(pc);
    final localDescription = await pc.getLocalDescription();
    final sdp = localDescription?.sdp ?? offer.sdp;

    final response = await http.post(
      Uri.parse('$baseUrl/v1/realtime?model=${Uri.encodeComponent(model)}'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/sdp',
        'OpenAI-Beta': 'realtime=v1',
      },
      body: sdp,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LifeKitException(
        'Failed to start LifeKit session (${response.statusCode}): ${response.body}',
      );
    }

    await pc.setRemoteDescription(
      RTCSessionDescription(response.body, 'answer'),
    );
  }

  Future<void> _waitForDataChannel() async {
    final channel = _eventChannel;
    if (channel == null) return;
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) return;
    _eventChannelReadyCompleter = Completer<void>();
    await _eventChannelReadyCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        throw LifeKitException(
          'Timed out waiting for LifeKit event channel to open.',
        );
      },
    );
  }

  Future<void> _waitForIceGatheringComplete(RTCPeerConnection pc) {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return Future.value();
    }
    final completer = Completer<void>();
    void handleState(RTCIceGatheringState state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    }

    final previousHandler = pc.onIceGatheringState;
    pc.onIceGatheringState = (state) {
      previousHandler?.call(state);
      handleState(state);
    };

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // If gathering never completes we still proceed – the session can trickle ICE.
      },
    );
  }

  void _registerEventChannel(RTCDataChannel channel) {
    _eventChannel = channel;
    channel.onMessage = (message) {
      if (message.isBinary) return;
      final text = message.text;
      if (text.trim().isEmpty) return;
      try {
        final payload = jsonDecode(text) as Map<String, dynamic>;
        _handleEvent(payload);
      } catch (error) {
        _errorController.add('Failed to parse LifeKit event: $error');
      }
    };
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (_eventChannelReadyCompleter != null &&
            !_eventChannelReadyCompleter!.isCompleted) {
          _eventChannelReadyCompleter!.complete();
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _eventChannelReadyCompleter?.completeError(
          LifeKitException('LifeKit event channel closed unexpectedly.'),
        );
        _eventChannelReadyCompleter = null;
      }
    };
  }

  Future<void> _sendEvent(Map<String, dynamic> event) async {
    final channel = _eventChannel;
    if (channel == null) return;
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      await _waitForDataChannel();
    }
    channel.send(RTCDataChannelMessage(jsonEncode(event)));
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'];
    switch (type) {
      case 'input_audio_buffer.speech_recognized':
        final transcript = (event['transcript'] ?? event['text']) as String?;
        if (transcript != null && transcript.isNotEmpty) {
          _transcriptController.add(transcript);
        }
        break;
      case 'response.created':
        _replyBuffer = '';
        _thinkingController.add(true);
        break;
      case 'response.delta':
        final delta = event['delta'];
        final addition = _extractText(delta);
        if (addition.isNotEmpty) {
          _replyBuffer += addition;
          _replyController.add(_replyBuffer);
        }
        final images = _extractImages(delta);
        if (images.isNotEmpty) {
          _imageController.add(images.last);
        }
        break;
      case 'response.completed':
        _thinkingController.add(false);
        final response = event['response'];
        final text = _extractText(response);
        if (text.isNotEmpty) {
          _replyBuffer = text;
          _replyController.add(_replyBuffer);
        }
        final images = _extractImages(response);
        if (images.isNotEmpty) {
          _imageController.add(images.last);
        }
        break;
      case 'response.output_item.added':
        final images = _extractImages(event['item']);
        if (images.isNotEmpty) {
          _imageController.add(images.last);
        }
        break;
      case 'error':
      case 'response.error':
        final message =
            event['error']?['message'] ??
            event['message'] ??
            'Unknown LifeKit error';
        _errorController.add(message.toString());
        break;
      default:
        break;
    }
  }

  String _extractText(dynamic root) {
    final buffer = StringBuffer();
    void walk(dynamic value) {
      if (value is Map) {
        final type = value['type'];
        if ((type == 'output_text' || type == 'output_text_delta') &&
            value['text'] is String) {
          buffer.write(value['text']);
        }
        value.forEach((_, v) => walk(v));
      } else if (value is List) {
        for (final item in value) {
          walk(item);
        }
      }
    }

    walk(root);
    return buffer.toString();
  }

  List<String> _extractImages(dynamic root) {
    final images = <String>[];
    void walk(dynamic value) {
      if (value is Map) {
        if (value.containsKey('image_base64') &&
            value['image_base64'] is String) {
          final format = value['format'] ?? 'png';
          images.add('data:image/$format;base64,${value['image_base64']}');
        } else if (value.containsKey('image_url') &&
            value['image_url'] is String) {
          images.add(value['image_url'] as String);
        }
        value.forEach((_, v) => walk(v));
      } else if (value is List) {
        for (final item in value) {
          walk(item);
        }
      }
    }

    walk(root);
    return images;
  }

  Future<void> _teardownConnection() async {
    try {
      await _eventChannel?.close();
    } catch (_) {}
    try {
      await _peerConnection?.close();
    } catch (_) {}
    _eventChannel = null;
    _peerConnection = null;
    _eventChannelReadyCompleter = null;
    _replyBuffer = '';
    _thinkingController.add(false);
  }

  void _updateState(LifeKitConnectionState next) {
    if (_currentState == next) return;
    _currentState = next;
    _connectionStateController.add(next);
  }

  void _setMicEnabledInternal(bool enabled) {
    for (final track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    _micEnabled = enabled;
  }
}
