// Generates assets/skills/openui/SKILL.md from chukOpenUiLibrary, then
// compiles the skills (tool/gen_skills.dart).
//
// OpenUI Lang by Thesys Inc. (MIT), https://github.com/thesysdev/openui.
// The rules and examples below are adapted from the upstream chat prompt.
//
// The library imports Flutter widgets, so this runs under `flutter test`
// (plain `dart run` has no dart:ui). From the repo root:
//
//   flutter test tool/gen_openui_skill.dart
//
// `test/openui/openui_skill_freshness_test.dart` fails when SKILL.md no
// longer matches the library. Run this tool again after a component
// change.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';

/// Where the generated skill goes.
const String kOpenUiSkillPath = 'assets/skills/openui/SKILL.md';

/// The prompt groups in upstream order. Other groups follow in
/// registration order.
const List<String> kOpenUiGroupOrder = <String>[
  'Content',
  'Tables',
  'Charts (2D)',
  'Charts (1D)',
  'Charts (Scatter)',
  'Forms',
  'Buttons',
  'Lists & Follow-ups',
  'Sections',
  'Layout',
  'Data Display',
  'Cards',
  'Other',
];

/// The skill description: in EVERY prompt, so it stays short (max 300).
const String kOpenUiSkillDescription =
    'Draws native UI in an answer: cards, tables, lists, forms, metrics, '
    'charts, follow-up buttons. Use when a structured view, comparison, '
    'choice or input form helps. Load before writing an openui-lang fence.';

/// Short notes that replace the upstream description in the skill.
///
/// The upstream descriptions repeat the enum values of the signature and
/// push the body over the skill budget. An empty note drops the
/// description: the signature says enough. A component that is not in
/// this map keeps its upstream description.
const Map<String, String> _kSkillNotes = <String, String>{
  'CardHeader': '',
  'TextContent': 'Markdown text',
  'MarkDownRenderer': 'Markdown in a container',
  'Callout': 'Banner; a \$visible binding hides it after 3 s',
  'TextCallout': '',
  'Image': '',
  'ImageBlock': '',
  'ImageGallery': 'Grid, tap for full screen',
  'CodeBlock': '',
  'InlineHeader': 'Compact heading inside a card',
  'Separator': '',
  'Steps': '',
  'StepsItem': '',
  'Table': 'Column-oriented table',
  'Col': 'One column with its data array',
  'EditableTable': 'Table the user edits; saved as a form field',
  'BarChart': 'Compare categories',
  'LineChart': 'Trends over time',
  'AreaChart': 'Totals or volume over time',
  'RadarChart': 'Compare several variables',
  'HorizontalBarChart': 'Long labels or ranked lists',
  'Series': '',
  'PieChart': 'Parts of one whole',
  'RadialChart': '',
  'SingleStackedBarChart': 'One bar split into parts',
  'Slice': '',
  'ScatterChart': 'Correlation',
  'ScatterSeries': '',
  'Point': '',
  'Form': '',
  'FormControl': 'One labelled field',
  'Label': '',
  'Input': '',
  'TextArea': '',
  'Select': '',
  'SelectItem': '',
  'DatePicker': 'Stores YYYY-MM-DD, or {from, to} for a range',
  'Slider': '',
  'CheckBoxGroup': '',
  'CheckBoxItem': '',
  'RadioGroup': '',
  'RadioItem': '',
  'SwitchGroup': '',
  'SwitchItem': '',
  'ChipItem': '',
  'Chips': 'Compact choice of short options',
  'OptionCard': '',
  'OptionCards': 'Choice as a grid of cards',
  'Button': '',
  'Buttons': '',
  'IconButton': 'name is the label sent on click',
  'Icon': 'Lucide name, e.g. "circle-check", "map-pin"',
  'FollowUpBlock': 'Suggestions at the end of an answer',
  'FollowUpItem': 'A tap sends text as a user message',
  'ListBlock': 'Items can be clickable',
  'ListItem': '',
  'Card': 'Root. sources back inline [n] citations in TextContent',
  'Stack': 'Flex container, default column, gap "m"',
  'Tabs': '',
  'TabItem': '',
  'Accordion': '',
  'AccordionItem': '',
  'Carousel': 'Each inner array is one slide',
  'SectionBlock': 'Collapsible sections',
  'SectionItem': '',
  'Modal': 'Dialog; set the open binding true to show it',
  'TagBlock': '',
  'Tag': '',
  'EntityList': 'Key/value rows',
  'Text': 'subtextVariant "metric" colours a +/- subtext',
  'BoldText': 'Like Text, bold',
  'IconText': 'Icon badge with title',
  'ImageText': 'Thumbnail with title; src must be a real URL',
  'ImageTextLarge': 'Banner image; src must be a real URL',
  'MetricIndicatorInline': 'Big value with trend',
  'MetricIndicatorWithStrikethrough': 'Value with old value struck out',
  'SnippetCardItem': '',
  'SnippetCardBlock': 'Short facts, 2 per row',
  'OverviewCardItem': '',
  'OverviewCardBlock': 'Headline cards with a metric',
  'ContextCardItem': 'body is markdown',
  'ContextCardBlock': 'Tinted cards with a short body',
  'CompositeCardItem': '',
  'CompositeCardBlock': 'Rich cards (offers, hotels, products)',
  'VisualCardItem': 'bgImageSrc must be a real URL',
  'VisualCardBlock': 'Photo-first cards',
};

