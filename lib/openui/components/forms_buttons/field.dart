// The plumbing that every OpenUI form field shares: the per-form
// validator, the FormControl slot, and the mixin that reads and writes
// one field value.
//
// Where a value lives:
// - In the form state of the view (`OpenUiFormScope.formOf`), under the
//   field `name`. A submit sends these values.
// - In the store, when the `value` slot got a `$variable`
//   (`props.binding('value')`). Then the store is the source and the
//   form state follows it.
// - Else a literal `value` or a default (`defaultValue`,
//   `defaultChecked`) is the start value. When the view stops
//   streaming, it is copied into the form state, so a submit sends what
//   the user sees.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/components/forms_buttons/rules.dart';
import 'package:chuk_chat/openui/openui_actions.dart';
import 'package:chuk_chat/openui/openui_props.dart';

/// The validation state of one `Form`: the fields with rules, and the
/// current error of each field.
class OpenUiFormValidator extends ChangeNotifier {
  /// The texts of the errors. The `Form` sets the app locale's texts.
  OpenUiRuleMessages messages = OpenUiRuleMessages.english;

  final Map<String, _Registration> _fields = <String, _Registration>{};
  final Map<String, String> _errors = <String, String>{};
  bool _disposed = false;

  /// Registers (or updates) the field [name]. [token] identifies the
  /// field widget, so a late [unregister] of an old widget does not
  /// remove the registration of its successor. [read] gives the value
  /// to check on submit.
  void register(
    String name,
    Object token,
    OpenUiRules rules,
    Object? Function() read,
  ) {
    _fields[name] = _Registration(token, rules, read);
  }

  /// Removes the field [name] when [token] still owns it.
  void unregister(String name, Object token) {
    final reg = _fields[name];
    if (reg == null || !identical(reg.token, token)) return;
    _fields.remove(name);
    if (_errors.remove(name) != null) _notify();
  }

  /// The current error of [name], or `null`.
  String? errorOf(String name) => _errors[name];

  /// Whether a field [name] with rules is registered.
  bool has(String name) => _fields.containsKey(name);

  /// Checks [value] against the rules of [name] and shows the result.
  /// Returns whether the value is valid.
  bool validateField(String name, Object? value) {
    final reg = _fields[name];
    if (reg == null) return true;
    final error = reg.rules.validate(value, messages);
    _setError(name, error);
    return error == null;
  }

  /// Hides the error of [name].
  void clearError(String name) => _setError(name, null);

  /// Checks every registered field. Returns whether all are valid.
  bool validateAll() {
    var valid = true;
    var changed = false;
    for (final entry in _fields.entries) {
      String? error;
      try {
        error = entry.value.rules.validate(entry.value.read(), messages);
      } on Object {
        error = null;
      }
      if (error != null) valid = false;
      if (_errors[entry.key] != error) {
        changed = true;
        if (error == null) {
          _errors.remove(entry.key);
        } else {
          _errors[entry.key] = error;
        }
      }
    }
    if (changed) _notify();
    return valid;
  }

