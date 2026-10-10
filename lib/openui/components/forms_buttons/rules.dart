// The `rules` object of the OpenUI form fields, parsed once and used by
// every field.
//
// Upstream: thesysdev/openui `lang-core/src/utils/validation.ts` (MIT).
// Keys: required, email, url, numeric, min, max, minLength, maxLength,
// pattern. A key with `false` or `null` is off. An unknown key is
// skipped. The English messages are the upstream messages; the app
// passes translated ones (OpenUiRuleMessages.of).

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';

/// The type text of the `rules` slot, exactly as upstream.
const String kOpenUiRulesType =
    '{required?: boolean, email?: boolean, url?: boolean, numeric?: boolean, '
    'min?: number, max?: number, minLength?: number, maxLength?: number, '
    'pattern?: string}';

/// The texts of the rule errors. `{n}` stands for the limit.
@immutable
class OpenUiRuleMessages {
  /// Creates the messages.
  const OpenUiRuleMessages({
    required this.required,
    required this.optionRequired,
    required this.email,
    required this.url,
    required this.number,
    required this.min,
    required this.max,
    required this.minLength,
    required this.maxLength,
    required this.pattern,
  });

  /// The upstream English messages.
  static const OpenUiRuleMessages english = OpenUiRuleMessages(
    required: 'This field is required',
    optionRequired: 'At least one option is required',
    email: 'Please enter a valid email',
    url: 'Please enter a valid URL',
    number: 'Must be a number',
    min: 'Must be at least {n}',
    max: 'Must be no more than {n}',
    minLength: 'Must be at least {n} characters',
    maxLength: 'Must be no more than {n} characters',
    pattern: 'Invalid format',
  );

  /// The messages of the app locale [l].
  factory OpenUiRuleMessages.of(AppLocalizations l) => OpenUiRuleMessages(
    required: l.openUiFieldRequired,
    optionRequired: l.openUiOptionRequired,
    email: l.openUiInvalidEmail,
    url: l.openUiInvalidUrl,
    number: l.openUiMustBeNumber,
    min: l.openUiMinValue('{n}'),
    max: l.openUiMaxValue('{n}'),
    minLength: l.openUiMinLength('{n}'),
    maxLength: l.openUiMaxLength('{n}'),
    pattern: l.openUiInvalidFormat,
  );

  /// An empty required field.
  final String required;

  /// A required check box group with nothing checked.
  final String optionRequired;

  /// A bad email.
  final String email;

  /// A bad URL.
  final String url;

  /// Not a number.
  final String number;

  /// Below `min`.
  final String min;

  /// Above `max`.
  final String max;

  /// Shorter than `minLength`.
  final String minLength;

  /// Longer than `maxLength`.
  final String maxLength;

  /// No `pattern` match.
  final String pattern;

  @override
  bool operator ==(Object other) =>
      other is OpenUiRuleMessages &&
      other.required == required &&
      other.optionRequired == optionRequired &&
      other.email == email &&
      other.url == url &&
      other.number == number &&
      other.min == min &&
      other.max == max &&
      other.minLength == minLength &&
      other.maxLength == maxLength &&
      other.pattern == pattern;

  @override
  int get hashCode => Object.hash(
    required,
    optionRequired,
    email,
    url,
    number,
    min,
    max,
    minLength,
    maxLength,
    pattern,
  );
}

/// One rule: its [type] (`minLength`) and its argument (`3`), if any.
@immutable
class OpenUiRule {
  /// Creates a rule.
  const OpenUiRule(this.type, [this.arg]);

  /// The rule key.
  final String type;

  /// The argument. `null` for a boolean rule.
  final Object? arg;

  @override
  String toString() => arg == null ? type : '$type:$arg';
}

/// The parsed rules of one field.
@immutable
class OpenUiRules {
  /// Creates rules from a list.
  const OpenUiRules(this.rules);

  /// No rules.
  static const OpenUiRules none = OpenUiRules(<OpenUiRule>[]);

  static const Set<String> _known = <String>{
    'required',
    'email',
    'url',
    'numeric',
    'min',
    'max',
    'minLength',
    'maxLength',
    'pattern',
  };

