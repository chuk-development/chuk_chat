// lib/widgets/agent_activity/tool_activity_category.dart
//
// What KIND of work a tool call is, read from its recorded name, and the
// words a group of calls gets: "Searching the web" while it runs, "Searched
// the web" once it is closed. One table, so the timeline, the group rows and
// the tests agree.
//
// Rules (from deepseek-harness `ui-chat/.../conversation-nodes/README.md`,
// adapted to this app's tool names):
// - Classification uses the exact tool name. No guess from arguments.
// - A group title names at most three categories, ranked by how many calls
//   each has (ties keep the order of first use). No counts in the title.
// - A label describes recorded activity, not success: a failed read still
//   counts as "Read files".

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';

/// One kind of tool work.
enum ToolActivityCategory {
  read,
  readImage,
  search,
  write,
  edit,
  documents,
  notes,
  commands,
  code,
  webSearch,
  webFetch,
  images,
  questions,
  tools,
}

/// The category of the tool called [name]. Exact names first, then a few
/// prefixes and suffixes. Every other name is [ToolActivityCategory.tools].
ToolActivityCategory toolActivityCategoryOf(String name) {
  switch (name) {
    case 'read_file':
    case 'read':
    case 'fetch_files':
      return ToolActivityCategory.read;
    case 'read_image':
    case 'view_chat_images':
    case 'fetch_image':
      return ToolActivityCategory.readImage;
    case 'search_chats':
    case 'grep':
    case 'glob':
    case 'list_dir':
    case 'list_files':
    case 'find_tools':
      return ToolActivityCategory.search;
    case 'write_file':
    case 'write':
      return ToolActivityCategory.write;
    case 'edit_file':
    case 'edit':
    case 'apply_patch':
      return ToolActivityCategory.edit;
    case 'artifact_manager':
    case 'create_artifact':
    case 'update_artifact':
    case 'typst_compile':
      return ToolActivityCategory.documents;
    case 'notes':
      return ToolActivityCategory.notes;
    case 'bash':
    case 'run_command':
    case 'shell':
    case 'pwsh':
    case 'exec_command':
    case 'write_stdin':
      return ToolActivityCategory.commands;
    case 'python':
    case 'run_python':
    case 'run_code':
      return ToolActivityCategory.code;
    case 'web_search':
      return ToolActivityCategory.webSearch;
    case 'web_crawl':
    case 'web_fetch':
      return ToolActivityCategory.webFetch;
    case 'generate_image':
      return ToolActivityCategory.images;
    case 'ask_user':
    case 'ask_user_question':
    case 'request_user_input':
      return ToolActivityCategory.questions;
  }
  if (name.startsWith('terminal_')) return ToolActivityCategory.commands;
  if (name.startsWith('browser_')) return ToolActivityCategory.webFetch;
  return ToolActivityCategory.tools;
}

/// Whether a call of [category] writes something whose size and change
/// count are worth printing on its row.
bool isEditCategory(ToolActivityCategory category) =>
    category == ToolActivityCategory.write ||
    category == ToolActivityCategory.edit ||
    category == ToolActivityCategory.documents ||
    category == ToolActivityCategory.notes;

const Map<ToolActivityCategory, (String, String)> _englishLabels =
    <ToolActivityCategory, (String, String)>{
      ToolActivityCategory.read: ('Reading files', 'Read files'),
      ToolActivityCategory.readImage: ('Reading images', 'Read images'),
      ToolActivityCategory.search: ('Searching', 'Searched'),
      ToolActivityCategory.write: ('Writing files', 'Wrote files'),
      ToolActivityCategory.edit: ('Editing files', 'Edited files'),
      ToolActivityCategory.documents: ('Writing pages', 'Wrote pages'),
      ToolActivityCategory.notes: ('Updating notes', 'Updated notes'),
      ToolActivityCategory.commands: ('Running commands', 'Ran commands'),
      ToolActivityCategory.code: ('Running code', 'Ran code'),
      ToolActivityCategory.webSearch: ('Searching the web', 'Searched the web'),
      ToolActivityCategory.webFetch: ('Reading pages', 'Read pages'),
      ToolActivityCategory.images: ('Generating images', 'Generated images'),
      ToolActivityCategory.questions: (
        'Waiting for your answer',
        'Asked questions',
      ),
      ToolActivityCategory.tools: ('Calling tools', 'Called tools'),
    };

/// The l10n key stem of [category], e.g. `webSearch`.
String _keyOf(ToolActivityCategory category) => category.name;

/// "Searching the web" (running) or "Searched the web" (closed).
String toolCategoryLabel(
  ToolActivityCategory category, {
  required bool running,
  AppLocalizations? l10n,
}) {
  final (String run, String done) = _englishLabels[category]!;
  if (l10n == null) return running ? run : done;
  final String key = '${running ? 'run' : 'done'}_${_keyOf(category)}';
  final String text = l10n.toolActivityText(key);
  // A missing key comes back as the key itself; keep the English then.
  return text.startsWith('toolActivity_') ? (running ? run : done) : text;
}