  void _setError(String name, String? error) {
    if (_errors[name] == error) return;
    if (error == null) {
      _errors.remove(name);
    } else {
      _errors[name] = error;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _Registration {
  const _Registration(this.token, this.rules, this.read);

  final Object token;
  final OpenUiRules rules;
  final Object? Function() read;
}

/// Gives the fields and buttons of one `Form` its validator.
class OpenUiFormValidationScope extends InheritedNotifier<OpenUiFormValidator> {
  /// Creates the scope.
  const OpenUiFormValidationScope({
    required OpenUiFormValidator validator,
    required super.child,
    super.key,
  }) : super(notifier: validator);

  /// The validator of the enclosing form, and a rebuild when an error
  /// changes. `null` outside a form.
  static OpenUiFormValidator? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<OpenUiFormValidationScope>()
      ?.notifier;

  /// The validator of the enclosing form, with no rebuild dependency.
  static OpenUiFormValidator? read(BuildContext context) => context
      .getInheritedWidgetOfExactType<OpenUiFormValidationScope>()
      ?.notifier;
}

/// What a `FormControl` learns from the field inside it: its name and
/// whether it is required.
class OpenUiFieldSlot extends ChangeNotifier {
  String? _name;
  bool _required = false;
  bool _disposed = false;
  bool _pending = false;

  /// The name of the field in the control, or `null`.
  String? get name => _name;

  /// Whether the field has the `required` rule.
  bool get required => _required;

  /// Called by the field during its build. Listeners hear of a change
  /// after the frame, never during a build.
  void attach(String name, {required bool required}) {
    if (_name == name && _required == required) return;
    _name = name;
    _required = required;
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Gives a field the slot of its `FormControl`.
class OpenUiFieldSlotScope extends InheritedWidget {
  /// Creates the scope.
  const OpenUiFieldSlotScope({
    required this.slot,
    required super.child,
    super.key,
  });

  /// The slot.
  final OpenUiFieldSlot slot;

  /// The slot of the enclosing `FormControl`, or `null`.
  static OpenUiFieldSlot? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<OpenUiFieldSlotScope>()?.slot;

  @override
  bool updateShouldNotify(OpenUiFieldSlotScope oldWidget) =>
      oldWidget.slot != slot;
}

/// One field as seen in one build: where its value lives, and its
/// validation state.
class OpenUiField {
  OpenUiField._({
    required this.name,
    required this.form,
    required this.binding,
    required this.literal,
    required this.validator,
    required this.streaming,
    required this.rules,
  });

  /// The field name (the first argument).
  final String name;

  /// The state of the enclosing form, or `null` outside a form.
  final OpenUiFormState? form;

  /// The `$variable` of the `value` slot, or `null`.
  final OpenUiBinding? binding;

  /// A literal (not bound) `value` argument, or `null`.
  final Object? literal;

  /// The validator of the enclosing form, or `null`.
  final OpenUiFormValidator? validator;

  /// Whether the view still streams. Fields are read-only then.
  final bool streaming;

  /// The rules of the field.
  final OpenUiRules rules;

  /// Whether the user can change the field now.
  bool get enabled => !streaming;

  /// The stored value: the form state first (it survives a remount of
  /// the view), then the store of a binding, then the literal `value`.
  /// `null` when there is none.
  Object? get stored {
    final f = form;
    if (f != null && f.hasValue(name)) return f.value(name);
    final b = binding;
    if (b != null) return b.value;
    return literal;
  }

  /// The value right now, also when it changed after this build (two
  /// taps in one frame). Same order as [stored].
  Object? latest(BuildContext context) {
    final f = form;
    if (f != null && f.hasValue(name)) return f.value(name);
    final b = binding;
    if (b == null) return literal;
    try {
      return RendererScope.maybeFind(context)?.store.get(b.target) ?? b.value;
    } on StateError {
      return b.value;
    }
  }

  /// The error to show, or `null`.
  String? get error => validator?.errorOf(name);

  /// Writes [value] to the form state and to the binding.
  void write(BuildContext context, Object? value) {
    form?.setValue(name, value);
    binding?.set(context, value);
  }

  /// Shows the result of the rules for [value] (on a change or a blur).
  void validate(Object? value) {
    if (rules.isEmpty) return;
    validator?.validateField(name, value);
  }

  /// Hides the error of the field.
  void clearError() {
    if (rules.isEmpty) return;
    validator?.clearError(name);
  }
}

/// Shared state logic of every OpenUI form field widget.
///
/// Call [resolveField] at the start of `build`. It reads the props,
/// listens to the form state, registers the rules, tells the
/// `FormControl` about the field, and copies the start value into the
/// form state once the view stops streaming.
mixin OpenUiFieldStateMixin<W extends StatefulWidget> on State<W> {
  final Object _token = Object();
  OpenUiFormState? _listened;
  OpenUiFormValidator? _registeredWith;
  String? _registeredName;

  /// Resolves the field of [props] for this build.
  ///
  /// [startValue] is the value to show when nothing is stored (a
  /// default). [validationValue] maps the stored value to the value the
  /// rules check (the default reads [OpenUiField.stored]).
  OpenUiField resolveField(
    BuildContext context,
    OpenUiProps props, {
    Object? startValue,
    Object? Function(Object? stored)? validationValue,
  }) {
    final renderer = RendererScope.maybeFind(context);
    final rawName = props.string('name').trim();
    final name = rawName.isEmpty ? props.component : rawName;
    final binding = props.binding('value');
    final literal = binding == null ? props.raw('value') : null;
    final form = OpenUiFormScope.formOf(context);
    final validator = OpenUiFormValidationScope.of(context);
    final rules = OpenUiRules.parse(props.raw('rules'));
    final field = OpenUiField._(
      name: name,
      form: form,
      binding: binding,
      literal: literal is Widget ? null : literal,
      validator: validator,
      streaming: renderer?.isStreaming ?? false,
      rules: rules,
    );

    _listen(form);
    _register(field, validationValue);
    OpenUiFieldSlotScope.maybeOf(context)
        ?.attach(name, required: rules.required);
    _hydrate(field, field.stored ?? startValue);
    return field;
  }

  void _listen(OpenUiFormState? form) {
    if (identical(form, _listened)) return;
    _listened?.removeListener(_onFormChanged);
    _listened = form;
    form?.addListener(_onFormChanged);
  }

  void _onFormChanged() {
    if (mounted) setState(() {});
  }

  void _register(
    OpenUiField field,
    Object? Function(Object? stored)? validationValue,
  ) {
    final validator = field.validator;
    if (_registeredWith != null &&
        (!identical(_registeredWith, validator) ||
            _registeredName != field.name)) {
      _registeredWith!.unregister(_registeredName!, _token);
      _registeredWith = null;
      _registeredName = null;
    }
    if (validator == null || field.rules.isEmpty) return;
    final map = validationValue ?? (Object? v) => v;
    validator.register(field.name, _token, field.rules, () {
      final form = field.form;
      final stored = form != null && form.hasValue(field.name)
          ? form.value(field.name)
          : field.stored;
      return map(stored);
    });
    _registeredWith = validator;
    _registeredName = field.name;
  }

  /// Keeps the form state, the binding and the start value in line.
  ///
  /// - No form value yet: the start value goes into the form state.
  /// - A binding that differs from the form value: after a `@Set` (a
  ///   store mutation) the form follows the store; after a remount (the
  ///   store holds only its declared seed) the store follows the form,
  ///   so the restored value wins.
  void _hydrate(OpenUiField field, Object? effective) {
    final form = field.form;
    if (form == null || field.streaming) return;
    final name = field.name;
    final binding = field.binding;
    if (!form.hasValue(name)) {
      if (effective == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || form.hasValue(name)) return;
        form.setValue(name, effective);
      });
      return;
    }
    if (binding == null) return;
    final formValue = form.value(name);
    if (openUiDeepEquals(formValue, binding.value)) return;
    final store = RendererScope.maybeFind(context)?.store;
    final mutation =
        store != null &&
        binding.value != null &&
        store.lastNotifyOrigin == StoreChangeOrigin.mutation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (mutation) {
        form.setValue(name, binding.value);
      } else {
        binding.set(context, formValue);
      }
    });
  }

  @override
  void dispose() {
    _listened?.removeListener(_onFormChanged);
    _listened = null;
    final validator = _registeredWith;
    final name = _registeredName;
    if (validator != null && name != null) {
      validator.unregister(name, _token);
    }
    super.dispose();
  }
}

/// Deep equality for the plain values a field stores (lists, maps,
/// primitives).
bool openUiDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!openUiDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!openUiDeepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Whether the statement [statementId] still streams (taps wait).
bool openUiStatementStreaming(BuildContext context, String statementId) {
  final renderer = RendererScope.maybeFind(context);
  return renderer != null &&
      renderer.isStreaming &&
      renderer.incomplete.contains(statementId);
}
