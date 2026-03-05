import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

const String _notesPrefsKey = 'tool_notes'; // legacy key-value store
const String _memoryPrefsKey = 'identity_memory'; // new free-text store
const String _soulPrefsKey = 'identity_soul';
const String _userInfoPrefsKey = 'identity_user';
const String _identityEnabledKey = 'identity_enabled';

const String _identitySoulColumn = 'identity_soul';
const String _identityUserColumn = 'identity_user';
const String _identityMemoryColumn = 'identity_memory';
const String _identityEnabledColumn = 'identity_enabled';

const Duration _identitySyncCacheTtl = Duration(minutes: 1);

Map<String, dynamic>? _cachedIdentityRow;
String? _cachedIdentityUserId;
DateTime? _cachedIdentityFetchedAt;
Future<Map<String, dynamic>?>? _identityRowInFlight;

String? _safeCurrentUserId() {
  try {
    return SupabaseService.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

Session? _safeCurrentSession() {
  try {
    return SupabaseService.auth.currentSession;
  } catch (_) {
    return null;
  }
}

void _resetIdentityCacheForUser(String? userId) {
  if (_cachedIdentityUserId == userId) {
    return;
  }
  _cachedIdentityUserId = userId;
  _cachedIdentityRow = null;
  _cachedIdentityFetchedAt = null;
  _identityRowInFlight = null;
}

Future<Map<String, dynamic>?> _loadIdentityRowFromSupabase() async {
  final userId = _safeCurrentUserId();
  if (userId == null) {
    return null;
  }

  _resetIdentityCacheForUser(userId);

  final now = DateTime.now();
  if (_cachedIdentityRow != null &&
      _cachedIdentityFetchedAt != null &&
      now.difference(_cachedIdentityFetchedAt!) < _identitySyncCacheTtl) {
    return Map<String, dynamic>.from(_cachedIdentityRow!);
  }

  if (_identityRowInFlight != null) {
    return await _identityRowInFlight!;
  }

  Future<Map<String, dynamic>?> fetch() async {
    try {
      final response = await SupabaseService.client
          .from('user_preferences')
          .select(
            '$_identitySoulColumn,$_identityUserColumn,$_identityMemoryColumn,$_identityEnabledColumn',
          )
          .eq('user_id', userId)
          .maybeSingle();

      _cachedIdentityFetchedAt = DateTime.now();
      _cachedIdentityRow = response == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(response);
      return response == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(response);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to load identity row from Supabase: $error');
      }
      return null;
    }
  }

  try {
    _identityRowInFlight = fetch();
    final result = await _identityRowInFlight!;
    _identityRowInFlight = null;
    return result;
  } catch (_) {
    _identityRowInFlight = null;
    rethrow;
  }
}

void _mergeIdentityCache(String userId, Map<String, dynamic> updates) {
  _resetIdentityCacheForUser(userId);
  _cachedIdentityRow ??= <String, dynamic>{};
  _cachedIdentityRow!.addAll(updates);
  _cachedIdentityFetchedAt = DateTime.now();
}

String _identitySyncedMarkerKey(String localKey) =>
    '${localKey}_synced_to_supabase';

Future<bool> _upsertIdentityFields(Map<String, dynamic> fields) async {
  final session = _safeCurrentSession();
  if (session == null) {
    return false;
  }

  final userId = session.user.id;
  final payload = <String, dynamic>{'user_id': userId, ...fields};

  try {
    await SupabaseService.client
        .from('user_preferences')
        .upsert(payload, onConflict: 'user_id');
    _mergeIdentityCache(userId, fields);
    return true;
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Failed to sync identity fields to Supabase: $error');
    }
    return false;
  }
}

Future<String?> _decryptIdentityValue(
  dynamic encryptedValue, {
  required String column,
}) async {
  if (encryptedValue == null) {
    return null;
  }

  final raw = encryptedValue.toString();
  if (raw.trim().isEmpty) {
    return '';
  }

  try {
    return await EncryptionService.decrypt(raw);
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Failed to decrypt $column from Supabase: $error');
    }
    return null;
  }
}

