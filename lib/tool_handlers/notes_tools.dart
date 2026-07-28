import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_diff_engine.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';

const String _notesPrefsKey = 'tool_notes'; // legacy key-value store
const String _memoryPrefsKey = 'identity_memory'; // new free-text store
const String _soulPrefsKey = 'identity_soul';
const String _userInfoPrefsKey = 'identity_user';
const String _identityEnabledKey = 'identity_enabled';

const String _identitySoulColumn = 'identity_soul';
const String _identityUserColumn = 'identity_user';
const String _identityMemoryColumn = 'identity_memory';
const String _identityEnabledColumn = 'identity_enabled';
const String _legacyPreferencesColumn = 'preferences';
const String _selectedModelColumn = 'selected_model_id';
const String _fallbackSelectedModelId = 'moonshotai/kimi-k2.5';

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
  _invalidateIdentityCache();
}

void _invalidateIdentityCache() {
  _cachedIdentityRow = null;
  _cachedIdentityFetchedAt = null;
  _identityRowInFlight = null;
}

Future<Map<String, dynamic>?> _loadIdentityRowFromSupabase({
  bool forceRefresh = false,
}) async {
  final userId = _safeCurrentUserId();
  if (userId == null) {
    return null;
  }

  _resetIdentityCacheForUser(userId);

  if (forceRefresh) {
    _invalidateIdentityCache();
  }

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
    } on PostgrestException catch (error) {
      if (_isMissingIdentityColumnsError(error)) {
        final legacy = await _loadIdentityRowFromLegacyPreferences(userId);
        if (legacy != null) {
          _cachedIdentityFetchedAt = DateTime.now();
          _cachedIdentityRow = Map<String, dynamic>.from(legacy);
          return Map<String, dynamic>.from(legacy);
        }
      }

      if (kDebugMode) {
        debugPrint('Failed to load identity row from Supabase: $error');
      }
      return null;
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

  // user_preferences.selected_model_id is NOT NULL.
  // Include it so identity upserts can also create missing rows reliably.
  final selectedModelId = await _resolveSelectedModelIdForUpsert(userId);
  if (selectedModelId != null && selectedModelId.isNotEmpty) {
    payload[_selectedModelColumn] = selectedModelId;
  }

  try {
    await SupabaseService.client
        .from('user_preferences')
        .upsert(payload, onConflict: 'user_id');
    _mergeIdentityCache(userId, fields);
    return true;
  } on PostgrestException catch (error) {
    if (_isMissingIdentityColumnsError(error)) {
      return _upsertIdentityFieldsLegacy(userId, fields);
    }

    if (kDebugMode) {
      debugPrint('Failed to sync identity fields to Supabase: $error');
    }
    return false;
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Failed to sync identity fields to Supabase: $error');
    }
    return false;
  }
}

Future<String?> _resolveSelectedModelIdForUpsert(String userId) async {
  try {
    final row = await SupabaseService.client
        .from('user_preferences')
        .select(_selectedModelColumn)
        .eq('user_id', userId)
        .maybeSingle();

    final existing = (row?[_selectedModelColumn] as String?)?.trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
  } catch (_) {
    // Fall through to local/default fallback.
  }

  try {
    final local = (await UserPreferencesService.loadSelectedModel())?.trim();
    if (local != null && local.isNotEmpty) {
      return local;
    }
  } catch (_) {
    // Fall through to default model.
  }

  return _fallbackSelectedModelId;
}

