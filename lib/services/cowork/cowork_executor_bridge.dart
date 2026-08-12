import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/cowork/cowork_demo_server.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

/// Drives the app's **real** chat/tool loop headlessly from a message injected
/// by the [CoworkDemoServer]'s phone page, and mirrors the run back to it.
///
/// This is the local CoWork demo executor. It reuses — never forks — the
/// production tool loop: a fresh [ToolLoopSession] from the shared
/// [ToolCallHandler], the same `sendStreamingChat` transport over the already
/// authenticated `MultiplexSession`, and the same `processAssistantResponse`
/// round recursion the desktop send logic runs. The only thing that differs is
/// where the message comes from (the phone page) and where the output goes
/// (the phone page), so laptop-native tools such as `run_command` execute on
/// this machine exactly as they would in a normal chat turn.
///
/// The E2E crypto envelope (`cowork_frame*.dart`) is deliberately not on this
/// path: the transport here is a `127.0.0.1` loopback socket, so there is no
/// untrusted hop to protect. The production phone/relay path is where those
/// frames belong.
class CoworkExecutorBridge {
  CoworkExecutorBridge({CoworkDemoServer? server, ToolCallHandler? handler})
    : _server = server ?? CoworkDemoServer(),
      _injectedHandler = handler;

  /// Process-wide singleton so a surface can start/stop the demo without
  /// spinning up a second server on another port.
  static final CoworkExecutorBridge instance = CoworkExecutorBridge();

  final CoworkDemoServer _server;

  /// The handler is built lazily on the first injected message, never at
  /// construction: `ToolCallHandler()` kicks off platform-channel work
  /// (shared_preferences, skills) that must not run just to start the loopback
  /// server — and would throw late in a widget-less test.
  final ToolCallHandler? _injectedHandler;
  ToolCallHandler? _handlerCache;
  ToolCallHandler get _handler =>
      _handlerCache ??= (_injectedHandler ?? ToolCallHandler());

  StreamSubscription<String>? _sub;

  /// Running conversation, so multiple injected messages form one thread.
  final List<Map<String, dynamic>> _history = <Map<String, dynamic>>[];

  bool _busy = false;
  int _toolCallsSeen = 0;
  final Set<String> _resultsPushed = <String>{};
  Uri? _url;

  /// Fixed chat id: the demo is a single ongoing session.
  static const String _chatId = 'cowork-demo';

  CoworkDemoServer get server => _server;
  bool get isRunning => _server.isRunning;

  /// The `http://127.0.0.1:<port>` phone-page URL once started, else null.
  Uri? get url => _url;

  /// Start the loopback server and begin listening for injected messages.
  /// Idempotent: a second call while already running returns the same URL, so
  /// a UI can re-enter the CoWork surface without spawning a second server.
  /// Returns the URL to open as the phone page.
  Future<Uri> start({int port = 0}) async {
    if (_server.isRunning && _url != null) {
      return _url!;
    }
    final uri = await _server.start(port: port);
    _url = uri;
    _sub ??= _server.injectedMessages.listen(_onInjected);
    return uri;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _server.stop();
    _url = null;
  }

  Future<void> _onInjected(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    if (_busy) {
      _server.pushError(
        'The laptop agent is still working on the previous task. '
        'Wait for it to finish.',
      );
      return;
    }
    _busy = true;
    _toolCallsSeen = 0;
    _resultsPushed.clear();

    try {
      final token =
          (await SupabaseService.refreshSession())?.accessToken ??
          SupabaseService.auth.currentSession?.accessToken;
      if (token == null || token.isEmpty) {
        _server.pushError(
          'Not signed in on the laptop. Sign in to chuk_chat first.',
        );
        return;
      }

      final modelId = await UserPreferencesService.forceLoadSelectedModel();
      if (modelId == null || modelId.isEmpty) {
        _server.pushError('No model is selected on the laptop.');
        return;
      }
      final providerSlug =
          await ChatUiHelpers.loadProviderSlugForModel(modelId) ?? 'openai';

      final session = _handler.createSession(
        initialUserMessage: trimmed,
        history: _history,
        accessToken: token,
        discoveryContextKey: _chatId,
        modelId: modelId,
      );
      final systemPrompt = await _handler.buildInitialSystemPrompt(session);

      final answer = await _runPass(
        session: session,
        message: trimmed,
        history: List<Map<String, dynamic>>.from(_history),
        systemPrompt: systemPrompt,
        modelId: modelId,
        providerSlug: providerSlug,
        token: token,
      );

      // null => a round already reported an error to the phone; don't append a
      // partial turn to the thread and don't send a phantom "done" after it.
      if (answer == null) return;

      _history.add(<String, dynamic>{'role': 'user', 'content': trimmed});
      _history.add(<String, dynamic>{'role': 'assistant', 'content': answer});

      _server.pushDone();
    } catch (e) {
      // Never swallow: the phone must see the failure, not a silent hang.
      _server.pushError('Task failed on the laptop: $e');
      if (kDebugMode) {
        debugPrint('[CoworkExecutorBridge] injected task failed: $e');
      }
    } finally {
      _busy = false;
    }
  }