Future<String> _loadIdentityText({
  required String localKey,
  required String remoteColumn,
  String? localOverride,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final localValue = localOverride ?? (prefs.getString(localKey) ?? '');
  final syncedMarkerKey = _identitySyncedMarkerKey(localKey);
  final hasSyncedBefore = prefs.getBool(syncedMarkerKey) ?? false;

  final remoteRow = await _loadIdentityRowFromSupabase();
  if (remoteRow == null || !remoteRow.containsKey(remoteColumn)) {
    return localValue;
  }

  Future<String> handleRemoteEmpty() async {
    if (!hasSyncedBefore) {
      return localValue;
    }

    if (localValue.isNotEmpty) {
      await prefs.remove(localKey);
    }
    return '';
  }

  final remoteRaw = remoteRow[remoteColumn];
  if (remoteRaw == null) {
    return handleRemoteEmpty();
  }

  if (remoteRaw.toString().trim().isEmpty) {
    return handleRemoteEmpty();
  }

  final decryptedRemote = await _decryptIdentityValue(
    remoteRaw,
    column: remoteColumn,
  );
  if (decryptedRemote == null) {
    return localValue;
  }

  if (decryptedRemote.isEmpty) {
    return handleRemoteEmpty();
  }

  if (decryptedRemote != localValue) {
    await prefs.setString(localKey, decryptedRemote);
  }
  await prefs.setBool(syncedMarkerKey, true);

  return decryptedRemote;
}

Future<void> _saveIdentityText({
  required String localKey,
  required String remoteColumn,
  required String text,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final trimmed = text.trim();
  final syncedMarkerKey = _identitySyncedMarkerKey(localKey);

  if (trimmed.isEmpty) {
    await prefs.remove(localKey);
    final synced = await _upsertIdentityFields({remoteColumn: null});
    if (synced) {
      await prefs.setBool(syncedMarkerKey, true);
    }
    return;
  }

  await prefs.setString(localKey, trimmed);

  try {
    final encrypted = await EncryptionService.encrypt(trimmed);
    final synced = await _upsertIdentityFields({remoteColumn: encrypted});
    if (synced) {
      await prefs.setBool(syncedMarkerKey, true);
    }
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Failed to encrypt/sync $remoteColumn: $error');
    }
  }
}

Future<String> _loadLocalMemoryText(SharedPreferences prefs) async {
  final local = prefs.getString(_memoryPrefsKey);
  if (local != null) {
    return local;
  }

  // Migrate legacy key-value notes to free text (one-time).
  final legacyRaw = prefs.getString(_notesPrefsKey);
  if (legacyRaw == null || legacyRaw.trim().isEmpty) {
    return '';
  }

  try {
    final decoded = jsonDecode(legacyRaw);
    if (decoded is Map<String, dynamic> && decoded.isNotEmpty) {
      final buffer = StringBuffer();
      for (final entry in decoded.entries) {
        buffer.writeln('- ${entry.key}: ${entry.value}');
      }
      final migrated = buffer.toString().trim();
      await prefs.setString(_memoryPrefsKey, migrated);
      await prefs.remove(_notesPrefsKey);
      return migrated;
    }
  } catch (_) {
    // Ignore legacy parse failures and keep memory empty.
  }

  return '';
}

/// Whether the identity system (Soul / User / Memory) is active.
///
/// This read also syncs the local toggle with the remote value when available.
Future<bool> isIdentityEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  final local = prefs.getBool(_identityEnabledKey) ?? true;

  final remoteRow = await _loadIdentityRowFromSupabase();
  if (remoteRow == null || !remoteRow.containsKey(_identityEnabledColumn)) {
    return local;
  }

  final remote = remoteRow[_identityEnabledColumn];
  if (remote is! bool) {
    return local;
  }

  if (remote != local) {
    await prefs.setBool(_identityEnabledKey, remote);
  }

  return remote;
}