Future<bool> _upsertIdentityFieldsLegacy(
  String userId,
  Map<String, dynamic> fields,
) async {
  try {
    final existing = await SupabaseService.client
        .from('user_preferences')
        .select(_legacyPreferencesColumn)
        .eq('user_id', userId)
        .maybeSingle();

    final preferences = _extractLegacyPreferencesMap(
      existing?[_legacyPreferencesColumn],
    );

    for (final entry in fields.entries) {
      switch (entry.key) {
        case _identitySoulColumn:
        case _identityUserColumn:
        case _identityMemoryColumn:
          final rawValue = entry.value?.toString();
          final value = rawValue?.trim();
          if (value == null || value.isEmpty) {
            preferences.remove(entry.key);
          } else {
            preferences[entry.key] = value;
          }
          break;
        case _identityEnabledColumn:
          final parsed = _coerceIdentityEnabled(entry.value);
          if (parsed == null) {
            preferences.remove(entry.key);
          } else {
            preferences[entry.key] = parsed;
          }
          break;
      }
    }

    await SupabaseService.client.from('user_preferences').upsert({
      'user_id': userId,
      _legacyPreferencesColumn: preferences,
    }, onConflict: 'user_id');

    _mergeIdentityCache(userId, fields);
    return true;
  } on PostgrestException catch (error) {
    if (kDebugMode) {
      if (_isMissingLegacyPreferencesError(error)) {
        debugPrint(
          'Legacy preferences fallback unavailable (missing column): $error',
        );
      } else {
        debugPrint('Failed to sync identity fallback fields: $error');
      }
    }
    return false;
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Failed to sync identity fallback fields: $error');
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

  if (!_looksLikeEncryptedPayload(raw)) {
    return raw;
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
  if (remoteRow == null) {
    return localValue;
  }

  if (!remoteRow.containsKey(remoteColumn)) {
    if (!hasSyncedBefore && localValue.isNotEmpty) {
      await _saveIdentityText(
        localKey: localKey,
        remoteColumn: remoteColumn,
        text: localValue,
      );
    }
    return localValue;
  }

  Future<String> handleRemoteEmpty() async {
    if (!hasSyncedBefore) {
      if (localValue.isNotEmpty) {
        await _saveIdentityText(
          localKey: localKey,
          remoteColumn: remoteColumn,
          text: localValue,
        );
      }
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

bool _looksLikeEncryptedPayload(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return false;
    }

    return decoded['v'] != null &&
        decoded['nonce'] != null &&
        decoded['ciphertext'] != null &&
        decoded['mac'] != null;
  } catch (_) {
    return false;
  }
}

bool _isMissingIdentityColumnsError(PostgrestException error) {
  final code = error.code?.toLowerCase() ?? '';
  final message = error.message.toLowerCase();

  final hasMissingColumnSignal =
      code == '42703' || message.contains('does not exist');
  if (!hasMissingColumnSignal) {
    return false;
  }

  return message.contains(_identitySoulColumn) ||
      message.contains(_identityUserColumn) ||
      message.contains(_identityMemoryColumn) ||
      message.contains(_identityEnabledColumn);
}

bool _isMissingLegacyPreferencesError(PostgrestException error) {
  final code = error.code?.toLowerCase() ?? '';
  final message = error.message.toLowerCase();

  final hasMissingColumnSignal =
      code == '42703' || message.contains('does not exist');
  if (!hasMissingColumnSignal) {
    return false;
  }

  return message.contains(_legacyPreferencesColumn);
}

Map<String, dynamic> _extractLegacyPreferencesMap(dynamic rawPreferences) {
  if (rawPreferences is Map<String, dynamic>) {
    return Map<String, dynamic>.from(rawPreferences);
  }

  if (rawPreferences is Map) {
    return rawPreferences.map((key, value) => MapEntry(key.toString(), value));
  }

  if (rawPreferences is String && rawPreferences.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(rawPreferences);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  return <String, dynamic>{};
}

bool? _coerceIdentityEnabled(dynamic raw) {
  if (raw is bool) {
    return raw;
  }

  if (raw is String) {
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
  }

  return null;
}

Future<Map<String, dynamic>?> _loadIdentityRowFromLegacyPreferences(
  String userId,
) async {
  try {
    final response = await SupabaseService.client
        .from('user_preferences')
        .select(_legacyPreferencesColumn)
        .eq('user_id', userId)
        .maybeSingle();

    final preferences = _extractLegacyPreferencesMap(
      response?[_legacyPreferencesColumn],
    );

    final row = <String, dynamic>{};
    if (preferences.containsKey(_identitySoulColumn)) {
      row[_identitySoulColumn] = preferences[_identitySoulColumn];
    }
    if (preferences.containsKey(_identityUserColumn)) {
      row[_identityUserColumn] = preferences[_identityUserColumn];
    }
    if (preferences.containsKey(_identityMemoryColumn)) {
      row[_identityMemoryColumn] = preferences[_identityMemoryColumn];
    }

    final enabled = _coerceIdentityEnabled(preferences[_identityEnabledColumn]);
    if (enabled != null) {
      row[_identityEnabledColumn] = enabled;
    }

    return row;
  } on PostgrestException catch (error) {
    if (kDebugMode && !_isMissingLegacyPreferencesError(error)) {
      debugPrint('Failed to load legacy identity row from Supabase: $error');
    }
    return null;
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Failed to load legacy identity row from Supabase: $error');
    }
    return null;
  }
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
    final synced = await _upsertIdentityFields({remoteColumn: null});
    if (!synced) {
      throw StateError('Failed to sync identity field "$remoteColumn"');
    }
    await prefs.remove(localKey);
    await prefs.setBool(syncedMarkerKey, true);
    return;
  }

  final encrypted = await EncryptionService.encrypt(trimmed);
  final synced = await _upsertIdentityFields({remoteColumn: encrypted});
  if (!synced) {
    throw StateError('Failed to sync identity field "$remoteColumn"');
  }
  await prefs.setString(localKey, trimmed);
  await prefs.setBool(syncedMarkerKey, true);
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

  final remote = _coerceIdentityEnabled(remoteRow[_identityEnabledColumn]);
  if (remote == null) {
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

/// Sync identity data (Soul/User/Memory/toggle) from Supabase into
/// local SharedPreferences.
///
/// This keeps mobile and desktop in sync even if the identity settings page
/// has not been opened yet.
Future<void> syncIdentityFromSupabase({bool forceRefresh = false}) async {
  if (forceRefresh) {
    _invalidateIdentityCache();
  }

  try {
    await Future.wait<void>([
      loadSoulText().then((_) {}),
      loadUserInfoText().then((_) {}),
      loadMemoryText().then((_) {}),
      isIdentityEnabled().then((_) {}),
    ]);
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Failed to sync identity from Supabase: $error');
    }
  }
}

Future<String> executeNotes(Map<String, dynamic> args) async {
  final action = (args['action'] as String? ?? 'list').trim().toLowerCase();

  try {
    switch (action) {
      case 'update_memory':
        return await _updateMemory(args);
      case 'update_user':
        return await _updateUserInfo(args);
      case 'update_soul':
        return await _updateSoul(args);
      case 'patch_memory':
        return await _patchMemory(args);
      case 'patch_user':
        return await _patchUserInfo(args);
      case 'patch_soul':
        return await _patchSoul(args);
      // Legacy key-value actions (still supported).
      case 'save':
        return await _saveNote(args);
      case 'get':
        return await _getNote(args);
      case 'list':
        return _listNotes();
      case 'delete':
        return await _deleteNote(args);
      case 'clear':
        return _clearNotes();
      default:
        return 'Error: Unknown action "$action". Use: update_memory, '
            'update_user, update_soul, patch_memory, patch_user, patch_soul';
    }
  } catch (error) {
    return 'Notes error: $error';
  }
}

/// Builds a <diff> visual block showing what changed.
String _buildDiffResult(
  String type,
  String title,
  String before,
  String after,
) {
  final diffJson = jsonEncode({
    'type': type,
    'title': '$title updated',
    'before': before,
    'after': after,
  });
  return '<diff>$diffJson</diff>';
}

/// Parse `edits` arg into a list of [ArtifactEdit].
List<ArtifactEdit>? _parseEdits(dynamic rawEdits) {
  if (rawEdits is! List) return null;
  final edits = <ArtifactEdit>[];
  for (final e in rawEdits) {
    if (e is Map<String, dynamic>) edits.add(ArtifactEdit.fromMap(e));
  }
  return edits.isEmpty ? null : edits;
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
  final before = await loadUserInfoText();
  await saveUserInfoText(content);
  return _buildDiffResult('user_info', 'User Info', before, content);
}

/// AI action: apply targeted edits to the user info text.
Future<String> _patchUserInfo(Map<String, dynamic> args) async {
  final edits = _parseEdits(args['edits']);
  if (edits == null) {
    return 'Error: "edits" must be a non-empty list of '
        '{old_str, new_str} objects for patch_user';
  }
  final before = await loadUserInfoText();
  final after = ArtifactDiffEngine.applyEdits(before, edits);
  await saveUserInfoText(after);
  return _buildDiffResult('user_info', 'User Info', before, after);
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
  final before = await loadMemoryText();
  await saveMemoryText(content);
  return _buildDiffResult('memory', 'Memory', before, content);
}

/// AI action: apply targeted edits to the memory text.
Future<String> _patchMemory(Map<String, dynamic> args) async {
  final edits = _parseEdits(args['edits']);
  if (edits == null) {
    return 'Error: "edits" must be a non-empty list of '
        '{old_str, new_str} objects for patch_memory';
  }
  final before = await loadMemoryText();
  final after = ArtifactDiffEngine.applyEdits(before, edits);
  await saveMemoryText(after);
  return _buildDiffResult('memory', 'Memory', before, after);
}

/// AI action: update the soul (personality) text.
/// The prompt instructs the AI to always inform the user when doing this.
Future<String> _updateSoul(Map<String, dynamic> args) async {
  final content = (args['content'] as String? ?? '').trim();
  if (content.isEmpty) {
    return 'Error: "content" parameter required for update_soul';
  }
  final before = await loadSoulText();
  await saveSoulText(content);
  final diff = _buildDiffResult('soul', 'Soul', before, content);
  return '$diff\nIMPORTANT: Tell the user what you changed and why.';
}

/// AI action: apply targeted edits to the soul text.
Future<String> _patchSoul(Map<String, dynamic> args) async {
  final edits = _parseEdits(args['edits']);
  if (edits == null) {
    return 'Error: "edits" must be a non-empty list of '
        '{old_str, new_str} objects for patch_soul';
  }
  final before = await loadSoulText();
  final after = ArtifactDiffEngine.applyEdits(before, edits);
  await saveSoulText(after);
  final diff = _buildDiffResult('soul', 'Soul', before, after);
  return '$diff\nIMPORTANT: Tell the user what you changed and why.';
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
