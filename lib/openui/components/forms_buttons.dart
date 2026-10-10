// OpenUI components, group B3: forms, buttons and follow-ups.
//
// Owner: agent B3. Rules: docs/OPENUI.md. The exact signatures are in
// test/openui/fixtures/upstream/components-chat.json.
//
// The definitions are here; the widgets are in forms_buttons/:
//   field.dart       the validator, the FormControl slot, the field mixin
//   rules.dart       the shared `rules` object
//   form.dart        Form, FormControl, Label, the field look
//   text_fields.dart Input, TextArea
//   pickers.dart     Select, DatePicker, Slider
//   choices.dart     CheckBoxGroup, RadioGroup, SwitchGroup, Chips,
//                    OptionCards
//   buttons.dart     Buttons, IconButton, FollowUpBlock
// Button (OpenUiButton) stays in this file.
//
// Data-only items (read by their parent with props.data): SelectItem,
// CheckBoxItem, RadioItem, SwitchItem, ChipItem, OptionCard,
// FollowUpItem.
//
// Values: every field writes to the form state of the enclosing Form
// under its `name`, and to its `$binding` when there is one. A primary
// Button inside a Form checks the rules of all fields first (upstream).

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/components/forms_buttons/buttons.dart';
import 'package:chuk_chat/openui/components/forms_buttons/choices.dart';
import 'package:chuk_chat/openui/components/forms_buttons/field.dart';
import 'package:chuk_chat/openui/components/forms_buttons/form.dart';
import 'package:chuk_chat/openui/components/forms_buttons/pickers.dart';
import 'package:chuk_chat/openui/components/forms_buttons/rules.dart';
import 'package:chuk_chat/openui/components/forms_buttons/text_fields.dart';
import 'package:chuk_chat/openui/openui_component.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

export 'package:chuk_chat/openui/components/forms_buttons/field.dart'
    show OpenUiFormValidationScope, OpenUiFormValidator;
export 'package:chuk_chat/openui/components/forms_buttons/rules.dart'
    show OpenUiRule, OpenUiRules;

const String _sizes = '"extra-small" | "small" | "medium" | "large"';
const String _variants = '"primary" | "secondary" | "tertiary"';
const String _selectionType = '"single" | "multiple"';