/// Persist the identity system toggle.
Future<void> setIdentityEnabled(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_identityEnabledKey, value);
  await _upsertIdentityFields({_identityEnabledColumn: value});
}

Future<String> executeNotes(Map<String, dynamic> args) async {
  final action = (args['action'] as String? ?? 'list').trim().toLowerCase();

  try {
    switch (action) {
      case 'update_memory':
        return _updateMemory(args);
      case 'update_user':
        return _updateUserInfo(args);
      case 'update_soul':
        return _updateSoul(args);
      // Legacy key-value actions (still supported).
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
        return 'Error: Unknown action "$action". Use: update_memory, '
            'update_user, update_soul';
    }
  } catch (error) {
    return 'Notes error: $error';
  }
}

// ─── Soul (personality) — AI can update but must inform the user ──────

/// Load Soul text. Public for system prompt injection.
Future<String> loadSoulText() async {
  return _loadIdentityText(
    localKey: _soulPrefsKey,
    remoteColumn: _identitySoulColumn,
  );
}

/// Save Soul text. Called from settings UI.
Future<void> saveSoulText(String text) async {
  await _saveIdentityText(
    localKey: _soulPrefsKey,
    remoteColumn: _identitySoulColumn,
    text: text,
  );
}

// ─── User info — AI can update via tool, user can edit in settings ────

/// Load User info text. Public for system prompt injection.
Future<String> loadUserInfoText() async {
  return _loadIdentityText(
    localKey: _userInfoPrefsKey,
    remoteColumn: _identityUserColumn,
  );
}

/// Save User info text. Called from settings UI or AI tool.
Future<void> saveUserInfoText(String text) async {
  await _saveIdentityText(
    localKey: _userInfoPrefsKey,
    remoteColumn: _identityUserColumn,
    text: text,
  );
}

/// AI action: update the user info text.
Future<String> _updateUserInfo(Map<String, dynamic> args) async {
  final content = (args['content'] as String? ?? '').trim();
  if (content.isEmpty) {
    return 'Error: "content" parameter required for update_user';
  }
  await saveUserInfoText(content);
  return 'User info updated (${content.length} chars).';
}

// ─── Memory (long-term knowledge) — free-text, AI can update ─────────

/// Load Memory text, with one-time migration from legacy key-value store.
Future<String> loadMemoryText() async {
  final prefs = await SharedPreferences.getInstance();
  final localMemory = await _loadLocalMemoryText(prefs);
  return _loadIdentityText(
    localKey: _memoryPrefsKey,
    remoteColumn: _identityMemoryColumn,
    localOverride: localMemory,
  );
}

/// Save Memory text. Called from settings UI.
Future<void> saveMemoryText(String text) async {
  await _saveIdentityText(
    localKey: _memoryPrefsKey,
    remoteColumn: _identityMemoryColumn,
    text: text,
  );
}

/// AI action: update the memory text.
Future<String> _updateMemory(Map<String, dynamic> args) async {
  final content = (args['content'] as String? ?? '').trim();
  if (content.isEmpty) {
    return 'Error: "content" parameter required for update_memory';
  }
  await saveMemoryText(content);
  return 'Memory updated (${content.length} chars).';
}

/// AI action: update the soul (personality) text.
/// The prompt instructs the AI to always inform the user when doing this.
Future<String> _updateSoul(Map<String, dynamic> args) async {
  final content = (args['content'] as String? ?? '').trim();
  if (content.isEmpty) {
    return 'Error: "content" parameter required for update_soul';
  }
  await saveSoulText(content);
  return 'Soul updated (${content.length} chars). '
      'IMPORTANT: Tell the user what you changed and why.';
}

/// Load all saved notes. Public so the system prompt builder can inject them.
Future<Map<String, String>> loadAllNotes() async {
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

  final notes = await loadAllNotes();
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

  final notes = await loadAllNotes();
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
  final notes = await loadAllNotes();
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

  final notes = await loadAllNotes();
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
