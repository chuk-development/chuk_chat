// OpenUI Input and TextArea: one text field widget for both.
//
// The field owns its controller and focus node. The text goes to the
// form state (and the binding) on every change. Rules: a change hides
// the error, leaving the field (blur) checks the rules, a submit checks
// all fields. That is the upstream timing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/openui/components/forms_buttons/field.dart';
import 'package:chuk_chat/openui/components/forms_buttons/form.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';

/// Builds `Input(name, placeholder?, type?, rules?, value?)`.
Widget buildOpenUiInput(BuildContext context, OpenUiProps props) =>
    OpenUiTextFieldView(props: props, multiline: false);

/// Builds `TextArea(name, placeholder?, rows?, rules?, value?)`.
Widget buildOpenUiTextArea(BuildContext context, OpenUiProps props) =>
    OpenUiTextFieldView(props: props, multiline: true);

/// The text field of `Input` and `TextArea`.
class OpenUiTextFieldView extends StatefulWidget {
  /// Creates a text field from the props of an `Input` or `TextArea`.
  const OpenUiTextFieldView({
    required this.props,
    required this.multiline,
    super.key,
  });

  /// The component props.
  final OpenUiProps props;

  /// `TextArea` when true.
  final bool multiline;

  @override
  State<OpenUiTextFieldView> createState() => _OpenUiTextFieldViewState();
}

class _OpenUiTextFieldViewState extends State<OpenUiTextFieldView>
    with OpenUiFieldStateMixin<OpenUiTextFieldView> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  OpenUiField? _field;
  bool _seeded = false;
  bool _obscured = true;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    final field = _field;
    if (field == null || !mounted) return;
    if (_focus.hasFocus) {
      field.clearError();
    } else {
      field.validate(_controller.text);
    }
  }

  static String _asText(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is num) {
      return v == v.roundToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : '$v';
    }
    if (v is bool) return '$v';
    return '';
  }

  /// Keeps the controller in line with the stored value. The first
  /// build takes the stored value. Later, only a change from outside
  /// (a `@Set` on the binding, a form reset) replaces the text.
  void _syncController(OpenUiField field) {
    final stored = _asText(field.stored);
    if (!_seeded) {
      _seeded = true;
      if (_controller.text != stored) {
        _controller.value = TextEditingValue(
          text: stored,
          selection: TextSelection.collapsed(offset: stored.length),
        );
      }
      return;
    }
    if (field.binding == null && field.form == null) return;
    if (stored == _controller.text) return;
    // The store is behind the controller while the user types (both
    // writes happen in the same callback), so only take outside
    // changes when the field is not being edited.
    if (_focus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.text == stored) return;
      _controller.value = TextEditingValue(
        text: stored,
        selection: TextSelection.collapsed(offset: stored.length),
      );
    });
  }

  void _onChanged(String text) {
    final field = _field;
    if (field == null) return;
    field.write(context, text);
    field.clearError();
  }

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final field = resolveField(context, props);
    _field = field;
    _syncController(field);

    final t = OpenUiTheme.of(context);
    final type = widget.multiline
        ? 'text'
        : props.choice('type', fallback: 'text');
    final password = type == 'password';
    final rows = widget.multiline
        ? props.integer('rows', fallback: 3).clamp(1, 20)
        : 1;
    final placeholder = props.string('placeholder');

    final (TextInputType keyboard, List<String> hints) = switch (type) {
      'email' => (TextInputType.emailAddress, <String>[AutofillHints.email]),
      'number' => (
        const TextInputType.numberWithOptions(decimal: true, signed: true),
        const <String>[],
      ),
      'url' => (TextInputType.url, <String>[AutofillHints.url]),
      'password' => (
        TextInputType.visiblePassword,
        <String>[AutofillHints.password],
      ),
      _ => (
        widget.multiline ? TextInputType.multiline : TextInputType.text,
        const <String>[],
      ),
    };

    Widget? suffix;
    if (password) {
      suffix = Semantics(
        button: true,
        label: _obscured
            ? openUiStrings(context).openUiShowPassword
            : openUiStrings(context).openUiHidePassword,
        child: InkResponse(
          onTap: () => setState(() => _obscured = !_obscured),
          radius: 20,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: HugeIcon(
                _obscured ? HugeIcons.view : HugeIcons.viewOff,
                size: 18,
                color: t.mutedColor,
              ),
            ),
          ),
        ),
      );
    }

    final style = t.bodyStyle.copyWith(fontSize: 15, height: 1.35);
    return TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: field.enabled,
      readOnly: !field.enabled,
      keyboardType: keyboard,
      autofillHints: field.enabled ? hints : null,
      obscureText: password && _obscured,
      enableSuggestions: !password && type != 'email' && type != 'url',
      autocorrect: type == 'text' && !password,
      minLines: widget.multiline ? rows : 1,
      maxLines: widget.multiline ? (rows < 12 ? 12 : rows) : 1,
      textInputAction: widget.multiline
          ? TextInputAction.newline
          : TextInputAction.next,
      inputFormatters: type == 'number'
          ? <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
            ]
          : null,
      style: style,
      cursorColor: t.accent,
      decoration: openUiFieldDecoration(
        context,
        hint: placeholder,
        hasError: field.error != null,
        suffixIcon: suffix,
      ),
      onChanged: _onChanged,
    );
  }
}