/// Categories of [calls], ranked: most calls first, ties in order of first
/// use. Counts every call once (by id).
List<ToolActivityCategory> rankedCategories(Iterable<ToolCall> calls) {
  final Map<ToolActivityCategory, int> counts = <ToolActivityCategory, int>{};
  final Set<String> seen = <String>{};
  for (final ToolCall call in calls) {
    if (!seen.add(call.id)) continue;
    final ToolActivityCategory category = toolActivityCategoryOf(call.name);
    counts[category] = (counts[category] ?? 0) + 1;
  }
  // Map keys keep insertion order (first use); a stable sort keeps that
  // order for equal counts.
  final List<ToolActivityCategory> ranked = counts.keys.toList();
  _stableSort(ranked, (a, b) => counts[b]!.compareTo(counts[a]!));
  return ranked;
}

/// Insertion sort: stable, and the lists here have a handful of entries.
void _stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  for (int i = 1; i < list.length; i++) {
    final T item = list[i];
    int j = i - 1;
    while (j >= 0 && compare(list[j], item) > 0) {
      list[j + 1] = list[j];
      j--;
    }
    list[j + 1] = item;
  }
}

/// Most categories a closed group title names.
const int kMaxTitleCategories = 3;

/// The title of a CLOSED group of [calls]: "Searched the web", "Searched the
/// web and read pages", "Searched the web, read pages, ran commands", and
/// "…, etc." above three. Never a count.
String closedGroupTitle(Iterable<ToolCall> calls, [AppLocalizations? l10n]) {
  final List<ToolActivityCategory> ranked = rankedCategories(calls);
  if (ranked.isEmpty) {
    return _text(l10n, 'analysisDone', 'Analysis completed');
  }
  final List<String> labels = <String>[
    for (int i = 0; i < ranked.length && i < kMaxTitleCategories; i++)
      toolCategoryLabel(ranked[i], running: false, l10n: l10n),
  ];
  // Joined labels after the first start lower case in English and German
  // keeps its nouns; only lower the first letter when the label's second
  // letter is lower case too (so "Wrote" -> "wrote", never "API" -> "aPI").
  final List<String> joined = <String>[
    labels.first,
    for (final String label in labels.skip(1)) _lowerFirst(label, l10n),
  ];
  final String and = _text(l10n, 'and', 'and');
  String title;
  if (joined.length == 1) {
    title = joined.first;
  } else if (joined.length == 2) {
    title = '${joined[0]} $and ${joined[1]}';
  } else {
    title = joined.join(', ');
  }
  if (ranked.length > kMaxTitleCategories) {
    title = '$title, ${_text(l10n, 'etc', 'etc.')}';
  }
  return title;
}

/// The title of a RUNNING group: the category of the newest call still in
/// flight (by start time; a later call wins a tie), else the analysis label.
String runningGroupTitle(List<ToolCall> calls, [AppLocalizations? l10n]) {
  final ToolCall? live = liveCall(calls);
  if (live == null) return _text(l10n, 'analysis', 'Analyzing the request');
  return toolCategoryLabel(
    toolActivityCategoryOf(live.name),
    running: true,
    l10n: l10n,
  );
}

/// The newest call of [calls] that has no result yet, or null.
ToolCall? liveCall(List<ToolCall> calls) {
  ToolCall? best;
  for (final ToolCall call in calls) {
    final bool inFlight =
        call.status == ToolCallStatus.running ||
        call.status == ToolCallStatus.pending;
    if (!inFlight) continue;
    if (best == null || !call.startedAt.isBefore(best.startedAt)) best = call;
  }
  return best;
}

/// Argument keys that name what a call is about, in priority order (shared
/// by every tool, as in the harness).
const List<String> _detailKeys = <String>[
  'title',
  'description',
  'objective',
  'task',
  'name',
  'question',
  'prompt',
  'message',
  'command',
  'cmd',
  'queries',
  'query',
  'q',
  'pattern',
  'url',
  'uri',
  'file_path',
  'path',
  'filename',
  'target',
  'action',
];

/// Longest live detail, in characters, before it is cut with "…".
const int kMaxLiveDetailChars = 160;

/// What the newest running call is about ("pnpm test", a query, a path):
/// the first usable argument by [_detailKeys], whitespace collapsed and cut
/// at [kMaxLiveDetailChars]. Null when no call runs or none has a usable
/// argument.
String? liveDetail(List<ToolCall> calls) {
  final ToolCall? live = liveCall(calls);
  if (live == null) return null;
  return callDetail(live);
}