  /// Parses an OpenUI object literal (`{required: true, minLength: 3}`).
  /// Anything that is not a map gives [none]. This never throws.
  factory OpenUiRules.parse(Object? raw) {
    if (raw is! Map) return none;
    final out = <OpenUiRule>[];
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (!_known.contains(key)) continue;
      if (value == null || value == false) continue;
      if (value == 'false') continue;
      if (value == true || value == 'true') {
        // A boolean on a rule that needs an argument means nothing.
        if (_needsArg(key)) continue;
        out.add(OpenUiRule(key));
        continue;
      }
      if (!_needsArg(key)) {
        // `required: 1` and the like: treat as on.
        out.add(OpenUiRule(key));
        continue;
      }
      out.add(OpenUiRule(key, value));
    }
    return out.isEmpty ? none : OpenUiRules(List<OpenUiRule>.unmodifiable(out));
  }

  static bool _needsArg(String key) =>
      key == 'min' ||
      key == 'max' ||
      key == 'minLength' ||
      key == 'maxLength' ||
      key == 'pattern';

  /// The rules, in the order of the object literal.
  final List<OpenUiRule> rules;

  /// Whether there are no rules.
  bool get isEmpty => rules.isEmpty;

  /// Whether the field must have a value.
  bool get required => rules.any((r) => r.type == 'required');

  /// The first error for [value], or `null` when the value is valid.
  /// The texts come from [messages] (English by default).
  String? validate(
    Object? value, [
    OpenUiRuleMessages messages = OpenUiRuleMessages.english,
  ]) {
    for (final rule in rules) {
      final error = _check(rule, value, messages);
      if (error != null) return error;
    }
    return null;
  }

  /// Whether [value] counts as empty: `null`, blank text, an empty list
  /// or an empty map.
  static bool isEmptyValue(Object? value) {
    if (value == null) return true;
    if (value is String) return value.trim().isEmpty;
    if (value is Iterable) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    return false;
  }

  static String? _check(
    OpenUiRule rule,
    Object? value,
    OpenUiRuleMessages m,
  ) {
    switch (rule.type) {
      case 'required':
        if (isEmptyValue(value)) return m.required;
        if (value is Map) {
          final values = value.values.toList();
          if (values.isNotEmpty &&
              values.every((v) => v is bool) &&
              !values.contains(true)) {
            return m.optionRequired;
          }
        }
        return null;
      case 'email':
        if (isEmptyValue(value)) return null;
        if (value is! String) return m.email;
        return _email.hasMatch(value.trim()) ? null : m.email;
      case 'url':
        if (isEmptyValue(value)) return null;
        if (value is! String) return m.url;
        return _isUrl(value.trim()) ? null : m.url;
      case 'numeric':
        if (isEmptyValue(value)) return null;
        if (value is num && !value.isNaN) return null;
        if (value is String && double.tryParse(value.trim()) != null) {
          return null;
        }
        return m.number;
      case 'min':
      case 'max':
        if (isEmptyValue(value)) return null;
        final n = _toNumber(value is List ? value.first : value);
        final limit = _toNumber(rule.arg);
        if (n == null || limit == null) return null;
        if (rule.type == 'min') {
          return n >= limit ? null : _limit(m.min, limit);
        }
        return n <= limit ? null : _limit(m.max, limit);
      case 'minLength':
      case 'maxLength':
        if (isEmptyValue(value) || value is! String) return null;
        final limit = _toNumber(rule.arg);
        if (limit == null) return null;
        final length = value.runes.length;
        if (rule.type == 'minLength') {
          return length >= limit ? null : _limit(m.minLength, limit);
        }
        return length <= limit ? null : _limit(m.maxLength, limit);
      case 'pattern':
        if (isEmptyValue(value) || value is! String) return null;
        final source = rule.arg;
        if (source is! String) return null;
        try {
          return RegExp(source).hasMatch(value) ? null : m.pattern;
        } on FormatException {
          return null;
        }
    }
    return null;
  }

  static final RegExp _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static bool _isUrl(String value) {
    if (value.contains(RegExp(r'\s'))) return false;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return false;
    return uri.host.isNotEmpty || uri.path.isNotEmpty;
  }

  static double? _toNumber(Object? v) {
    if (v is num) return v.isFinite ? v.toDouble() : null;
    if (v is String) {
      final n = double.tryParse(v.trim());
      return n != null && n.isFinite ? n : null;
    }
    return null;
  }

  static String _limit(String template, double limit) =>
      template.replaceAll('{n}', _fmt(limit));

  static String _fmt(double v) =>
      v == v.roundToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : '$v';

  @override
  String toString() => 'OpenUiRules($rules)';
}
