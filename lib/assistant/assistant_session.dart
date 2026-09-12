import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';

import 'assistant_bridge.dart';
import 'assistant_config.dart';
import 'assistant_microphone.dart';
import 'assistant_result.dart';
import 'assistant_tools.dart';

/// Where one assistant turn currently stands.
enum AssistantPhase {
  starting,
  listening,
  transcribing,
  thinking,
  acting,
  paused,
  error,
}

/// The whole assistant turn: endpointed microphone, transcription through the
/// API proxy, one hard-wired model with native tool calls, and device tools.
///
/// Everything goes through the same proxy the chat uses — `/v1/ai/transcribe-
/// audio` for speech and the multiplexed `/v2/ws` socket for the model — so
/// there is no second API key and no second account on the device.
///
/// The answer is **written, never spoken.** Reading it out is slower than
/// showing it, it cannot carry a list or a card, and it forces the microphone
/// to pause for the length of the answer.
class AssistantSession extends ChangeNotifier {
  AssistantSession({ChatApiService? apiService, AssistantMicrophone? microphone})
    : _api = apiService ?? ChatApiService(),
      _injectedMicrophone = microphone;

  final ChatApiService _api;
  final AssistantMicrophone? _injectedMicrophone;
  final List<Map<String, dynamic>> _history = <Map<String, dynamic>>[];

  AssistantMicrophone? _microphone;
  AssistantSettings _settings = const AssistantSettings();

  AssistantPhase _phase = AssistantPhase.starting;
  String _userText = '';
  String _answer = '';
  String _error = '';
  double _level = 0;
  bool _muted = false;
  bool _turnInFlight = false;
  bool _disposed = false;
  List<AssistantToolRun> _tools = <AssistantToolRun>[];
  AssistantCard? _card;

  AssistantPhase get phase => _phase;
  AssistantSettings get settings => _settings;

  /// The transcribed user utterance of the current turn.
  String get userText => _userText;

  /// The assistant answer text.
  String get answer => _answer;

  /// Non-empty when the session cannot continue.
  String get error => _error;

  /// Microphone level, 0 to 1, for the waveform.
  double get level => _level;

  bool get muted => _muted;
  bool get listening => _phase == AssistantPhase.listening;

  /// Tool calls of the current turn, oldest first.
  List<AssistantToolRun> get tools => List.unmodifiable(_tools);

  /// The visual result of the current turn, if a tool produced one.
  AssistantCard? get card => _card;

  bool get busy =>
      _phase == AssistantPhase.transcribing ||
      _phase == AssistantPhase.thinking ||
      _phase == AssistantPhase.acting;

  String get statusLabel => switch (_phase) {
    AssistantPhase.starting => 'Starte …',
    AssistantPhase.listening => 'Ich höre zu',
    AssistantPhase.transcribing => 'Verstehe …',
    AssistantPhase.thinking => 'Denke nach …',
    AssistantPhase.acting => 'Führe aus …',
    AssistantPhase.paused => 'Mikrofon pausiert',
    AssistantPhase.error => 'Fehler',
  };

  Future<void> start() async {
    // start() is also the retry path out of the error phase, so an earlier
    // recorder can still be running. Left alive its stream keeps feeding
    // utterances into a session that has moved on.
    final previous = _microphone;
    _microphone = null;
    if (previous != null) await previous.dispose();

    _settings = await AssistantSettingsStore.load();
    if (!AssistantPlatform.isSupported) {
      _fail('Der Assistent läuft nur auf Android.');
      return;
    }
    if (await _awaitAccessToken() == null) {
      _fail('Nicht angemeldet. Melde dich in Chuk Chat an.');
      return;
    }

    _history
      ..clear()
      ..add({'role': 'system', 'content': _systemPrompt()});

    final microphone =
        _injectedMicrophone ??
        AssistantMicrophone(
          onUtterance: (wav) => unawaited(_onUtterance(wav)),
          onLevel: (value) {
            _level = value;
            _notify();
          },
        );
    _microphone = microphone;

    if (!await microphone.hasPermission()) {
      _fail('Ohne Mikrofon-Freigabe kann der Assistent nicht zuhören.');
      return;
    }

    try {
      // Foreground service of type microphone: Android keeps the recording
      // alive if the surface loses focus mid-question.
      await AssistantBridge.startVoiceService();
    } catch (error) {
      if (kDebugMode) debugPrint('assistant voice service failed: $error');
    }

    if (!await microphone.start()) {
      _fail('Mikrofon konnte nicht gestartet werden.');
      return;
    }
    _set(AssistantPhase.listening);
  }

  /// Pause or resume the microphone. In the error state this retries.
  Future<void> toggleMute() async {
    if (_phase == AssistantPhase.error) {
      _error = '';
      await start();
      return;
    }
    _muted = !_muted;
    if (_muted) {
      _microphone?.pause();
      _level = 0;
      _set(AssistantPhase.paused);
    } else {
      _microphone?.resume();
      _set(AssistantPhase.listening);
    }
  }