/// The detail of one call, see [liveDetail].
String? callDetail(ToolCall call) {
  for (final String key in _detailKeys) {
    final Object? value = call.arguments[key];
    String? text;
    if (value is String) {
      text = value;
    } else if (value is List &&
        value.isNotEmpty &&
        value.every((v) => v is String)) {
      text = value.cast<String>().join(', ');
    }
    if (text == null) continue;
    final String clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) continue;
    final List<int> runes = clean.runes.toList();
    if (runes.length <= kMaxLiveDetailChars) return clean;
    return '${String.fromCharCodes(runes.take(kMaxLiveDetailChars - 1)).trimRight()}…';
  }
  return null;
}

/// The file a write or edit call acts on, or null.
String? editTargetOf(ToolCall call) {
  for (final String key in const <String>[
    'file_path',
    'path',
    'filename',
    'file',
    'title',
    'artifact_id',
  ]) {
    final Object? value = call.arguments[key];
    if (value is String && value.trim().isNotEmpty) {
      final String trimmed = value.trim();
      // A path reads by its last segment; the full path is in the sheet.
      final int slash = trimmed.lastIndexOf('/');
      return slash >= 0 && slash < trimmed.length - 1
          ? trimmed.substring(slash + 1)
          : trimmed;
    }
  }
  return null;
}

/// Content keys a write or edit call carries its text in.
const List<String> _contentKeys = <String>[
  'content',
  'new_string',
  'old_string',
  'text',
  'body',
  'code',
  'patch',
  'edits',
];

/// Size of the text a write or edit call sends, in whole KB, rounded up
/// (UTF-16 length / 1024, old and new text summed for an edit). It is the
/// size of the input, not of the file. Null when the call carries no text.
int? editInputKb(ToolCall call) {
  int units = 0;
  bool any = false;
  for (final String key in _contentKeys) {
    final Object? value = call.arguments[key];
    if (value is String && value.isNotEmpty) {
      units += value.length;
      any = true;
    } else if (value is List) {
      for (final Object? item in value) {
        if (item is Map) {
          for (final Object? v in item.values) {
            if (v is String) {
              units += v.length;
              any = true;
            }
          }
        } else if (item is String) {
          units += item.length;
          any = true;
        }
      }
    }
  }
  if (!any) return null;
  return (units + 1023) ~/ 1024;
}

/// The row of a call that has not run yet: "Preparing: Edit intro.md 1KB".
/// Null for a call that is not pending.
String? preparingLabel(ToolCall call, [AppLocalizations? l10n]) {
  if (call.status != ToolCallStatus.pending) return null;
  final ToolActivityCategory category = toolActivityCategoryOf(call.name);
  final String verb = _preparingVerb(category, call.name, l10n);
  final List<String> parts = <String>[verb];
  if (isEditCategory(category)) {
    final String? target = editTargetOf(call);
    if (target != null) parts.add(target);
    final int? kb = editInputKb(call);
    if (kb != null) parts.add('${kb}KB');
  } else {
    final String? detail = callDetail(call);
    if (detail != null) parts.add(detail);
  }
  return '${_text(l10n, 'preparing', 'Preparing')}: ${parts.join(' ')}';
}

String _preparingVerb(
  ToolActivityCategory category,
  String name,
  AppLocalizations? l10n,
) {
  switch (category) {
    case ToolActivityCategory.read:
      return _text(l10n, 'verbRead', 'Read');
    case ToolActivityCategory.readImage:
      return _text(l10n, 'verbReadImage', 'Read image');
    case ToolActivityCategory.write:
      return _text(l10n, 'verbWrite', 'Write');
    case ToolActivityCategory.edit:
    case ToolActivityCategory.notes:
      return _text(l10n, 'verbEdit', 'Edit');
    case ToolActivityCategory.documents:
      return _text(l10n, 'verbPage', 'Page');
    case ToolActivityCategory.commands:
      return _text(l10n, 'verbRun', 'Run');
    case ToolActivityCategory.code:
      return _text(l10n, 'verbCode', 'Code');
    case ToolActivityCategory.webSearch:
    case ToolActivityCategory.search:
      return _text(l10n, 'verbSearch', 'Search');
    case ToolActivityCategory.webFetch:
      return _text(l10n, 'verbOpen', 'Open');
    case ToolActivityCategory.images:
      return _text(l10n, 'verbImage', 'Image');
    case ToolActivityCategory.questions:
      return _text(l10n, 'verbAsk', 'Ask');
    case ToolActivityCategory.tools:
      return name.replaceAll('_', ' ');
  }
}

String _text(AppLocalizations? l10n, String key, String english) {
  if (l10n == null) return english;
  final String text = l10n.toolActivityText(key);
  return text.startsWith('toolActivity_') ? english : text;
}

String _lowerFirst(String label, AppLocalizations? l10n) {
  if (l10n != null && l10n.locale.languageCode == 'de') return label;
  if (label.length < 2) return label;
  final String first = label[0];
  final String second = label[1];
  if (second.toLowerCase() != second) return label;
  return '${first.toLowerCase()}${label.substring(1)}';
}