/// The B3 components: forms, buttons and follow-ups.
final List<OpenUiComponentDef> formsButtonsComponents = <OpenUiComponentDef>[
  // -- Forms ----------------------------------------------------------
  const OpenUiComponentDef(
    name: 'Form',
    group: 'Forms',
    description: 'Form container with fields and explicit action buttons',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('buttons', 'Buttons'),
      OpenUiParam.opt('fields', 'FormControl[]'),
    ],
    builder: buildOpenUiForm,
  ),
  const OpenUiComponentDef(
    name: 'FormControl',
    group: 'Forms',
    description: 'Field with label, input component, and optional hint text',
    params: <OpenUiParam>[
      OpenUiParam('label', 'string'),
      OpenUiParam(
        'input',
        'Input | TextArea | Select | DatePicker | Slider | CheckBoxGroup | '
            'RadioGroup | Chips | OptionCards',
      ),
      OpenUiParam.opt('hint', 'string'),
    ],
    builder: buildOpenUiFormControl,
  ),
  const OpenUiComponentDef(
    name: 'Label',
    group: 'Forms',
    description: 'Text label',
    params: <OpenUiParam>[OpenUiParam('text', 'string')],
    builder: buildOpenUiLabel,
  ),
  const OpenUiComponentDef(
    name: 'Input',
    group: 'Forms',
    description: 'Single-line text field',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('placeholder', 'string'),
      OpenUiParam.opt(
        'type',
        '"text" | "email" | "password" | "number" | "url"',
      ),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('value', r'$binding<string>'),
    ],
    builder: buildOpenUiInput,
  ),
  const OpenUiComponentDef(
    name: 'TextArea',
    group: 'Forms',
    description: 'Multi-line text field',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('placeholder', 'string'),
      OpenUiParam.opt('rows', 'number'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('value', r'$binding<string>'),
    ],
    builder: buildOpenUiTextArea,
  ),
  const OpenUiComponentDef(
    name: 'Select',
    group: 'Forms',
    description: 'Dropdown to choose one option',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('items', 'SelectItem[]'),
      OpenUiParam.opt('placeholder', 'string'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('value', r'$binding<string>'),
      OpenUiParam.opt('size', '"small" | "medium" | "large"'),
    ],
    builder: buildOpenUiSelect,
  ),
  const OpenUiComponentDef.data(
    name: 'SelectItem',
    group: 'Forms',
    description: 'Option for Select',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam('label', 'string'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'DatePicker',
    group: 'Forms',
    description: 'Date field; mode "range" picks a start and an end date',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('mode', '"single" | "range"'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('value', r'$binding<any>'),
    ],
    builder: buildOpenUiDatePicker,
  ),
  const OpenUiComponentDef(
    name: 'Slider',
    group: 'Forms',
    description:
        'Numeric slider input; supports continuous and discrete (stepped) '
        'variants',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('variant', '"continuous" | "discrete"'),
      OpenUiParam('min', 'number'),
      OpenUiParam('max', 'number'),
      OpenUiParam.opt('step', 'number'),
      OpenUiParam.opt('defaultValue', 'number[]'),
      OpenUiParam.opt('label', 'string'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('value', r'$binding<number[]>'),
    ],
    builder: buildOpenUiSlider,
  ),
  const OpenUiComponentDef(
    name: 'CheckBoxGroup',
    group: 'Forms',
    description:
        'Group of check boxes; the value maps item names to true/false',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('items', 'CheckBoxItem[]'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('value', r'$binding<Record<string, boolean>>'),
    ],
    builder: buildOpenUiCheckBoxGroup,
  ),
  const OpenUiComponentDef.data(
    name: 'CheckBoxItem',
    group: 'Forms',
    description: 'One check box of a CheckBoxGroup',
    params: <OpenUiParam>[
      OpenUiParam('label', 'string'),
      OpenUiParam('description', 'string'),
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('defaultChecked', 'boolean'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'RadioGroup',
    group: 'Forms',
    description: 'Group of radio buttons to choose exactly one option',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('items', 'RadioItem[]'),
      OpenUiParam.opt('defaultValue', 'string'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('value', r'$binding<string>'),
    ],
    builder: buildOpenUiRadioGroup,
  ),
  const OpenUiComponentDef.data(
    name: 'RadioItem',
    group: 'Forms',
    description: 'One option of a RadioGroup',
    params: <OpenUiParam>[
      OpenUiParam('label', 'string'),
      OpenUiParam('description', 'string'),
      OpenUiParam('value', 'string'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'SwitchGroup',
    group: 'Forms',
    description: 'Group of switch toggles',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('items', 'SwitchItem[]'),
      OpenUiParam.opt('variant', '"clear" | "card" | "sunk"'),
      OpenUiParam.opt('value', r'$binding<Record<string, boolean>>'),
    ],
    builder: buildOpenUiSwitchGroup,
  ),
  const OpenUiComponentDef.data(
    name: 'SwitchItem',
    group: 'Forms',
    description: 'Individual switch toggle',
    params: <OpenUiParam>[
      OpenUiParam.opt('label', 'string'),
      OpenUiParam.opt('description', 'string'),
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('defaultChecked', 'boolean'),
    ],
  ),
  const OpenUiComponentDef.data(
    name: 'ChipItem',
    group: 'Forms',
    description:
        'A single selectable chip inside a Chips group, with a value, label '
        'and optional icon.',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam('label', 'string'),
      OpenUiParam.opt('icon', 'Icon'),
      OpenUiParam.opt('disabled', 'boolean'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'Chips',
    group: 'Forms',
    description:
        'A form field of compact selectable chips for choosing one or many '
        'short options; the selection is stored under `name`.',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('type', _selectionType),
      OpenUiParam.opt('items', 'ChipItem[]'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('defaultValue', 'string | string[]'),
    ],
    builder: buildOpenUiChips,
  ),
  const OpenUiComponentDef.data(
    name: 'OptionCard',
    group: 'Forms',
    description:
        'A single selectable card inside an OptionCards group, with a value, '
        'title, optional subtitle and an optional Icon or Image on top.',
    params: <OpenUiParam>[
      OpenUiParam('value', 'string'),
      OpenUiParam('title', 'string'),
      OpenUiParam.opt('subtitle', 'string'),
      OpenUiParam.opt('topContent', 'Icon | Image'),
      OpenUiParam.opt('disabled', 'boolean'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'OptionCards',
    group: 'Forms',
    description:
        'A form field of selectable cards (title, optional subtitle, optional '
        'icon or image) laid out in a responsive grid for choosing one or '
        'many options; the selection is stored under `name`.',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam.opt('type', _selectionType),
      OpenUiParam.opt('items', 'OptionCard[]'),
      OpenUiParam.opt('rules', kOpenUiRulesType),
      OpenUiParam.opt('defaultValue', 'string | string[]'),
    ],
    builder: buildOpenUiOptionCards,
  ),
  // -- Buttons --------------------------------------------------------
  const OpenUiComponentDef(
    name: 'Button',
    group: 'Buttons',
    description: 'Clickable button',
    params: <OpenUiParam>[
      OpenUiParam('label', 'string'),
      OpenUiParam.opt('action', 'ActionExpression'),
      OpenUiParam.opt('variant', _variants),
      OpenUiParam.opt('type', '"normal" | "destructive"'),
      OpenUiParam.opt('size', _sizes),
    ],
    builder: _buildButton,
  ),
  const OpenUiComponentDef(
    name: 'Buttons',
    group: 'Buttons',
    description:
        'Group of Button components. direction: "row" (default) | "column".',
    params: <OpenUiParam>[
      OpenUiParam('buttons', 'Button[]'),
      OpenUiParam.opt('direction', '"row" | "column"'),
    ],
    builder: buildOpenUiButtons,
  ),
  const OpenUiComponentDef(
    name: 'IconButton',
    group: 'Buttons',
    description:
        'Icon-only button. name is the accessible label and the action '
        'label; icon is an Icon; action fires on click.',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('icon', 'Icon'),
      OpenUiParam.opt('action', 'ActionExpression'),
      OpenUiParam.opt('variant', _variants),
      OpenUiParam.opt('size', _sizes),
      OpenUiParam.opt('shape', '"square" | "circle"'),
    ],
    builder: buildOpenUiIconButton,
  ),
  // -- Lists & Follow-ups ---------------------------------------------
  const OpenUiComponentDef(
    name: 'FollowUpBlock',
    group: 'Lists & Follow-ups',
    description:
        'List of clickable follow-up suggestions placed at the end of a '
        'response',
    params: <OpenUiParam>[OpenUiParam('items', 'FollowUpItem[]')],
    builder: buildOpenUiFollowUpBlock,
  ),
  const OpenUiComponentDef.data(
    name: 'FollowUpItem',
    group: 'Lists & Follow-ups',
    description:
        'Clickable follow-up suggestion — when clicked, sends text as user '
        'message',
    params: <OpenUiParam>[OpenUiParam('text', 'string')],
  ),
];

// ---------------------------------------------------------------------
// Button: the app's one button family (a MorphTap pill, flat fill, no
// glow). Without an action it sends its label to the assistant, with
// the values of the enclosing Form, like upstream.
// ---------------------------------------------------------------------

Widget _buildButton(BuildContext context, OpenUiProps props) {
  final label = props.string('label');
  if (label.trim().isEmpty) return const SizedBox.shrink();
  return OpenUiButton(
    label: label,
    action: props.action('action'),
    variant: props.choice('variant', fallback: 'primary'),
    destructive: props.choice('type', fallback: 'normal') == 'destructive',
    size: props.choice('size', fallback: 'medium'),
    statementId: props.statementId,
  );
}

/// The OpenUI button. Reuse it for `Buttons`, `IconButton` and the
/// submit row of a `Form`.
class OpenUiButton extends StatelessWidget {
  /// Creates a button.
  ///
  /// [action] is the resolved action. Without one (no argument, `null`
  /// or a malformed action), a tap sends [label] to the assistant. While
  /// the statement of the button still streams, it is disabled.
  const OpenUiButton({
    required this.label,
    this.action,
    this.variant = 'primary',
    this.destructive = false,
    this.size = 'medium',
    this.statementId = '',
    super.key,
  });

  /// The visible text and the message of a label action.
  final String label;

  /// The action, or `null`.
  final OpenUiAction? action;

  /// `primary` (accent fill), `secondary` (tonal fill) or `tertiary`
  /// (no fill, accent text).
  final String variant;

  /// The `destructive` type: error colours.
  final bool destructive;

  /// `extra-small`, `small`, `medium` or `large`.
  final String size;

  /// The statement of the button, to detect a still-streaming one.
  final String statementId;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final scheme = t.scheme;
    final renderer = RendererScope.maybeFind(context);
    final streamingHere =
        renderer != null &&
        renderer.isStreaming &&
        renderer.incomplete.contains(statementId);
    final enabled = !streamingHere;

    final (Color fill, Color fg) = switch ((variant, destructive)) {
      ('primary', false) => (scheme.primary, scheme.onPrimary),
      ('primary', true) => (scheme.error, scheme.onError),
      ('secondary', false) => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      ('secondary', true) => (scheme.errorContainer, scheme.onErrorContainer),
      (_, true) => (Colors.transparent, scheme.error),
      _ => (
        Colors.transparent,
        Theme.of(context).accentForegroundOn(scheme.surface),
      ),
    };
    final (EdgeInsets padding, double fontSize) = switch (size) {
      'extra-small' => (
        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        12.0,
      ),
      'small' => (
        const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        13.0,
      ),
      'large' => (
        const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
        15.0,
      ),
      _ => (const EdgeInsets.symmetric(horizontal: 20, vertical: 12), 14.0),
    };

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: MorphTap(
          onTap: enabled ? () => _onTap(context) : null,
          color: fill,
          padding: padding,
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
            ),
          ),
        ),
      ),
    );
  }

  void _onTap(BuildContext context) {
    // Inside a Form, a primary button is the submit: it checks the rules
    // of every field first and stops when one fails (upstream).
    final validator = OpenUiFormValidationScope.read(context);
    if (validator != null && variant == 'primary' && _submits(action)) {
      FocusManager.instance.primaryFocus?.unfocus();
      if (!validator.validateAll()) return;
    }
    final a = action ?? OpenUiAction(implicitContinueConversationPlan(label));
    a.run(context, label: label);
  }

  /// Whether the action sends something on: a message to the assistant
  /// or a `@Run`. No action is the implicit message.
  static bool _submits(OpenUiAction? action) {
    if (action == null) return true;
    return action.plan.steps.any(
      (s) => s is ContinueConversationStep || s is RunStep,
    );
  }
}