  /// Push the visible screen text into the conversation, so the next question
  /// already has the context without spending a tool round on it.
  Future<void> attachScreenContext() async {
    try {
      final context = await AssistantBridge.getCurrentContext();
      final text = (context['visibleText'] ?? '').toString();
      if (text.trim().isEmpty) return;
      _history.add({
        'role': 'system',
        'content':
            'Sichtbarer Bildschirm (${context['packageName']}):\n'
            '${text.length > 4000 ? text.substring(0, 4000) : text}',
      });
      _notify();
    } catch (error) {
      if (kDebugMode) debugPrint('assistant screen context failed: $error');
    }
  }

  Future<void> _onUtterance(Uint8List wav) async {
    if (_disposed || _muted || _turnInFlight) return;
    _turnInFlight = true;
    try {
      await _runTurn(wav);
    } catch (error, stack) {
      if (kDebugMode) debugPrint('assistant turn failed: $error\n$stack');
      _fail(_humanError(error));
    } finally {
      _turnInFlight = false;
      if (!_disposed && _phase != AssistantPhase.error) {
        _set(_muted ? AssistantPhase.paused : AssistantPhase.listening);
      }
    }
  }

  Future<void> _runTurn(Uint8List wav) async {
    final token = await _accessToken();
    if (token == null) {
      _fail('Sitzung abgelaufen. Melde dich neu an.');
      return;
    }

    _tools = <AssistantToolRun>[];
    _card = null;
    _answer = '';
    _set(AssistantPhase.transcribing);

    // The microphone keeps running while the model answers, but a turn that is
    // already in flight swallows further utterances (see _onUtterance), so the
    // user can still interrupt by pausing.
    final transcription = await _api.transcribeAudioBytes(
      bytes: wav,
      filename: 'assistant.wav',
      accessToken: token,
    );
    final transcript = transcription.text.trim();
    if (transcript.isEmpty) return;

    _userText = transcript;
    _history.add({'role': 'user', 'content': transcript});
    _set(AssistantPhase.thinking);

    final runtime = AssistantToolRuntime(
      serverUrl: ApiConfigService.apiBaseUrl,
      serverHeaders: {'Authorization': 'Bearer $token'},
      describeScreenshot: (question, base64Jpeg) =>
          _describeScreenshot(question, base64Jpeg, token),
      language: _settings.language,
    );

    var nextMessage = transcript;
    for (var round = 0; round < kAssistantMaxToolRounds; round++) {
      final pass = await _chatPass(message: nextMessage, token: token);
      if (pass.error != null) {
        _fail(pass.error!);
        return;
      }

      if (pass.toolCalls.isEmpty) {
        _answer = pass.content.trim();
        break;
      }

      _set(AssistantPhase.acting);
      _history.add({
        'role': 'assistant',
        'content': pass.content.trim().isEmpty ? null : pass.content.trim(),
        'tool_calls': [
          for (final call in pass.toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {'name': call.name, 'arguments': call.arguments},
            },
        ],
      });

      for (final call in pass.toolCalls) {
        final tool = assistantToolsByName[call.name];
        final args = _decodeArguments(call.arguments);
        final run = AssistantToolRun(
          name: call.name,
          label: tool?.label(args) ?? call.name,
        );
        _tools = [..._tools, run];
        _notify();

        await runAssistantTool(run: run, args: args, runtime: runtime);
        if (run.card != null) _card = run.card;
        _history.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': run.content,
        });
        _notify();
      }