const String _header = r'''
# OpenUI: rich UI in the answer

The app draws OpenUI Lang (spec v0.5) as native widgets. Use it when a
structured view helps: cards, tables, lists, comparisons, metrics,
charts, choices, forms, follow-up buttons. For a simple question, answer
with text only.

## Inline mode

- Write normal markdown. Put the UI in ONE fence that starts with
  ```openui-lang and ends with ```. Text outside the fence shows as chat.
- One statement per line: `name = Expression`. Line 1 is
  `root = Card([...])`. Then the children, top to bottom. Leaf data last.
  The UI streams in this order.
- Every name except `root` must be used by another statement, or it does
  not show. Every name you use must be defined.
- Arguments are POSITIONAL, in signature order. No named arguments
  (`gap: "l"` breaks the line). Leave out optional arguments at the end;
  write `null` for a skipped optional argument in the middle.
- Values: "strings" (backslash escapes), numbers, true/false, null,
  [arrays], {key: value} objects, component calls.
- No Query or Mutation. Call tools the normal way first, then put the
  results in the UI as literal data. Never invent data.
- No <chart>/<map> tags and no other code fence inside the fence.

## Actions

An `ActionExpression` slot takes `Action([step, ...])`:
- `@ToAssistant("message")` sends a user message in this chat.
- `@OpenUrl("https://...")` opens a link (http, https, mailto, tel).
- `@Set($var, value)` sets a variable; `@Reset($a, $b)` restores defaults.
Some slots also take `{type: "continue_conversation", context: "..."}`.
A `Button` without an action sends its label. A button in a `Form` sends
the form values with the message.

## State and expressions

`$name = default` declares a variable. Pass `$name` to a `$binding<...>`
slot for two-way binding; everything that reads `$name` updates.
Expressions: `a.b`, `a[0]`, `rows.title` (a field of each element),
`c ? a : b`, `+ - * / %`, comparisons, `&& || !`, `@Count @Sum @Avg @Min
@Max @First @Last @Filter(arr, field, op, value) @Sort(arr, field, dir?)
@Round(n, d?) @Each(arr, "x", Comp(x.field))`.

## Layout rules

- Card is the root container; children stack top to bottom.
- `CardHeader` first when the answer needs a title.
- One `FormControl` per statement; `Form(name, Buttons(...), [fields])`.
- End with `FollowUpBlock([...])` when there are good next questions.
- Do not use a callout for meta comments about the answer.
''';