  /// One round of the tool loop. Streams displayable text to the phone,
  /// emits tool-activity chips, and recurses while the loop wants to continue.
  /// Returns the final assistant text, or null if a round hit a stream error
  /// (already pushed to the phone) so the caller skips finalisation.
  Future<String?> _runPass({
    required ToolLoopSession session,
    required String message,
    required List<Map<String, dynamic>> history,
    required String? systemPrompt,
    required String modelId,
    required String providerSlug,
    required String token,
    int pass = 0,
  }) async {
    final stream = WebSocketChatService.sendStreamingChat(
      accessToken: token,
      message: message,
      modelId: modelId,
      providerSlug: providerSlug,
      history: history,
      systemPrompt: systemPrompt,
      maxTokens: 2048,
      reasoningEffort: 'none',
      chatId: _chatId,
    );

    final content = StringBuffer();
    final reasoning = StringBuffer();
    Map<String, dynamic> meta = <String, dynamic>{};
    var streamedDisplayLen = 0;

    await for (final ev in stream) {
      switch (ev) {
        case ContentEvent(:final text):
          content.write(text);
          // Only stream the part the user should read: tool-call markup is
          // stripped, matching how the desktop UI renders a working round.
          final display = stripToolCallBlocksForDisplay(content.toString());
          if (display.length > streamedDisplayLen) {
            _server.pushDelta(display.substring(streamedDisplayLen));
            streamedDisplayLen = display.length;
          }
        case ReasoningEvent(:final text):
          reasoning.write(text);
        case MetaEvent(meta: final m):
          meta = m;
        case ErrorEvent(:final message):
          _server.pushError(message);
          return null;
        case UsageEvent():
        case TpsEvent():
        case DoneEvent():
          break;
      }
    }

    final loopResult = await _handler.processAssistantResponse(
      session: session,
      content: content.toString(),
      reasoning: reasoning.toString(),
      turnSignals: ToolTurnSignals.fromMeta(meta),
      onToolCallsUpdated: (List<ToolCall> calls) {
        for (var i = _toolCallsSeen; i < calls.length; i++) {
          _server.pushToolCall(calls[i].name, _preview(calls[i].arguments));
        }
        if (calls.length > _toolCallsSeen) {
          _toolCallsSeen = calls.length;
        }
      },
    );

    for (final call in loopResult.toolCalls) {
      final result = call.result;
      if (result != null && result.isNotEmpty && _resultsPushed.add(call.id)) {
        _server.pushToolResult(call.name, _preview(result));
      }
    }

    if (loopResult.shouldContinue && loopResult.nextStep != null) {
      final next = loopResult.nextStep!;
      return _runPass(
        session: session,
        message: next.message,
        history: next.history,
        systemPrompt: next.systemPrompt,
        modelId: modelId,
        providerSlug: providerSlug,
        token: token,
        pass: pass + 1,
      );
    }

    final finalContent = loopResult.finalContent ?? content.toString();
    final finalDisplay = stripToolCallBlocksForDisplay(finalContent);
    if (finalDisplay.length > streamedDisplayLen) {
      _server.pushDelta(finalDisplay.substring(streamedDisplayLen));
    }
    return finalContent;
  }

  String _preview(Object? value, {int max = 200}) {
    final s = value is String ? value : value.toString();
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }
}
