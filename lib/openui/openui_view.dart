// The widget that shows one OpenUI Lang program in chuk_chat's design.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/openui_actions.dart';
import 'package:chuk_chat/openui/openui_library.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';

/// Renders an OpenUI Lang program as native widgets.
///
/// - [source] is the program, or the text of a ```` ```openui-lang ````
///   fence, or a whole answer with prose around fences (the prose is
///   dropped). It may be a partial stream: pass the text so far and
///   [isStreaming] true; each new text re-renders.
/// - While streaming, an incomplete or unknown trailing statement
///   draws nothing.
/// - After the stream ends, a small, calm error line shows only when
///   nothing at all could be rendered ([failureText]).
/// - It never throws.
class OpenUiView extends StatefulWidget {
  /// Creates a view.
  const OpenUiView({
    required this.source,
    this.isStreaming = false,
    this.actionHandler,
    this.library,
    this.tools,
    this.initialState,
    this.onError,
    this.forms,
    super.key,
  });

  /// The OpenUI Lang source (complete or partial).
  final String source;

  /// Whether [source] is still growing.
  final bool isStreaming;

  /// Receives messages to the assistant, URLs to open and state
  /// changes. `null` makes the view read-only.
  final OpenUiActionHandler? actionHandler;

  /// The component library. Defaults to [chukOpenUiLibrary].
  final OpenUiLibrary? library;

  /// Executors for `Query`/`Mutation` tools, keyed by tool name.
  /// Without an executor, a `Query` shows its defaults.
  final Map<String, ToolExecutor>? tools;

  /// Initial `$variable` values (keys with the `$`), for example a
  /// snapshot saved from [OpenUiActionHandler.onStateChanged].
  final Map<String, Object?>? initialState;

  /// Receives the renderer's errors (unknown components, failed
  /// tools). For logs only; the view stays calm.
  final void Function(List<OpenUIError> errors)? onError;

  /// The form states, when the host keeps them outside the view (for
  /// example a chat that rebuilds the view after a scroll). The view does
  /// not dispose them. `null`: the view owns its forms.
  final OpenUiForms? forms;

  /// The English text of the error line. The line shows the app
  /// locale's text (`openUiViewFailed`), which is this in English.
  static const String failureText = 'This view could not be shown.';

  @override
  State<OpenUiView> createState() => _OpenUiViewState();
}

class _OpenUiViewState extends State<OpenUiView> {
  OpenUiForms? _ownForms;
  Map<String, ToolExecutor>? _toolsSource;
  ToolRegistry _toolRegistry = const ToolRegistry(executors: {});
  String? _checkedSource;
  OpenUiLibrary? _checkedLibrary;
  bool _checkedFailed = false;

  OpenUiForms get _forms => widget.forms ?? (_ownForms ??= OpenUiForms());

  @override
  void dispose() {
    _ownForms?.dispose();
    super.dispose();
  }

  ToolRegistry _tools() {
    final tools = widget.tools;
    if (!identical(tools, _toolsSource)) {
      _toolsSource = tools;
      _toolRegistry = ToolRegistry(
        executors: tools ?? const <String, ToolExecutor>{},
      );
    }
    return _toolRegistry;
  }

  /// Whether the finished [source] renders nothing at all.
  bool _nothingRenders(OpenUiLibrary library, String source) {
    if (identical(library, _checkedLibrary) && source == _checkedSource) {
      return _checkedFailed;
    }
    _checkedLibrary = library;
    _checkedSource = source;
    _checkedFailed = _computeNothingRenders(library, source);
    return _checkedFailed;
  }

  static bool _computeNothingRenders(OpenUiLibrary library, String source) {
    if (source.trim().isEmpty) return false;
    try {
      final result = createStreamingParser().set(source);
      final root = result.root;
      if (root == null) return true;
      final statements = <String, Statement>{
        for (final s in result.statements) s.name: s,
      };
      var expr = root.expression;
      for (var hops = 0; expr is Reference && hops < 16; hops++) {
        final next = statements[expr.name];
        if (next == null) return true;
        expr = next.expression;
      }
      if (expr is CompCall) return !library.contains(expr.type);
      return expr is NullLiteral || expr is Reference;
    } on Object {
      return true;
    }
  }

  void _onAction(ActionEvent event) {
    final handler = widget.actionHandler;
    if (handler == null) return;
    if (event.params['success'] == false) return;
    if (event.type == BuiltinActionType.continueConversation) {
      final message = event.humanFriendlyMessage;
      if (message == null || message.trim().isEmpty) return;
      final context = event.params['context'];
      handler.sendToAssistant(
        message,
        context: context is String ? context : null,
        formValues: _forms.valuesOf(_forms.activeFormName),
      );
    } else if (event.type == BuiltinActionType.openUrl) {
      final url = event.params['url'];
      if (url is String && url.isNotEmpty) handler.openUrl(url);
    }
  }

  void _onState(Map<String, Object?> state) {
    widget.actionHandler?.onStateChanged(state);
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library ?? chukOpenUiLibrary;
    if (!widget.isStreaming && _nothingRenders(library, widget.source)) {
      return const _FailureLine();
    }
    return OpenUiScope(
      forms: _forms,
      isStreaming: widget.isStreaming,
      handler: widget.actionHandler,
      // The app's icon theme again: OpenUI icons follow only the icon
      // themes their own components set.
      child: IconTheme(
        data: Theme.of(context).iconTheme,
        child: Renderer(
          response: widget.source,
          isStreaming: widget.isStreaming,
          library: library.definition,
          componentRegistry: library.registry,
          toolRegistry: _tools(),
          initialState: widget.initialState,
          onAction: _onAction,
          onStateUpdate: _onState,
          onError: widget.onError,
          errorBuilder: (_) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _FailureLine extends StatelessWidget {
  const _FailureLine();

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        openUiStrings(context).openUiViewFailed,
        style: t.captionStyle,
      ),
    );
  }
}