const String _examples = r'''
## Examples

A comparison:

```openui-lang
root = Card([header, table, note, followUps])
header = CardHeader("Python vs JavaScript", "The main differences")
table = Table([colTopic, colPy, colJs])
colTopic = Col("Topic", ["Typing", "Runs in", "Typical use"])
colPy = Col("Python", ["Dynamic, strong", "Interpreter", "Data, scripts"])
colJs = Col("JavaScript", ["Dynamic, weak", "Browser, Node", "Web apps"])
note = TextContent("Both are good first languages. Pick by **what you want to build**.")
followUps = FollowUpBlock([FollowUpItem("Which one is faster?"), FollowUpItem("Show the same code in both")])
```

Choices the user can tap (`null` skips the image slot):

```openui-lang
root = Card([title, list, more])
title = InlineHeader("Two trip ideas", "Tap one for a full plan")
list = ListBlock([rome, lisbon])
rome = ListItem("Weekend in Rome", "3 days, about 600 EUR", null, "Plan it", Action([@ToAssistant("Plan the Rome weekend in detail")]))
lisbon = ListItem("Week in Lisbon", "7 days, about 1100 EUR", null, "Plan it", Action([@ToAssistant("Plan the Lisbon week in detail")]))
more = Buttons([Button("Open the city guide", Action([@OpenUrl("https://www.example.com/guide")]), "secondary")])
```

A form:

```openui-lang
root = Card([header, form])
header = CardHeader("Book a table")
form = Form("booking", buttons, [fcName, fcGuests, fcNote])
fcName = FormControl("Name", Input("name", "Your name", "text", {required: true}))
fcGuests = FormControl("Guests", Select("guests", [SelectItem("2", "2 people"), SelectItem("4", "4 people")], "Choose"))
fcNote = FormControl("Note", TextArea("note", "Allergies, wishes", 3))
buttons = Buttons([Button("Send request", Action([@ToAssistant("Book the table with these details")]), "primary")])
```
''';

/// The example programs of the skill (the fence bodies), for tests.
List<String> openUiSkillExamplePrograms() {
  final fence = RegExp(r'```openui-lang\n([\s\S]*?)\n```');
  return <String>[for (final m in fence.allMatches(_examples)) m.group(1)!];
}

/// Names for repeated object types, by the param name where the type
/// first shows. An unnamed one gets the param name, capitalised.
const Map<String, String> _kObjectAliasNames = <String, String>{
  'rules': 'Rules',
  'rows': 'EntityRow',
};

/// The name of the shared start of the long child unions.
const String _kContentAlias = 'Content';

/// A short name for a long type that repeats in the signatures. The
/// skill defines it once, so the prompt stays small.
class OpenUiTypeAlias {
  /// Creates an alias.
  const OpenUiTypeAlias(this.name, this.text);

  /// The short name, for example `Rules`.
  final String name;

  /// The full type text. For the content union it is the member list
  /// joined by ` | `.
  final String text;
}

final RegExp _objectType = RegExp(r'\{[^{}]*\}');
final RegExp _unionGroup = RegExp(r'\(([^()]*)\)');

/// The aliases for [library]: object types that show 3+ times, and the
/// shared start of the long child unions (`(A | B | ...)[]`).
List<OpenUiTypeAlias> openUiSkillAliases(OpenUiLibrary library) {
  final params = <OpenUiParam>[
    for (final def in library.components) ...def.params,
  ];
  final aliases = <OpenUiTypeAlias>[];

  final counts = <String, int>{};
  final firstParam = <String, String>{};
  for (final p in params) {
    for (final m in _objectType.allMatches(p.type)) {
      final text = m.group(0)!;
      counts[text] = (counts[text] ?? 0) + 1;
      firstParam.putIfAbsent(text, () => p.name);
    }
  }
  for (final e in counts.entries) {
    if (e.value < 3 || e.key.length < 40) continue;
    final param = firstParam[e.key]!;
    final name =
        _kObjectAliasNames[param] ??
        '${param[0].toUpperCase()}${param.substring(1)}';
    aliases.add(OpenUiTypeAlias(name, e.key));
  }

  // The long unions share their first members. That shared start
  // becomes `Content`.
  final unions = <List<String>>[
    for (final p in params)
      for (final m in _unionGroup.allMatches(p.type))
        if (_members(m.group(1)!).length >= 20) _members(m.group(1)!),
  ];
  if (unions.length >= 3) {
    var prefix = unions.first;
    for (final u in unions.skip(1)) {
      var n = 0;
      while (n < prefix.length && n < u.length && prefix[n] == u[n]) {
        n++;
      }
      prefix = prefix.sublist(0, n);
    }
    if (prefix.length >= 5) {
      aliases.add(OpenUiTypeAlias(_kContentAlias, prefix.join(' | ')));
    }
  }
  return aliases;
}

List<String> _members(String union) =>
    union.split('|').map((m) => m.trim()).toList();

