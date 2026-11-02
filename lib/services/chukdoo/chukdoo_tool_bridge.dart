// lib/services/chukdoo/chukdoo_tool_bridge.dart
//
// The connected Chukdoo account becomes ordinary tools, like a connected MCP
// server (lib/services/mcp/mcp_tool_bridge.dart): registered with the same
// executor, found through `find_tools`, routed by [ToolType.chukdoo] in
// `ToolExecutor.execute`.

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_connector.dart';
import 'package:chuk_chat/services/tool_executor.dart';

/// Register the Chukdoo tools when connected, remove them when not.
void syncChukdooTools(ToolExecutor executor) {
  for (final tool in executor.allRegisteredTools) {
    if (tool.type == ToolType.chukdoo) executor.unregisterTool(tool.name);
  }
  final connector = ChukdooConnector.instance;
  if (!connector.state.value.connected) return;
  for (final spec in connector.specs) {
    if (!isOfferedChukdooTool(spec.name)) continue;
    executor.registerTool(
      ClientTool(
        name: '${ChukdooConnector.toolPrefix}${spec.name}',
        description: spec.name == 'update_note'
            ? '${ChukdooConnector.displayName}: Change a note: title, folder, '
                  'pinned, or append text at the end.'
            : '${ChukdooConnector.displayName}: ${spec.description}',
        parameters: spec.name == 'update_note'
            ? _withoutProperty(spec.inputSchema, 'content')
            : spec.inputSchema,
        type: ToolType.chukdoo,
        tags: chukdooToolTags(spec.name),
      ),
    );
  }
}

/// The hard deletes (`delete_todo`, `delete_note`, `delete_event`,
/// `delete_habit`) are held back: they remove server rows for good, other
/// devices keep stale copies (chukdoo does not sync deletions yet), and the
/// tool loop has no per-call approval step, so a crawled page with injected
/// instructions could make the model wipe data. Bead chuk_chat-e4a7 tracks the
/// approval step that would let them in.
/// For the same reason `update_note` is offered without `content` (which
/// replaces the whole body); `append` stays.
bool isOfferedChukdooTool(String toolName) => !toolName.startsWith('delete_');

/// Whether a call of [toolName] with [args] would destroy data the same way
/// a held-back tool does.
bool isDestructiveChukdooCall(String toolName, Map<String, dynamic> args) =>
    !isOfferedChukdooTool(toolName) ||
    (toolName == 'update_note' && args.containsKey('content'));

Map<String, dynamic> _withoutProperty(
  Map<String, dynamic> schema,
  String key,
) {
  final props = Map<String, dynamic>.from(
    schema['properties'] as Map? ?? const <String, dynamic>{},
  )..remove(key);
  return <String, dynamic>{...schema, 'properties': props};
}

/// Keep [executor] in step with the connector for as long as it lives.
void watchChukdooConnector(ToolExecutor executor) {
  ChukdooConnector.instance.state.addListener(() => syncChukdooTools(executor));
}

/// What `find_tools` matches on: the connector, the words of the tool name,
/// and the everyday words (English and German) for what the tool touches.
List<String> chukdooToolTags(String toolName) {
  final words = toolName
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2)
      .toList();
  final tags = <String>{'chukdoo', 'connector', ...words};
  for (final word in words) {
    tags.addAll(_topicTags[word] ?? const <String>[]);
  }
  return tags.toList();
}

const Map<String, List<String>> _topicTags = {
  'todo': _todoTags,
  'todos': _todoTags,
  'project': ['project', 'projects', 'projekt', 'projekte', ..._todoTags],
  'projects': ['project', 'projects', 'projekt', 'projekte', ..._todoTags],
  'event': _calendarTags,
  'events': _calendarTags,
  'calendars': _calendarTags,
  'note': _noteTags,
  'notes': _noteTags,
  'folders': _noteTags,
  'habit': _habitTags,
  'habits': _habitTags,
  'overview': [
    'overview',
    'today',
    'heute',
    'agenda',
    'schedule',
    'plan',
    'tag',
    ..._todoTags,
    ..._calendarTags,
  ],
};

const List<String> _todoTags = [
  'todo',
  'todos',
  'task',
  'tasks',
  'aufgabe',
  'aufgaben',
  'reminder',
  'erinnerung',
];
const List<String> _calendarTags = [
  'calendar',
  'kalender',
  'event',
  'events',
  'termin',
  'termine',
  'meeting',
  'appointment',
];
const List<String> _noteTags = ['note', 'notes', 'notiz', 'notizen'];
const List<String> _habitTags = [
  'habit',
  'habits',
  'gewohnheit',
  'gewohnheiten',
  'streak',
];
