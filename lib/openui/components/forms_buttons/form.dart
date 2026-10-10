// OpenUI Form, FormControl and Label, plus the look the fields share
// (the input decoration and the hint or error line).

import 'package:flutter/material.dart';

import 'package:chuk_chat/openui/components/forms_buttons/field.dart';
import 'package:chuk_chat/openui/components/forms_buttons/rules.dart';
import 'package:chuk_chat/openui/openui_actions.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';

/// Space between the fields of a form, and before its buttons.
const double kOpenUiFormGap = 16;

/// Space between a label and its field, and a field and its hint.
const double kOpenUiLabelGap = 6;

// ---------------------------------------------------------------------
// Form
// ---------------------------------------------------------------------

/// Builds `Form(name, buttons, fields?)`.
Widget buildOpenUiForm(BuildContext context, OpenUiProps props) {
  final name = props.string('name').trim();
  return OpenUiFormView(
    name: name.isEmpty ? 'form' : name,
    fields: props.children('fields'),
    buttons: props.children('buttons'),
  );
}

/// The body of a `Form`: the fields, then the buttons. It gives them
/// the form scope (values) and the validator (errors).
class OpenUiFormView extends StatefulWidget {
  /// Creates a form body.
  const OpenUiFormView({
    required this.name,
    required this.fields,
    required this.buttons,
    super.key,
  });

  /// The form name. The form state in the view is keyed by it.
  final String name;

  /// The rendered fields (normally `FormControl`s).
  final List<Widget> fields;

  /// The rendered buttons (a `Buttons` row or single `Button`s).
  final List<Widget> buttons;

  @override
  State<OpenUiFormView> createState() => _OpenUiFormViewState();
}

class _OpenUiFormViewState extends State<OpenUiFormView> {
  final OpenUiFormValidator _validator = OpenUiFormValidator();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Errors in the app language; English without app localizations.
    _validator.messages = OpenUiRuleMessages.of(openUiStrings(context));
  }

  @override
  void dispose() {
    _validator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final field in widget.fields) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: kOpenUiFormGap));
      }
      children.add(field);
    }
    if (widget.buttons.isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: kOpenUiFormGap + 4));
      }
      children.add(
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: widget.buttons.length == 1
              ? widget.buttons.first
              : Wrap(spacing: 8, runSpacing: 8, children: widget.buttons),
        ),
      );
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: OpenUiFormScope(
        formName: widget.name,
        child: OpenUiFormValidationScope(
          validator: _validator,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// FormControl and Label
// ---------------------------------------------------------------------

/// Builds `FormControl(label, input, hint?)`.
Widget buildOpenUiFormControl(BuildContext context, OpenUiProps props) {
  return OpenUiFormControlView(
    label: props.string('label'),
    hint: props.stringOrNull('hint'),
    input: props.child('input'),
  );
}

/// A label, one field, and a line under it: the error of the field, or
/// else the hint.
class OpenUiFormControlView extends StatefulWidget {
  /// Creates a form control.
  const OpenUiFormControlView({
    required this.label,
    this.hint,
    this.input,
    super.key,
  });

  /// The label text.
  final String label;

  /// The hint text, or `null`.
  final String? hint;

  /// The field. It may be absent while the program streams.
  final Widget? input;

  @override
  State<OpenUiFormControlView> createState() => _OpenUiFormControlViewState();
}

class _OpenUiFormControlViewState extends State<OpenUiFormControlView> {
  final OpenUiFieldSlot _slot = OpenUiFieldSlot();

  @override
  void dispose() {
    _slot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final validator = OpenUiFormValidationScope.of(context);
    return ListenableBuilder(
      listenable: _slot,
      builder: (context, _) {
        final name = _slot.name;
        final error = name == null ? null : validator?.errorOf(name);
        final hint = widget.hint?.trim();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.label.trim().isNotEmpty) ...<Widget>[
              OpenUiLabelText(widget.label, required: _slot.required),
              const SizedBox(height: kOpenUiLabelGap),
            ],
            if (widget.input != null)
              OpenUiFieldSlotScope(slot: _slot, child: widget.input!),
            if (error != null) ...<Widget>[
              const SizedBox(height: kOpenUiLabelGap),
              OpenUiFieldMessage(error, isError: true),
            ] else if (hint != null && hint.isNotEmpty) ...<Widget>[
              const SizedBox(height: kOpenUiLabelGap),
              OpenUiFieldMessage(hint),
            ],
          ],
        );
      },
    );
  }
}

/// Builds `Label(text)`.
Widget buildOpenUiLabel(BuildContext context, OpenUiProps props) {
  final text = props.string('text');
  if (text.trim().isEmpty) return const SizedBox.shrink();
  return OpenUiLabelText(text);
}

/// The label of a field. A required field gets a star after it.
class OpenUiLabelText extends StatelessWidget {
  /// Creates a label.
  const OpenUiLabelText(this.text, {this.required = false, super.key});

  /// The text.
  final String text;

  /// Whether to mark the field as required.
  final bool required;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final style = (t.text.labelLarge ?? const TextStyle()).copyWith(
      color: t.textColor,
      fontWeight: FontWeight.w600,
      fontSize: 14,
    );
    return Text.rich(
      TextSpan(
        text: text,
        children: <InlineSpan>[
          if (required)
            TextSpan(
              text: ' *',
              semanticsLabel: openUiStrings(context).openUiRequiredSuffix,
              style: TextStyle(color: t.danger),
            ),
        ],
      ),
      style: style,
    );
  }
}

/// The line under a field: a hint (muted) or an error (danger colour,
/// with an icon). The icon sits in a box one text line high, so it
/// centres on the first line.
class OpenUiFieldMessage extends StatelessWidget {
  /// Creates a hint or error line.
  const OpenUiFieldMessage(this.text, {this.isError = false, super.key});

  /// The text.
  final String text;

  /// Whether this is an error.
  final bool isError;

  static const double _fontSize = 12.5;
  static const double _lineHeight = 18;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final color = isError ? t.danger : t.mutedColor;
    final style = TextStyle(
      color: color,
      fontSize: _fontSize,
      height: _lineHeight / _fontSize,
      fontWeight: isError ? FontWeight.w500 : FontWeight.w400,
    );
    final message = Text(text, style: style);
    if (!isError) return message;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            height: _lineHeight,
            width: 14,
            child: Center(
              child: HugeIcon(HugeIcons.alertCircle, size: 14, color: color),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: message),
        ],
      ),
    );
  }
}

/// The input decoration of every OpenUI field: the app's filled field
/// look (`inputDecorationTheme`), with the error border when [hasError].
InputDecoration openUiFieldDecoration(
  BuildContext context, {
  String? hint,
  bool hasError = false,
  Widget? prefixIcon,
  Widget? suffixIcon,
  EdgeInsetsGeometry? contentPadding,
}) {
  final theme = Theme.of(context).inputDecorationTheme;
  final t = OpenUiTheme.of(context);
  return InputDecoration(
    hintText: hint == null || hint.isEmpty ? null : hint,
    hintMaxLines: 1,
    isDense: true,
    filled: true,
    fillColor: t.sunkColor,
    contentPadding:
        contentPadding ??
        const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    prefixIcon: prefixIcon,
    prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    suffixIcon: suffixIcon,
    suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    enabledBorder: hasError ? theme.errorBorder : null,
    focusedBorder: hasError ? theme.focusedErrorBorder : null,
  );
}
