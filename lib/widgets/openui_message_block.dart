// lib/widgets/openui_message_block.dart
//
// One OpenUI program inside an assistant answer: the view, the chat's
// action handler, and a small memory that keeps form values and $state
// when the list drops and rebuilds the message (scroll, stream ticks).
// See docs/OPENUI.md, "Chat integration".

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:openui/openui.dart' show kOpenUrlSchemes, safeOpenUrl;
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/openui/openui.dart';

/// The URL schemes an OpenUI `@OpenUrl` may open. The renderer uses
/// the same set, so both filter alike.
const Set<String> kOpenUiUrlSchemes = kOpenUrlSchemes;

/// [url] as a [Uri] when the chat may open it, else `null`.
///
/// Only http, https, mailto and tel. A web link must have a host. Other
/// schemes (`javascript:`, `file:`, `intent:`, app links) are refused,
/// because the model writes the URL. The rule is the renderer's
/// [safeOpenUrl].
Uri? safeOpenUiUri(String url) => safeOpenUrl(url);

/// Opens [uri] outside the app.
Future<void> _launchExternal(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object catch (e) {
    if (kDebugMode) debugPrint('OpenUI openUrl failed: ${e.runtimeType}');
  }
}

/// The chat's [OpenUiActionHandler].
///
/// - [sendToAssistant] composes one plain-text message
///   ([OpenUiActionHandler.composeMessage]) and gives it to [onSend].
///   Without [onSend] the view cannot talk to the assistant.
/// - [openUrl] opens only the URLs [safeOpenUiUri] accepts.
class ChatOpenUiActionHandler extends OpenUiActionHandler {
  /// Creates the handler.
  const ChatOpenUiActionHandler({this.onSend, this.onState, this.launch});

  /// Sends a user message in the same chat.
  final ValueChanged<String>? onSend;

  /// Receives each `$variable` snapshot.
  final ValueChanged<Map<String, Object?>>? onState;

  /// Opens a URL. Defaults to url_launcher, external application.
  final Future<void> Function(Uri uri)? launch;

  @override
  void sendToAssistant(
    String text, {
    String? context,
    Map<String, Object?>? formValues,
  }) {
    final send = onSend;
    if (send == null) return;
    final message = OpenUiActionHandler.composeMessage(
      text,
      context: context,
      formValues: formValues,
    );
    if (message.trim().isEmpty) return;
    send(message);
  }

  @override
  void openUrl(String url) {
    final uri = safeOpenUiUri(url);
    if (uri == null) return;
    unawaited((launch ?? _launchExternal)(uri));
  }

  @override
  void onStateChanged(Map<String, Object?> state) => onState?.call(state);
}

/// What one program of one message keeps between rebuilds.
class OpenUiViewMemoryEntry {
  /// The form values, by form name.
  final OpenUiForms forms = OpenUiForms();

  /// The last `$variable` snapshot, or `null`.
  Map<String, Object?>? state;
}

/// Form values and `$state` of the OpenUI programs in the chat, keyed by
/// message id and program index.
///
/// The chat list builds only the rows on screen. A program that scrolls
/// out and back in is a new widget; this memory gives it its old values.
/// It keeps the [capacity] most recently used entries. A dropped entry is
/// not disposed, because a view on screen may still use it.
class OpenUiViewMemory {
  OpenUiViewMemory._();

  /// How many programs the memory keeps.
  static const int capacity = 64;

  static final LinkedHashMap<String, OpenUiViewMemoryEntry> _entries =
      LinkedHashMap<String, OpenUiViewMemoryEntry>();

  /// The entry for [key]; created on first use.
  static OpenUiViewMemoryEntry entry(String key) {
    final existing = _entries.remove(key);
    final entry = existing ?? OpenUiViewMemoryEntry();
    _entries[key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    return entry;
  }

  /// The number of entries. For tests.
  @visibleForTesting
  static int get length => _entries.length;

  /// Forgets every entry. For tests.
  @visibleForTesting
  static void clear() => _entries.clear();
}

/// One OpenUI program in an assistant answer.
///
/// [memoryKey] is `<message id>#<program index>`. With a key, form values
/// and `$state` survive a rebuild of the message. [onSendMessage] sends a
/// user message in the same chat; `null` makes buttons that talk to the
/// assistant do nothing (links still open).
class OpenUiMessageBlock extends StatelessWidget {
  /// Creates the block.
  const OpenUiMessageBlock({
    required this.source,
    required this.isStreaming,
    this.memoryKey,
    this.onSendMessage,
    this.launch,
    super.key,
  });

  /// The program source (the fence body).
  final String source;

  /// Whether the program is still streaming.
  final bool isStreaming;

  /// The memory key, or `null` for no memory.
  final String? memoryKey;

  /// Sends a user message in the same chat.
  final ValueChanged<String>? onSendMessage;

  /// Opens a URL. For tests; defaults to url_launcher.
  final Future<void> Function(Uri uri)? launch;

  @override
  Widget build(BuildContext context) {
    final key = memoryKey;
    final memory = key == null ? null : OpenUiViewMemory.entry(key);
    return OpenUiView(
      source: source,
      isStreaming: isStreaming,
      forms: memory?.forms,
      initialState: memory?.state,
      actionHandler: ChatOpenUiActionHandler(
        onSend: onSendMessage,
        onState: memory == null ? null : (state) => memory.state = state,
        launch: launch,
      ),
    );
  }
}