      // The tool results ARE the model's next input, not a synthetic user
      // turn — the same shape the chat tool loop uses.
      nextMessage = '';
    }

    if (_answer.isEmpty) {
      _answer = 'Dazu habe ich keine Antwort gefunden.';
    }
    _trimHistory();
  }

  /// One request to the model. Returns the assembled content and any native
  /// tool calls it asked for.
  Future<_AssistantPass> _chatPass({
    required String message,
    required String token,
  }) async {
    final content = StringBuffer();
    final toolCalls = <NativeToolCall>[];
    String? error;

    await for (final event in WebSocketChatService.sendStreamingChat(
      accessToken: token,
      message: message,
      modelId: kAssistantModelId,
      providerSlug: kAssistantProviderSlug,
      history: List<Map<String, dynamic>>.from(_history),
      maxTokens: kAssistantMaxTokens,
      temperature: 0.3,
      reasoningEffort: kAssistantReasoningEffort,
      tools: assistantToolSchemas,
    )) {
      switch (event) {
        case ContentEvent(text: final chunk):
          content.write(chunk);
        case ToolCallsEvent(calls: final incoming):
          toolCalls.addAll(incoming);
        case ErrorEvent(message: final failure):
          error ??= failure;
        default:
          break;
      }
    }

    return _AssistantPass(
      content: content.toString(),
      toolCalls: toolCalls,
      error: error,
    );
  }

  /// One-shot vision call for `look_at_screen`. GLM 5.3 Flash is multimodal,
  /// so the screenshot goes to the same model as a data URI.
  Future<String> _describeScreenshot(
    String question,
    String base64Jpeg,
    String token,
  ) async {
    final buffer = StringBuffer();
    await for (final event in WebSocketChatService.sendStreamingChat(
      accessToken: token,
      message: question,
      modelId: kAssistantModelId,
      providerSlug: kAssistantProviderSlug,
      systemPrompt:
          'Beschreibe knapp und sachlich, was auf dem Bildschirmfoto zu sehen '
          'ist, und beantworte die Frage dazu. Keine Aufzaehlungen.',
      maxTokens: 400,
      temperature: 0.2,
      reasoningEffort: kAssistantReasoningEffort,
      images: ['data:image/jpeg;base64,$base64Jpeg'],
    )) {
      if (event is ContentEvent) buffer.write(event.text);
      if (event is ErrorEvent) return 'Bild konnte nicht gelesen werden.';
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? 'Auf dem Bild war nichts Eindeutiges zu sehen.' : text;
  }

  void _trimHistory() {
    // Keep the system prompt plus the last 24 turn messages.
    if (_history.length <= 25) return;
    final system = _history.first;
    final tail = _history.sublist(_history.length - 24);
    // A tool message must never lead, it would reference a dropped call.
    while (tail.isNotEmpty && tail.first['role'] == 'tool') {
      tail.removeAt(0);
    }
    _history
      ..clear()
      ..add(system)
      ..addAll(tail);
  }

  Future<String?> _accessToken() async {
    try {
      final token = SupabaseService.auth.currentSession?.accessToken;
      if (token == null || token.isEmpty) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Waits briefly for the session to exist.
  ///
  /// The assist gesture can start the process cold: `main()` kicks Supabase off
  /// without awaiting it, so the very first read races the restore of the
  /// stored session. Failing with "not signed in" there would be a lie the user
  /// could only fix by opening the app once.
  Future<String?> _awaitAccessToken() async {
    const attempts = 20;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final token = await _accessToken();
      if (token != null) return token;
      if (_disposed) return null;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  String _systemPrompt() {
    final now = DateTime.now();
    return '''
Du bist der Assistent von Chuk Chat auf einem Android-Telefon. Du liegst als
Fläche über der App, die der Nutzer gerade offen hat.

Regeln:
- Antworte auf Deutsch und kurz. Die Antwort wird gelesen, nicht vorgelesen.
- Markdown ist erlaubt und erwünscht, solange es die Antwort schneller lesbar
  macht: **fett** für die eine Zahl oder den einen Namen, auf den es ankommt,
  eine kurze Liste für mehrere gleichartige Dinge, `code` für Befehle und
  Werte. Keine Überschriften, keine Tabellen, keine Absätze zum Aufwärmen.
- Höchstens drei Sätze oder fünf Listenpunkte.
- Wenn der Nutzer sich auf "das hier", "diese Seite" oder den Bildschirm bezieht,
  rufe zuerst read_screen auf.
- Für Bilder, Karten oder Layout-Fragen nutze look_at_screen.
- Soll irgendwo hin navigiert werden, nutze open_maps. Das öffnet die Karten-App
  des Geräts. Nenne den Ort danach nicht noch einmal vor.
- Für Orte und Lokale in der Nähe zuerst get_location, dann search_places oder
  search_restaurants. Die Liste sieht der Nutzer, zähle sie nicht auf: sage, wie
  viele es sind und nenne höchstens den besten Treffer.
- Für Fakten, Preise und Nachrichten nutze web_search.
- Führe Geräteaktionen nur aus, wenn der Nutzer sie verlangt.
- Erfinde keine Werte. Wenn ein Werkzeug einen Fehler liefert, sage das kurz.

Aktuelle Zeit: ${now.toIso8601String()}.
''';
  }

  static Map<String, dynamic> _decodeArguments(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (error) {
      if (kDebugMode) {
        // The arguments carry user content — an SMS body, a contact name, a
        // search query. Length only.
        debugPrint(
          'assistant tool arguments are not valid JSON '
          '(${trimmed.length} chars)',
        );
      }
    }
    return <String, dynamic>{};
  }

  static String _humanError(Object error) {
    if (error is TranscriptionException) {
      return 'Sprache konnte nicht erkannt werden: ${error.message}';
    }
    return error.toString();
  }

  void _set(AssistantPhase phase) {
    _phase = phase;
    if (phase != AssistantPhase.error) _error = '';
    _notify();
  }

  void _fail(String message) {
    _error = message;
    _phase = AssistantPhase.error;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_microphone?.dispose());
    _microphone = null;
    try {
      unawaited(AssistantBridge.stopVoiceService());
    } catch (_) {
      // The channel is gone on a platform without the native side.
    }
    super.dispose();
  }
}

@immutable
class _AssistantPass {
  const _AssistantPass({
    required this.content,
    required this.toolCalls,
    this.error,
  });

  final String content;
  final List<NativeToolCall> toolCalls;
  final String? error;
}
