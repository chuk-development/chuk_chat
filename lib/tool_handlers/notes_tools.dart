import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const String _notesPrefsKey = 'tool_notes';

Future<String> executeNotes(Map<String, dynamic> args) async {
  final action = (args['action'] as String? ?? 'list').trim().toLowerCase();

  try {
    switch (action) {
      case 'save':
        return _saveNote(args);
      case 'get':
        return _getNote(args);
      case 'list':
        return _listNotes();
      case 'delete':
        return _deleteNote(args);
      case 'clear':
        return _clearNotes();
      default:
        return 'Error: Unknown action "$action". Use: save, get, list, '
            'delete, clear';
    }
  } catch (error) {
    return 'Notes error: $error';
  }
}

Future<Map<String, String>> _loadNotes() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_notesPrefsKey);
  if (raw == null || raw.trim().isEmpty) {
    return <String, String>{};
  }

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return <String, String>{};
    }

    return decoded.map((key, value) => MapEntry(key, value?.toString() ?? ''));
  } catch (_) {
    return <String, String>{};
  }
}

Future<void> _persistNotes(Map<String, String> notes) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_notesPrefsKey, jsonEncode(notes));
}

Future<String> _saveNote(Map<String, dynamic> args) async {
  final key = (args['key'] as String? ?? '').trim();
  final content = (args['content'] as String? ?? '').trim();

  if (key.isEmpty) {
    return 'Error: "key" parameter required';
  }
  if (content.isEmpty) {
    return 'Error: "content" parameter required';
  }

  final notes = await _loadNotes();
  final isUpdate = notes.containsKey(key);
  notes[key] = content;
  await _persistNotes(notes);

  if (isUpdate) {
    return 'Note "$key" updated. Total notes: ${notes.length}';
  }
  return 'Note "$key" saved. Total notes: ${notes.length}';
}

Future<String> _getNote(Map<String, dynamic> args) async {
  final key = (args['key'] as String? ?? '').trim();
  if (key.isEmpty) {
    return 'Error: "key" parameter required';
  }

  final notes = await _loadNotes();
  final exact = notes[key];
  if (exact != null) {
    return 'Note "$key":\n$exact';
  }

  final matches = notes.keys
      .where((k) => k.toLowerCase().contains(key.toLowerCase()))
      .toList();
  if (matches.isEmpty) {
    return 'No note found with key "$key".';
  }
  if (matches.length == 1) {
    final matchKey = matches.first;
    return 'Note "$matchKey":\n${notes[matchKey]}';
  }

  return 'No exact match for "$key". Did you mean: ${matches.join(', ')}?';
}

Future<String> _listNotes() async {
  final notes = await _loadNotes();
  if (notes.isEmpty) {
    return 'No notes saved yet.';
  }

  final buf = StringBuffer();
  buf.writeln('Saved notes (${notes.length}):');
  buf.writeln();
  for (final entry in notes.entries) {
    final preview = entry.value.length > 80
        ? '${entry.value.substring(0, 80)}...'
        : entry.value;
    buf.writeln('- ${entry.key}: $preview');
  }
  return buf.toString().trimRight();
}

Future<String> _deleteNote(Map<String, dynamic> args) async {
  final key = (args['key'] as String? ?? '').trim();
  if (key.isEmpty) {
    return 'Error: "key" parameter required';
  }

  final notes = await _loadNotes();
  if (!notes.containsKey(key)) {
    return 'No note found with key "$key"';
  }

  notes.remove(key);
  await _persistNotes(notes);
  return 'Note "$key" deleted. Remaining notes: ${notes.length}';
}

Future<String> _clearNotes() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_notesPrefsKey);
  return 'All notes cleared.';
}