/// [type] with the long parts replaced by alias names.
String openUiSkillShortType(String type, List<OpenUiTypeAlias> aliases) {
  var out = type;
  for (final a in aliases) {
    if (a.name == _kContentAlias) continue;
    out = out.replaceAll(a.text, a.name);
  }
  final content = aliases.where((a) => a.name == _kContentAlias);
  if (content.isEmpty) return out;
  final prefix = _members(content.single.text);
  return out.replaceAllMapped(_unionGroup, (m) {
    final members = _members(m.group(1)!);
    if (members.length < prefix.length) return m.group(0)!;
    for (var i = 0; i < prefix.length; i++) {
      if (members[i] != prefix[i]) return m.group(0)!;
    }
    final rest = members.sublist(prefix.length);
    // `(Content)[]` reads better as `Content[]`.
    if (rest.isEmpty) return _kContentAlias;
    return '(${<String>[_kContentAlias, ...rest].join(' | ')})';
  });
}

/// [short] with the alias names replaced by their full text again.
/// The freshness test checks that this gives back the exact signature.
String expandOpenUiSkillType(String short, List<OpenUiTypeAlias> aliases) {
  var out = short;
  for (final a in aliases) {
    final word = RegExp('\\b${a.name}\\b');
    if (a.name != _kContentAlias) {
      out = out.replaceAll(word, a.text);
      continue;
    }
    // `(Content | X)` puts the members in place; a bare `Content`
    // becomes the whole union in parentheses.
    out = out
        .replaceAll('($_kContentAlias | ', '(${a.text} | ')
        .replaceAll(word, '(${a.text})');
  }
  return out;
}

/// The signature as the skill writes it, with alias names.
String openUiSkillSignature(OpenUiComponentDef def, List<OpenUiTypeAlias> a) {
  final params = [
    for (final p in def.params)
      '${p.name}${p.optional ? '?' : ''}: ${openUiSkillShortType(p.type, a)}',
  ];
  return '${def.name}(${params.join(', ')})';
}

/// Builds the SKILL.md text for [library].
String buildOpenUiSkillMarkdown(OpenUiLibrary library) {
  final aliases = openUiSkillAliases(library);
  final byGroup = <String, List<OpenUiComponentDef>>{};
  for (final def in library.components) {
    byGroup.putIfAbsent(def.group, () => <OpenUiComponentDef>[]).add(def);
  }
  final groups = <String>[
    for (final g in kOpenUiGroupOrder)
      if (byGroup.containsKey(g)) g,
    for (final g in byGroup.keys)
      if (!kOpenUiGroupOrder.contains(g)) g,
  ];

  final out = StringBuffer()
    ..writeln('---')
    ..writeln(
      '# GENERATED by tool/gen_openui_skill.dart from '
      'chukOpenUiLibrary. Do not edit by hand.',
    )
    ..writeln(
      '# OpenUI Lang by Thesys Inc. (MIT), '
      'https://github.com/thesysdev/openui',
    )
    ..writeln('name: openui')
    ..writeln('description: "$kOpenUiSkillDescription"')
    ..writeln('metadata:')
    ..writeln('  version: "1.0"')
    ..writeln('---')
    ..write(_header)
    ..writeln()
    ..writeln('## Components')
    ..writeln()
    ..writeln('`?` marks an optional argument. Use only these components.');
  if (aliases.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Type names used below:');
    for (final a in aliases) {
      out.writeln('- `${a.name}` = `${a.text}`');
    }
  }
  for (final group in groups) {
    out
      ..writeln()
      ..writeln('### $group');
    for (final def in byGroup[group]!) {
      final description =
          (_kSkillNotes[def.name] ?? def.description)
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      final signature = openUiSkillSignature(def, aliases);
      out.writeln(
        description.isEmpty ? signature : '$signature — $description',
      );
    }
  }
  out.write(_examples);
  return out.toString();
}

void main() {
  test('writes $kOpenUiSkillPath and compiles the skills', () {
    final file = File(kOpenUiSkillPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(buildOpenUiSkillMarkdown(chukOpenUiLibrary));
    final gen = Process.runSync('dart', <String>[
      'run',
      'tool/gen_skills.dart',
    ]);
    stdout.write(gen.stdout);
    stderr.write(gen.stderr);
    expect(gen.exitCode, 0, reason: 'dart run tool/gen_skills.dart failed');
  });
}
