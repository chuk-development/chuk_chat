import 'package:flutter/foundation.dart';

/// Immutable snapshot of the assistant placeholder's live streaming body,
/// pushed on every coalesced (~30fps) token flush during a send.
///
/// The chat list wraps ONLY the streaming bubble in a
/// `ValueListenableBuilder<StreamingLive?>` on [ChatRuntime.streamingLive], so
/// per-token updates rebuild just that one bubble instead of running a
/// screen-wide `setState` (which previously rebuilt every visible bubble, the
/// composer, and the overlays ~30 times per second).
@immutable
class StreamingLive {
  const StreamingLive({
    required this.index,
    required this.text,
    required this.reasoning,
  });

  /// Index of the placeholder message in the runtime's message list.
  final int index;

  /// Current accumulated display text for the answer body.
  final String text;

  /// Current accumulated reasoning text.
  final String reasoning;

  @override
  bool operator ==(Object other) =>
      other is StreamingLive &&
      other.index == index &&
      other.text == text &&
      other.reasoning == reasoning;

  @override
  int get hashCode => Object.hash(index, text, reasoning);
}

/// Per-chat in-memory live state.
///
/// Each open chat in the UI owns one [ChatRuntime]. The widget tree binds
/// to its [messages], [isSending], and [isStreaming] notifiers so that:
///
/// * switching chats only rebinds the visible view — the runtime, its
///   message list, and any in-flight stream live on in the registry
/// * sending a message in chat B while chat A is still streaming does not
///   interfere with A — each runtime is independent
/// * the Send / Stop button always reflects the visible chat's state
///   because the button binds to [isStreaming] (and calls
///   [cancelHandler]), both of which are per-runtime.
class ChatRuntime {
  ChatRuntime({required this.chatId, List<Map<String, String>>? initial})
    : messages = ValueNotifier<List<Map<String, String>>>(
        List<Map<String, String>>.from(initial ?? const []),
      );

  final String chatId;

  /// Live message list. Mutations must go through [setMessages],
  /// [appendMessage], [updateMessage], or [removeMessageAt] so the
  /// notifier fires and listeners rebuild.
  final ValueNotifier<List<Map<String, String>>> messages;

  /// True from the moment the user presses Send until the stream
  /// terminates (success, error, or cancel).
  final ValueNotifier<bool> isSending = ValueNotifier<bool>(false);

  /// True while a server stream is actively delivering tokens.
  /// Strict subset of [isSending] in time: send turns on first; stream
  /// turns on after the request handshake; both turn off on completion.
  final ValueNotifier<bool> isStreaming = ValueNotifier<bool>(false);

  /// Live body of the streaming placeholder, updated per token flush. The
  /// chat list scopes per-token rebuilds to the single streaming bubble by
  /// listening to this instead of calling `setState` on the whole screen.
  /// Null when no token has been pushed for the current turn.
  final ValueNotifier<StreamingLive?> streamingLive =
      ValueNotifier<StreamingLive?>(null);

  /// Index of the assistant placeholder message currently being filled
  /// by the active stream. Null when no stream is in flight.
  int? placeholderIndex;

  /// Selected model id for the in-flight turn (captured at send time).
  String? modelId;

  /// Provider slug for the in-flight turn.
  String? provider;

  /// Bound at stream start by the send pipeline. The Stop button calls
  /// this directly so it always cancels *this* chat's stream regardless
  /// of which chat the user is currently viewing.
  VoidCallback? cancelHandler;

  /// Last time this runtime had user activity (send, switch in). Used by
  /// the registry's LRU eviction.
  DateTime lastTouchedAt = DateTime.now();

  /// True if the runtime has nothing in flight and is safe to evict.
  bool get isIdle => !isSending.value && !isStreaming.value;

  void touch() {
    lastTouchedAt = DateTime.now();
  }

  /// Replace the entire message list. Use when seeding the runtime from
  /// the cache or applying a recovered background snapshot.
  void setMessages(List<Map<String, String>> next) {
    messages.value = List<Map<String, String>>.from(next);
  }

  /// Append a message and return its index.
  int appendMessage(Map<String, String> message) {
    final updated = List<Map<String, String>>.from(messages.value)
      ..add(Map<String, String>.from(message));
    messages.value = updated;
    return updated.length - 1;
  }

  /// Update one field of a message in place. No-op if [index] is out of
  /// range or the runtime is being torn down.
  void updateMessage(int index, Map<String, String> patch) {
    final current = messages.value;
    if (index < 0 || index >= current.length) return;
    final updated = List<Map<String, String>>.from(current);
    final merged = Map<String, String>.from(updated[index])..addAll(patch);
    updated[index] = merged;
    messages.value = updated;
  }


  void removeMessageAt(int index) {
    final current = messages.value;
    if (index < 0 || index >= current.length) return;
    final updated = List<Map<String, String>>.from(current)..removeAt(index);
    messages.value = updated;
  }

  /// Mark the start of a send: user message + assistant placeholder are
  /// already in [messages]; record the placeholder index and flip flags.
  void beginStream({required int placeholderIndex, required String modelId, String? provider, VoidCallback? cancelHandler}) {
    this.placeholderIndex = placeholderIndex;
    this.modelId = modelId;
    this.provider = provider;
    this.cancelHandler = cancelHandler;
    isSending.value = true;
    isStreaming.value = true;
    touch();
  }

  /// Push the latest streamed body for the placeholder at [index]. Scoped
  /// per-token updates read this via a `ValueListenableBuilder`; the
  /// notifier only fires when the value actually changed (see [StreamingLive]
  /// equality), so identical re-flushes are free.
  void pushStreamingText({
    required int index,
    required String text,
    required String reasoning,
  }) {
    streamingLive.value = StreamingLive(
      index: index,
      text: text,
      reasoning: reasoning,
    );
  }

  /// Mark the end of a send (any outcome: complete, error, cancel).
  void endStream() {
    placeholderIndex = null;
    cancelHandler = null;
    isSending.value = false;
    isStreaming.value = false;
    streamingLive.value = null;
    touch();
  }

  void dispose() {
    messages.dispose();
    isSending.dispose();
    isStreaming.dispose();
    streamingLive.dispose();
  }
}
