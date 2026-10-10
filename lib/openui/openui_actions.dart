// The bridge between an OpenUI view and the host app: the action
// handler the host implements, the per-view form state, and the
// inherited scope the components read. See docs/OPENUI.md, "Actions".

import 'dart:convert';

import 'package:flutter/widgets.dart';

/// What the host app does when an OpenUI view acts.
///
/// - [sendToAssistant]: a `@ToAssistant` step, an object-literal
///   `continue_conversation` action, a `FollowUpItem`, or a `Button`
///   without an action. [context] is the optional extra context of the
///   step. [formValues] holds the values of the enclosing `Form`, when
///   the component sits in one.
/// - [openUrl]: an `@OpenUrl` step or an `open_url` action.
/// - [onStateChanged]: optional; every `$variable` write, with the full
///   store snapshot (for persistence).
abstract class OpenUiActionHandler {
  /// Const constructor for subclasses.
  const OpenUiActionHandler();

  /// Sends a user message to the assistant.
  void sendToAssistant(
    String text, {
    String? context,
    Map<String, Object?>? formValues,
  });

  /// Opens [url] outside the view.
  void openUrl(String url);

  /// Called after each `$variable` write. The default does nothing.
  void onStateChanged(Map<String, Object?> state) {}

  /// Builds one plain-text chat message from the three parts of
  /// [sendToAssistant]. Hosts that send text can use it as is:
  ///
  /// ```text
  /// Submit
  ///
  /// Context: plan the trip
  ///
  /// Form "contact":
  /// - name: Ada
  /// - email: ada@example.com
  /// ```
  static String composeMessage(
    String text, {
    String? context,
    Map<String, Object?>? formValues,
    String? formName,
  }) {
    final out = StringBuffer(text.trim());
    if (context != null && context.trim().isNotEmpty) {
      out.write('\n\nContext: ${context.trim()}');
    }
    if (formValues != null && formValues.isNotEmpty) {
      out.write(formName == null ? '\n\nForm:' : '\n\nForm "$formName":');
      for (final entry in formValues.entries) {
        out.write('\n- ${entry.key}: ${_valueText(entry.value)}');
      }
    }
    return out.toString();
  }

  static String _valueText(Object? v) {
    if (v == null) return '';
    if (v is String || v is num || v is bool) return '$v';
    try {
      return jsonEncode(v);
    } on Object {
      return '$v';
    }
  }
}

/// An [OpenUiActionHandler] made from callbacks. Missing callbacks do
/// nothing.
class CallbackOpenUiActionHandler extends OpenUiActionHandler {
  /// Creates a handler from callbacks.
  const CallbackOpenUiActionHandler({
    this.onSendToAssistant,
    this.onOpenUrl,
    this.onState,
  });

  /// Receives [sendToAssistant] calls.
  final void Function(
    String text,
    String? context,
    Map<String, Object?>? formValues,
  )?
  onSendToAssistant;

  /// Receives [openUrl] calls.
  final void Function(String url)? onOpenUrl;

  /// Receives [onStateChanged] calls.
  final void Function(Map<String, Object?> state)? onState;

  @override
  void sendToAssistant(
    String text, {
    String? context,
    Map<String, Object?>? formValues,
  }) => onSendToAssistant?.call(text, context, formValues);

  @override
  void openUrl(String url) => onOpenUrl?.call(url);

  @override
  void onStateChanged(Map<String, Object?> state) => onState?.call(state);
}

/// The values of one OpenUI `Form`, keyed by field name.
///
/// Field components write their value here on every change
/// ([setValue]); a submit reads [values]. The state lives in the
/// [OpenUiView], so it survives the rebuilds of a stream.
class OpenUiFormState extends ChangeNotifier {
  /// Creates the state of the form called [name].
  OpenUiFormState(this.name);

  /// The form name (first argument of `Form`).
  final String name;

  final Map<String, Object?> _values = <String, Object?>{};

  /// A copy of the current values.
  Map<String, Object?> get values => Map<String, Object?>.unmodifiable(_values);

  /// The value of [field], or `null`.
  Object? value(String field) => _values[field];

  /// Whether [field] has a value (also a `null` one).
  bool hasValue(String field) => _values.containsKey(field);

  /// Stores the value of [field] and notifies listeners on a change.
  void setValue(String field, Object? value) {
    if (_values.containsKey(field) && _values[field] == value) return;
    _values[field] = value;
    notifyListeners();
  }

  /// Clears every value.
  void reset() {
    if (_values.isEmpty) return;
    _values.clear();
    notifyListeners();
  }
}

/// All forms of one view, by name.
class OpenUiForms {
  final Map<String, OpenUiFormState> _forms = <String, OpenUiFormState>{};

  /// The form whose action runs now (see [OpenUiScope.runWithForm]),
  /// or `null`.
  String? activeFormName;

  /// The state of the form called [name] (created on first use).
  OpenUiFormState form(String name) =>
      _forms.putIfAbsent(name, () => OpenUiFormState(name));

  /// The current values of [name], or `null` when there is no such form.
  Map<String, Object?>? valuesOf(String? name) =>
      name == null ? null : _forms[name]?.values;

  /// Releases every form state.
  void dispose() {
    for (final f in _forms.values) {
      f.dispose();
    }
    _forms.clear();
  }
}

/// Marks a subtree as the body of the `Form` called [formName].
///
/// The `Form` component wraps its fields and buttons in it. Fields find
/// their state with [formOf]; actions find the form with [maybeNameOf].
class OpenUiFormScope extends InheritedWidget {
  /// Creates the scope of the form called [formName].
  const OpenUiFormScope({
    required this.formName,
    required super.child,
    super.key,
  });

  /// The form name.
  final String formName;

  /// The name of the enclosing form, or `null`.
  static String? maybeNameOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<OpenUiFormScope>()?.formName;

  /// The state of the enclosing form, or `null` outside a form or an
  /// [OpenUiView].
  static OpenUiFormState? formOf(BuildContext context) {
    final name = maybeNameOf(context);
    if (name == null) return null;
    return OpenUiScope.maybeOf(context)?.forms.form(name);
  }

  @override
  bool updateShouldNotify(OpenUiFormScope oldWidget) =>
      oldWidget.formName != formName;
}

/// Per-view services for components: the host handler, the forms, and
/// the stream state. [OpenUiView] installs it above the renderer.
class OpenUiScope extends InheritedWidget {
  /// Creates the scope. Normally only [OpenUiView] does this.
  const OpenUiScope({
    required this.forms,
    required this.isStreaming,
    required super.child,
    this.handler,
    super.key,
  });

  /// The host handler, or `null` when the view is read-only.
  final OpenUiActionHandler? handler;

  /// The form states of this view.
  final OpenUiForms forms;

  /// Whether the source is still streaming.
  final bool isStreaming;

  /// Runs [body] with [formName] as the active form, so a message to
  /// the assistant carries that form's values.
  Future<void> runWithForm(
    String? formName,
    Future<void> Function() body,
  ) async {
    final previous = forms.activeFormName;
    forms.activeFormName = formName;
    try {
      await body();
    } finally {
      forms.activeFormName = previous;
    }
  }

  /// The nearest scope, or `null` outside an [OpenUiView].
  static OpenUiScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OpenUiScope>();

  @override
  bool updateShouldNotify(OpenUiScope oldWidget) =>
      oldWidget.handler != handler ||
      oldWidget.forms != forms ||
      oldWidget.isStreaming != isStreaming;
}
