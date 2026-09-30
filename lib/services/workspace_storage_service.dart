// lib/services/workspace_storage_service.dart
// MERGE NOTE: the Agents build stubbed this file (empty project list, every
// mutation a no-op) because its sidebar listed coworkers, not projects.
// Upstream's Supabase-backed workspace store is kept whole.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/encrypted_meta.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/file_conversion_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// One `projects` / `project_files` row after its `encrypted_meta` envelope
/// was opened. See [WorkspaceStorageService.resolveSealedRow].
typedef SealedRowRead = ({
  /// The row with every sealed field resolved; safe for `fromJson`.
  Map<String, dynamic> row,

  /// The envelope exists but cannot be opened (sealed with another key).
  /// Such a row must never be written back sealed.
  bool undecryptable,

  /// The row has no envelope yet.
  bool legacy,

  /// The row is legacy or holds real plaintext in a sealed column.
  bool needsReseal,
});

/// One row to write again sealed: a snapshot of the row as it was read.
/// The values and the `updated_at` stamp come from the same read, so the
/// write (guarded by that stamp) never replaces a newer edit.
@visibleForTesting
class ResealJob {
  const ResealJob({
    required this.id,
    required this.workspaceId,
    required this.legacy,
    required this.updatedAt,
    required this.values,
  });

  final String id;

  /// Set for a `project_files` row: the workspace that holds the file.
  final String? workspaceId;

  /// The row had no envelope when it was read.
  final bool legacy;

  /// `updated_at` exactly as the server sent it. Never rebuilt from a
  /// DateTime: format or precision drift would make the guard miss.
  final String updatedAt;

  /// Resolved (decrypted) values of the sealed fields.
  final Map<String, String?> values;

  bool get isFile => workspaceId != null;
  String get table => isFile ? 'project_files' : 'projects';
  String get key => isFile ? 'file:$id' : 'project:$id';
}

/// Service for managing workspace workspaces, chat assignments, and file attachments
class WorkspaceStorageService {
  static const String bucketName = 'workspace-files';
  static const String _cacheKey = 'cached_projects';
  static const Uuid _uuid = Uuid();

  static const String _projectsTable = 'projects';
  static const String _filesTable = 'project_files';

  /// `projects` columns whose values live in `encrypted_meta`.
  @visibleForTesting
  static const List<String> projectSealedFields = [
    'name',
    'description',
    'custom_system_prompt',
  ];

  /// `project_files` columns whose values live in `encrypted_meta`.
  @visibleForTesting
  static const List<String> fileSealedFields = [
    'file_name',
    'markdown_summary',
  ];

  // SINGLE SOURCE OF TRUTH - all projects stored here
  static final Map<String, Workspace> _projectsById = <String, Workspace>{};
  static bool _cacheLoaded = false;
  static bool _isLoadingFromNetwork = false;

  // Rows whose envelope could not be opened on the last load. They are shown
  // with the placeholder and never written back sealed: that would replace
  // the sealed values, which another key can still open, with placeholders.
  static final Set<String> _undecryptableProjectIds = <String>{};
  static final Set<String> _undecryptableFileIds = <String>{};

  // Background re-seal of legacy / old-build rows. Each row is tried at most
  // once per session; the runs are chained so they never overlap.
  static final Set<String> _resealAttempted = <String>{};
  static Future<void> _resealChain = Future<void>.value();
  static bool _resealDisabled = false;

  // Prevent concurrent loadProjects() calls
  static Completer<void>? _loadingCompleter;
  static bool get _isLoading =>
      _loadingCompleter != null && !_loadingCompleter!.isCompleted;

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  // Debounce for _notifyChanges to prevent rapid-fire UI rebuilds
  static Timer? _notifyDebounceTimer;
  static bool _hasPendingNotification = false;
  static const Duration _notifyDebounceDelay = Duration(milliseconds: 100);

  // Currently selected workspace (for chat UI context)
  static String? selectedWorkspaceId;

  // Get projects as a sorted list (most recent first)
  static List<Workspace> get projects {
    final list = _projectsById.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  // Get non-archived projects
  static List<Workspace> get activeProjects {
    return projects.where((p) => !p.isArchived).toList();
  }

  // Get archived projects
  static List<Workspace> get archivedProjects {
    return projects.where((p) => p.isArchived).toList();
  }

  static Stream<void> get changes => _changesController.stream;

  /// Notify listeners of changes with debouncing to prevent rapid-fire UI rebuilds.
  /// Only saves to cache if explicitly requested and not during network loading.
  static void _notifyChanges({bool updateCache = true}) {
    if (_changesController.isClosed) return;

    _hasPendingNotification = true;

    // Cancel existing timer
    _notifyDebounceTimer?.cancel();

    // Start new debounce timer
    _notifyDebounceTimer = Timer(_notifyDebounceDelay, () {
      if (_changesController.isClosed) return;
      if (_hasPendingNotification) {
        _changesController.add(null);
        _hasPendingNotification = false;
      }
    });

    // Auto-save to cache when data changes (but not during network load - that saves at the end)
    if (updateCache && _cacheLoaded && !_isLoadingFromNetwork) {
      unawaited(_saveToCache());
    }
  }

  /// Notify immediately without debounce (for critical updates like initial cache load)
  static void _notifyChangesImmediate() {
    if (!_changesController.isClosed) {
      _changesController.add(null);
    }
  }

  // ============ LOCAL CACHE ============

  /// Load projects from local cache (fast, for instant UI)
  static Future<void> loadFromCache() async {
    if (_cacheLoaded) return;

    try {
      final cached = await LocalChatCacheService.kvGet(_cacheKey);
      if (cached != null && cached.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(cached);
        _projectsById.clear();
        for (final json in jsonList) {
          final workspace = Workspace.fromJson(json);
          _projectsById[workspace.id] = workspace;
        }
        if (kDebugMode) {
          debugPrint(
            '✅ [ProjectStorage] Loaded ${_projectsById.length} projects from cache',
          );
        }
        _cacheLoaded = true;
        _notifyChangesImmediate();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] Failed to load cache: $e');
      }
    }
  }

  /// Save projects to local cache
  static Future<void> _saveToCache() async {
    try {
      final jsonList = _projectsById.values.map((p) => p.toJson()).toList();
      await LocalChatCacheService.kvSet(_cacheKey, jsonEncode(jsonList));
      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Saved ${jsonList.length} projects to cache',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] Failed to save cache: $e');
      }
    }
  }

  // ============ SEALED ROW METADATA (encrypted_meta) ============
  //
  // Project name, description and system prompt, and project file name and
  // text, travel in one encrypted envelope per row. The plaintext columns
  // keep the placeholder (NOT NULL / non-empty ones) or NULL. The model and
  // the local cache hold the decrypted values; nothing outside this service
  // sees a raw row.

  /// Opens [raw]'s envelope and resolves every field in [fields] with the
  /// read rule of [EncryptedMeta.pick]. [requiredField] falls back to the
  /// placeholder, so a row that cannot be read still builds a model.
  ///
  /// The envelope must be bound to this row (`raw['id']` in [table]). One
  /// that belongs to another row, or to another table, reads exactly like
  /// one sealed with another key: undecryptable, never re-sealed.
  @visibleForTesting
  static Future<SealedRowRead> resolveSealedRow(
    Map<String, dynamic> raw,
    List<String> fields, {
    required String requiredField,
    required String table,
  }) async {
    final envelope = raw['encrypted_meta'];
    final rowId = raw['id'];
    final legacy = !_hasEnvelope(envelope);
    Map<String, dynamic>? meta;
    var undecryptable = false;
    if (!legacy) {
      try {
        if (rowId is! String) {
          throw const FormatException('row id missing; cannot check binding');
        }
        meta = await EncryptedMeta.decode(
          envelope as String,
          table: table,
          rowId: rowId,
        );
      } catch (_) {
        undecryptable = true;
      }
    }
    return (
      row: patchSealedRow(raw, meta, fields, requiredField: requiredField),
      undecryptable: undecryptable,
      legacy: legacy,
      needsReseal:
          !undecryptable &&
          rowNeedsReseal(raw, fields, requiredField: requiredField),
    );
  }

  /// Returns a copy of [raw] with every field in [fields] resolved from the
  /// plaintext column and the decoded [meta], without the envelope itself.
  @visibleForTesting
  static Map<String, dynamic> patchSealedRow(
    Map<String, dynamic> raw,
    Map<String, dynamic>? meta,
    List<String> fields, {
    required String requiredField,
  }) {
    final patched = Map<String, dynamic>.from(raw)..remove('encrypted_meta');
    for (final field in fields) {
      patched[field] = EncryptedMeta.pick(raw[field], meta, field);
    }
    patched[requiredField] ??= kEncryptedPlaceholder;
    return patched;
  }

  /// Returns a copy of [row] with [values] written over the sealed fields,
  /// without the envelope. Used after a write, where the values are known.
  @visibleForTesting
  static Map<String, dynamic> withResolvedFields(
    Map<String, dynamic> row,
    Map<String, String?> values,
  ) => Map<String, dynamic>.from(row)
    ..remove('encrypted_meta')
    ..addAll(values);

  /// True when [raw] is not in its clean sealed state and must be written
  /// again: it has no envelope yet, or a sealed column holds anything but
  /// the placeholder ([requiredField]) or NULL (the others). That covers an
  /// old build writing real plaintext, and also an old build writing '' back
  /// (read as the sealed value, cleaned up by the re-seal). Same rule as the
  /// startup sweep query ([projectSweepFilter], [fileSweepFilter]).
  @visibleForTesting
  static bool rowNeedsReseal(
    Map<String, dynamic> raw,
    List<String> fields, {
    required String requiredField,
  }) {
    if (!_hasEnvelope(raw['encrypted_meta'])) return true;
    for (final field in fields) {
      final value = raw[field];
      if (field == requiredField) {
        if (value != kEncryptedPlaceholder) return true;
      } else if (value != null) {
        return true;
      }
    }
    return false;
  }

  /// PostgREST `or` filter for the `projects` rows [rowNeedsReseal] flags.
  @visibleForTesting
  static String get projectSweepFilter =>
      'encrypted_meta.is.null,'
      'name.neq."$kEncryptedPlaceholder",'
      'description.not.is.null,'
      'custom_system_prompt.not.is.null';

  /// PostgREST `or` filter for the `project_files` rows [rowNeedsReseal]
  /// flags.
  @visibleForTesting
  static String get fileSweepFilter =>
      'encrypted_meta.is.null,'
      'file_name.neq."$kEncryptedPlaceholder",'
      'markdown_summary.not.is.null';

  /// The sealed-column part of a `projects` insert or update of row
  /// [rowId]. The envelope is bound to that row.
  @visibleForTesting
  static Future<Map<String, dynamic>> sealedProjectColumns({
    required String rowId,
    required String name,
    String? description,
    String? customSystemPrompt,
  }) async => <String, dynamic>{
    'name': kEncryptedPlaceholder,
    'description': null,
    'custom_system_prompt': null,
    'encrypted_meta': await EncryptedMeta.encode(
      {
        'name': name,
        'description': description,
        'custom_system_prompt': customSystemPrompt,
      },
      table: _projectsTable,
      rowId: rowId,
    ),
  };

  /// The sealed-column part of a `project_files` insert or update of row
  /// [rowId]. The envelope is bound to that row.
  @visibleForTesting
  static Future<Map<String, dynamic>> sealedFileColumns({
    required String rowId,
    required String fileName,
    String? markdownSummary,
  }) async => <String, dynamic>{
    'file_name': kEncryptedPlaceholder,
    'markdown_summary': null,
    'encrypted_meta': await EncryptedMeta.encode(
      {'file_name': fileName, 'markdown_summary': markdownSummary},
      table: _filesTable,
      rowId: rowId,
    ),
  };

  /// Merges the optional fields of an update over the current values, so
  /// the envelope always holds all three. Values are trimmed; an empty
  /// description or prompt clears it (null). Throws when the new name is
  /// empty, or when no new name is given and the current one is only the
  /// placeholder (sealing it would destroy the real, sealed name).
  @visibleForTesting
  static ({String name, String? description, String? customSystemPrompt})
  mergeProjectFields({
    required String currentName,
    String? currentDescription,
    String? currentCustomSystemPrompt,
    String? name,
    String? description,
    String? customSystemPrompt,
  }) {
    final String mergedName;
    if (name != null) {
      mergedName = name.trim();
      if (mergedName.isEmpty) {
        throw ArgumentError('Workspace name cannot be empty');
      }
    } else {
      if (!EncryptedMeta.isRealPlaintext(currentName)) {
        throw StateError(_undecryptableWorkspaceMessage);
      }
      mergedName = currentName;
    }
    return (
      name: mergedName,
      description: _blankToNull(description ?? currentDescription),
      customSystemPrompt: _blankToNull(
        customSystemPrompt ?? currentCustomSystemPrompt,
      ),
    );
  }

  /// True when [error] says the `encrypted_meta` column is not there yet
  /// (migration not applied, or PostgREST schema cache not reloaded).
  @visibleForTesting
  static bool isMissingEncryptedMetaColumn(PostgrestException error) =>
      EncryptedMeta.isMissingColumnError(error);

  static bool _hasEnvelope(Object? value) =>
      value is String && value.trim().isNotEmpty;

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Sealed rows need the key. Without it every sealed row would read as
  /// undecryptable and overwrite the good local cache with placeholders, so
  /// the load fails instead and the cached projects stay.
  ///
  /// [mayLoadKey] is false for the startup load: it runs before the key is
  /// loaded on purpose (Linux secure storage can stall the GTK main thread),
  /// so it waits instead and [reloadIfWaitingForKey] loads again once the
  /// app has the key. User actions may load the key themselves.
  static Future<void> _ensureKeyForSealedRows(
    Iterable<dynamic> rows, {
    bool mayLoadKey = true,
  }) async {
    final anySealed = rows.any(
      (row) => row is Map && _hasEnvelope(row['encrypted_meta']),
    );
    if (!anySealed || EncryptionService.hasKey) return;
    if (!mayLoadKey) {
      _waitingForKey = true;
    } else if (await EncryptionService.tryLoadKey()) {
      return;
    }
    throw StateError('Encryption key is missing. Please sign in again.');
  }

  /// A load found sealed rows before the key was there.
  static bool _waitingForKey = false;

  /// Loads the projects again if a load had to wait for the key. The app
  /// calls this once the key is ready. Never throws.
  static Future<void> reloadIfWaitingForKey() async {
    if (!_waitingForKey || !EncryptionService.hasKey) return;
    _waitingForKey = false;
    try {
      await loadProjects();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] Reload after key failed: $e');
      }
    }
  }

  static const String _undecryptableWorkspaceMessage =
      'This workspace cannot be decrypted on this device, so it cannot be '
      'edited.';
  static const String _undecryptableFileMessage =
      'This file cannot be decrypted on this device, so it cannot be edited.';

  /// Merges an update over the project row as it is on the server now
  /// ([fetched]: `id, name, description, custom_system_prompt,
  /// encrypted_meta`),
  /// read with the pick rule. The envelope holds all three fields, so
  /// merging over the local model would write back a field another device
  /// changed since the last load. Throws a [StateError] when the row cannot
  /// be opened: sealing over it would destroy its sealed values.
  @visibleForTesting
  static Future<({String name, String? description, String? customSystemPrompt})>
  mergeProjectUpdate(
    Map<String, dynamic> fetched, {
    String? name,
    String? description,
    String? customSystemPrompt,
  }) async {
    final read = await resolveSealedRow(
      fetched,
      projectSealedFields,
      requiredField: 'name',
      table: _projectsTable,
    );
    if (read.undecryptable) throw StateError(_undecryptableWorkspaceMessage);
    return mergeProjectFields(
      currentName: read.row['name'] as String,
      currentDescription: read.row['description'] as String?,
      currentCustomSystemPrompt: read.row['custom_system_prompt'] as String?,
      name: name,
      description: description,
      customSystemPrompt: customSystemPrompt,
    );
  }

  /// The file name to seal next to a new summary, read from the file row as
  /// it is on the server now ([fetched]: `id, file_name, encrypted_meta`).
  /// Throws a [StateError] when the row cannot be opened or holds no real
  /// name: sealing the placeholder would destroy the sealed name.
  @visibleForTesting
  static Future<String> currentFileNameForUpdate(
    Map<String, dynamic> fetched,
  ) async {
    final read = await resolveSealedRow(
      fetched,
      fileSealedFields,
      requiredField: 'file_name',
      table: _filesTable,
    );
    final fileName = read.row['file_name'] as String;
    if (read.undecryptable || !EncryptedMeta.isRealPlaintext(fileName)) {
      throw StateError(_undecryptableFileMessage);
    }
    return fileName;
  }

  /// The sealed fields of one project row, straight from the server.
  static Future<Map<String, dynamic>> _fetchProjectFields(
    String workspaceId,
    String userId,
  ) async {
    final raw = await SupabaseService.client
        .from('projects')
        .select('id, name, description, custom_system_prompt, encrypted_meta')
        .eq('id', workspaceId)
        .eq('user_id', userId)
        .maybeSingle();
    if (raw == null) throw StateError('Workspace not found');
    await _ensureKeyForSealedRows([raw]);
    return raw;
  }

  /// The sealed name of one file row, straight from the server.
  static Future<Map<String, dynamic>> _fetchFileNameFields(
    String fileId,
  ) async {
    final raw = await SupabaseService.client
        .from('project_files')
        .select('id, file_name, encrypted_meta')
        .eq('id', fileId)
        .maybeSingle();
    if (raw == null) throw StateError('File not found');
    await _ensureKeyForSealedRows([raw]);
    return raw;
  }

  /// The re-seal job for one read row, or null when the row needs no
  /// re-seal, cannot be opened, has no `updated_at` to guard the write, or
  /// has no real name (the placeholder is never sealed as the name).
  @visibleForTesting
  static ResealJob? resealJobFromRead(
    SealedRowRead read, {
    required bool isFile,
  }) {
    if (read.undecryptable || !read.needsReseal) return null;
    final row = read.row;
    final updatedAt = row['updated_at'];
    if (updatedAt is! String || updatedAt.isEmpty) return null;
    final name = row[isFile ? 'file_name' : 'name'];
    if (name is! String || !EncryptedMeta.isRealPlaintext(name)) return null;
    final workspaceId = isFile ? row['project_id'] : null;
    if (isFile && workspaceId is! String) return null;
    return ResealJob(
      id: row['id'] as String,
      workspaceId: workspaceId as String?,
      legacy: read.legacy,
      updatedAt: updatedAt,
      values: isFile
          ? {
              'file_name': name,
              'markdown_summary': row['markdown_summary'] as String?,
            }
          : {
              'name': name.trim(),
              'description': _blankToNull(row['description'] as String?),
              'custom_system_prompt': _blankToNull(
                row['custom_system_prompt'] as String?,
              ),
            },
    );
  }

  /// Adds the guards of a re-seal write to [query]: the row id, the owner
  /// (projects), the `updated_at` stamp of the snapshot, and for a legacy
  /// row "still no envelope". Only ids and the stamp go into the URL, never
  /// a value or an envelope.
  @visibleForTesting
  static PostgrestFilterBuilder<T> applyResealGuards<T>(
    PostgrestFilterBuilder<T> query,
    ResealJob job, {
    String? userId,
  }) {
    var guarded = query.eq('id', job.id).eq('updated_at', job.updatedAt);
    if (userId != null) guarded = guarded.eq('user_id', userId);
    if (job.legacy) guarded = guarded.isFilter('encrypted_meta', null);
    return guarded;
  }

  /// Writes [job] sealed. Returns false when nothing was written: the row
  /// cannot be opened on this device, or it changed since the snapshot (the
  /// guarded update matched no row; the next load or sweep handles it).
  /// [from] replaces the Supabase client in tests.
  @visibleForTesting
  static Future<bool> writeResealJob(
    ResealJob job,
    String userId, {
    PostgrestQueryBuilder Function(String table)? from,
  }) async {
    final undecryptable = job.isFile
        ? _undecryptableFileIds
        : _undecryptableProjectIds;
    if (undecryptable.contains(job.id)) return false;
    final values = job.values;
    final payload = job.isFile
        ? await sealedFileColumns(
            rowId: job.id,
            fileName: values['file_name']!,
            markdownSummary: values['markdown_summary'],
          )
        : await sealedProjectColumns(
            rowId: job.id,
            name: values['name']!,
            description: values['description'],
            customSystemPrompt: values['custom_system_prompt'],
          );
    final table = (from ?? SupabaseService.client.from)(job.table);
    final written = await applyResealGuards(
      table.update(payload),
      job,
      userId: job.isFile ? null : userId,
    ).select('id');
    return written.isNotEmpty;
  }

  /// Claims the jobs to run now and marks them as tried this session.
  /// Claims nothing without a key: sealing would fail, and the startup
  /// sweep, which runs after the key is loaded, takes those rows instead.
  @visibleForTesting
  static List<ResealJob> claimResealJobs(
    Iterable<ResealJob> jobs,
    Set<String> attempted, {
    required bool hasKey,
  }) {
    if (!hasKey) return const [];
    return jobs.where((job) => attempted.add(job.key)).toList();
  }

  /// After a failed re-seal write: a server verdict (a PostgrestException)
  /// keeps the row marked as tried; any other failure (no key, encryption
  /// error, network) releases it, so the sweep can try the row again.
  @visibleForTesting
  static void releaseResealClaim(
    Set<String> attempted,
    ResealJob job,
    Object error,
  ) {
    if (error is! PostgrestException) attempted.remove(job.key);
  }

  /// Queues [jobs] for the background re-seal, skipping rows already tried
  /// this session. Does nothing before the key is loaded (Linux loads the
  /// projects first); the startup sweep seals those rows.
  static void _queueReseal(List<ResealJob> jobs, String userId) {
    if (_resealDisabled || jobs.isEmpty) return;
    final fresh = claimResealJobs(
      jobs,
      _resealAttempted,
      hasKey: EncryptionService.hasKey,
    );
    if (fresh.isEmpty) return;
    if (kDebugMode) {
      debugPrint('🔒 [ProjectStorage] Re-sealing ${fresh.length} rows');
    }
    _resealChain = _resealChain
        .then((_) => _runReseal(fresh, userId))
        .catchError((_) {});
    unawaited(_resealChain);
  }

  static Future<void> _runReseal(List<ResealJob> jobs, String userId) async {
    var sealed = 0;
    var skipped = 0;
    var failed = 0;
    for (final job in jobs) {
      if (_resealDisabled) return;
      // Signed out or switched account: the rows are not ours to write.
      if (SupabaseService.auth.currentUser?.id != userId) return;
      try {
        if (await writeResealJob(job, userId)) {
          sealed++;
        } else {
          skipped++;
        }
      } on PostgrestException catch (e) {
        if (isMissingEncryptedMetaColumn(e)) {
          _disableResealForMissingColumn(e, job.table);
          return;
        }
        failed++;
        // Only the code: a Postgres error detail can echo the row.
        if (kDebugMode) {
          debugPrint(
            '⚠️ [ProjectStorage] Re-seal failed for ${job.key}: ${e.code}',
          );
        }
      } catch (e) {
        failed++;
        releaseResealClaim(_resealAttempted, job, e);
        if (kDebugMode) {
          debugPrint(
            '⚠️ [ProjectStorage] Re-seal failed for ${job.key}: '
            '${e.runtimeType}',
          );
        }
      }
    }
    if (kDebugMode) {
      debugPrint(
        '🔒 [ProjectStorage] Re-seal done: $sealed sealed, $skipped skipped, '
        '$failed failed',
      );
    }
  }

  static void _disableResealForMissingColumn(
    PostgrestException error,
    String table,
  ) {
    _resealDisabled = true;
    unawaited(
      DiagnosticsLogService.warning(
        'workspace',
        'encrypted_meta column missing; re-seal disabled for this session',
        data: {'code': error.code, 'table': table},
      ),
    );
    if (kDebugMode) {
      debugPrint(
        '⚠️ [ProjectStorage] encrypted_meta column missing ($table); '
        're-seal disabled for this session',
      );
    }
  }

  static Future<int>? _sweepInFlight;

  /// Startup sweep: seals every legacy or old-build row of the signed-in
  /// user, whether or not the projects UI is ever opened. Fetches only the
  /// rows that need work ([projectSweepFilter], [fileSweepFilter]), so a
  /// run with nothing left costs three small queries. Same rules as the
  /// lazy re-seal: each row at most once per session, undecryptable rows are
  /// never written, values come from the read rule. Loaded projects and the
  /// local cache take the resolved values. Returns how many rows it sealed.
  /// Never throws; a missing `encrypted_meta` column stops re-sealing for
  /// the session.
  static Future<int> resealLegacyRows() {
    return _sweepInFlight ??= _sweepLegacyRows().whenComplete(() {
      _sweepInFlight = null;
    });
  }

  static Future<int> _sweepLegacyRows() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null || _resealDisabled) return 0;
    final userId = user.id;
    var sealed = 0;
    var skipped = 0;
    var failed = 0;
    var modelChanged = false;
    var table = 'projects';

    Future<bool> sweep(List<Map<String, dynamic>> rows, bool isFile) async {
      for (final raw in rows) {
        if (_resealDisabled || SupabaseService.auth.currentUser?.id != userId) {
          return false;
        }
        final read = await resolveSealedRow(
          raw,
          isFile ? fileSealedFields : projectSealedFields,
          requiredField: isFile ? 'file_name' : 'name',
          table: isFile ? _filesTable : _projectsTable,
        );
        if (read.undecryptable) {
          final id = read.row['id'] as String;
          (isFile ? _undecryptableFileIds : _undecryptableProjectIds).add(id);
          continue;
        }
        final job = resealJobFromRead(read, isFile: isFile);
        if (job == null || !_resealAttempted.add(job.key)) continue;
        try {
          if (!await writeResealJob(job, userId)) {
            skipped++;
            continue;
          }
          sealed++;
          modelChanged |= isFile
              ? _applySweptFile(read.row)
              : _applySweptProject(job.id, read.row);
        } on PostgrestException catch (e) {
          if (isMissingEncryptedMetaColumn(e)) rethrow;
          failed++;
          if (kDebugMode) {
            debugPrint(
              '⚠️ [ProjectStorage] Sweep failed for ${job.key}: ${e.code}',
            );
          }
        } catch (e) {
          // No server verdict (key gone, encryption failed, network): let a
          // later sweep try this row again, and stop this one.
          releaseResealClaim(_resealAttempted, job, e);
          rethrow;
        }
      }
      return true;
    }

    try {
      if (!EncryptionService.hasKey && !await EncryptionService.tryLoadKey()) {
        return 0;
      }

      final projectRows = await SupabaseService.client
          .from('projects')
          .select(
            'id, name, description, custom_system_prompt, encrypted_meta, '
            'updated_at',
          )
          .eq('user_id', userId)
          .or(projectSweepFilter);
      if (!await sweep(projectRows, false)) return sealed;

      table = 'project_files';
      final idRows = await SupabaseService.client
          .from('projects')
          .select('id')
          .eq('user_id', userId);
      final projectIds = idRows.map((row) => row['id'] as String).toList();
      if (projectIds.isNotEmpty) {
        final fileRows = await SupabaseService.client
            .from('project_files')
            .select(
              'id, project_id, file_name, markdown_summary, encrypted_meta, '
              'updated_at',
            )
            .inFilter('project_id', projectIds)
            .or(fileSweepFilter);
        await sweep(fileRows, true);
      }
    } on PostgrestException catch (e) {
      if (isMissingEncryptedMetaColumn(e)) {
        _disableResealForMissingColumn(e, table);
      } else if (kDebugMode) {
        // Only the code: a Postgres error detail can echo the row.
        debugPrint('⚠️ [ProjectStorage] Sweep stopped: ${e.code}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] Sweep stopped: ${e.runtimeType}');
      }
    } finally {
      if (modelChanged) _notifyChanges();
      if (kDebugMode && (sealed > 0 || skipped > 0 || failed > 0)) {
        debugPrint(
          '🔒 [ProjectStorage] Sweep done: $sealed sealed, $skipped skipped, '
          '$failed failed',
        );
      }
    }
    return sealed;
  }

  /// Puts the resolved values of a swept project row into the loaded model.
  /// Returns true when the model changed.
  static bool _applySweptProject(String id, Map<String, dynamic> row) {
    final workspace = _projectsById[id];
    if (workspace == null) return false;
    final name = row['name'] as String;
    final description = row['description'] as String?;
    final prompt = row['custom_system_prompt'] as String?;
    if (workspace.name == name &&
        workspace.description == description &&
        workspace.customSystemPrompt == prompt) {
      return false;
    }
    _projectsById[id] = Workspace.fromJson({
      ...workspace.toJson(),
      'name': name,
      'description': description,
      'custom_system_prompt': prompt,
    });
    return true;
  }

  /// Puts the resolved values of a swept file row into the loaded model.
  /// Returns true when the model changed.
  static bool _applySweptFile(Map<String, dynamic> row) {
    final workspaceId = row['project_id'] as String?;
    final id = row['id'] as String;
    final workspace = workspaceId == null ? null : _projectsById[workspaceId];
    if (workspace == null) return false;
    final fileName = row['file_name'] as String;
    final markdown = row['markdown_summary'] as String?;
    var changed = false;
    final files = workspace.files.map((f) {
      if (f.id != id ||
          (f.fileName == fileName && f.markdownSummary == markdown)) {
        return f;
      }
      changed = true;
      return _fileWith(f, fileName: fileName, markdownSummary: markdown);
    }).toList();
    if (!changed) return false;
    _projectsById[workspaceId!] = workspace.copyWith(files: files);
    return true;
  }

  /// [WorkspaceFile.copyWith] cannot clear the summary; this can.
  static WorkspaceFile _fileWith(
    WorkspaceFile f, {
    required String fileName,
    required String? markdownSummary,
  }) => WorkspaceFile(
    id: f.id,
    workspaceId: f.workspaceId,
    fileName: fileName,
    storagePath: f.storagePath,
    fileType: f.fileType,
    fileSize: f.fileSize,
    uploadedAt: f.uploadedAt,
    markdownSummary: markdownSummary,
  );

  // ============ PROJECT CRUD OPERATIONS ============

  /// Load all projects from Supabase (updates cache)
  /// Uses cache-first pattern: loads from cache immediately, then syncs from network.
  static Future<void> loadProjects() async {
    // First load from cache for instant UI (if not already loaded)
    if (!_cacheLoaded) {
      await loadFromCache();
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      if (kDebugMode) {
        debugPrint('⚠️ [ProjectStorage] No user signed in, clearing projects');
      }
      _projectsById.clear();
      _notifyChanges(updateCache: false);
      return;
    }

    // Prevent concurrent loads - wait for existing load to finish
    if (_isLoading) {
      if (kDebugMode) {
        debugPrint('⏳ [ProjectStorage] Load already in progress, waiting...');
      }
      return _loadingCompleter!.future;
    }
    _loadingCompleter = Completer<void>();
    _isLoadingFromNetwork = true;

    try {
      // Load projects from server
      final projectRows = await SupabaseService.client
          .from('projects')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Loaded ${projectRows.length} projects from server',
        );
      }

      // Skip network fetch work if no projects
      if (projectRows.isEmpty) {
        _undecryptableProjectIds.clear();
        _undecryptableFileIds.clear();
        if (_projectsById.isNotEmpty) {
          _projectsById.clear();
          await _saveToCache();
          _notifyChanges(updateCache: false);
        }
        return;
      }

      // Load workspace-chat relationships AND workspace files in PARALLEL
      final workspaceIds = projectRows.map((p) => p['id'] as String).toList();
      final chatsFuture = SupabaseService.client
          .from('project_chats')
          .select('project_id, chat_id')
          .inFilter('project_id', workspaceIds);
      final filesFuture = SupabaseService.client
          .from('project_files')
          .select('*')
          .inFilter('project_id', workspaceIds);

      final results = await Future.wait<dynamic>([chatsFuture, filesFuture]);
      final projectChatRows = results[0] as List<dynamic>;
      final fileRows = results[1] as List<dynamic>;

      await _ensureKeyForSealedRows([
        ...projectRows,
        ...fileRows,
      ], mayLoadKey: false);

      // Group chat IDs by workspace ID
      final Map<String, List<String>> chatIdsByProject = {};
      for (final row in projectChatRows) {
        final workspaceId = row['project_id'] as String;
        final chatId = row['chat_id'] as String;
        chatIdsByProject.putIfAbsent(workspaceId, () => []).add(chatId);
      }

      final resealJobs = <ResealJob>[];
      final undecryptableProjects = <String>{};
      final undecryptableFiles = <String>{};

      // Group files by workspace ID (sealed fields decrypted)
      final Map<String, List<WorkspaceFile>> filesByProject = {};
      for (final raw in fileRows) {
        final read = await resolveSealedRow(
          Map<String, dynamic>.from(raw as Map),
          fileSealedFields,
          requiredField: 'file_name',
          table: _filesTable,
        );
        final file = WorkspaceFile.fromJson(read.row);
        if (read.undecryptable) undecryptableFiles.add(file.id);
        final job = resealJobFromRead(read, isFile: true);
        if (job != null) resealJobs.add(job);
        filesByProject.putIfAbsent(file.workspaceId, () => []).add(file);
      }

      // Build Workspace objects (sealed fields decrypted)
      final loaded = <String, Workspace>{};
      for (final raw in projectRows) {
        final read = await resolveSealedRow(
          raw,
          projectSealedFields,
          requiredField: 'name',
          table: _projectsTable,
        );
        final workspaceId = read.row['id'] as String;
        if (read.undecryptable) undecryptableProjects.add(workspaceId);
        final job = resealJobFromRead(read, isFile: false);
        if (job != null) resealJobs.add(job);
        loaded[workspaceId] = Workspace.fromJson({
          ...read.row,
          'chatIds': chatIdsByProject[workspaceId] ?? [],
          'files':
              filesByProject[workspaceId]?.map((f) => f.toJson()).toList() ?? [],
        });
      }
      _projectsById
        ..clear()
        ..addAll(loaded);
      _undecryptableProjectIds
        ..clear()
        ..addAll(undecryptableProjects);
      _undecryptableFileIds
        ..clear()
        ..addAll(undecryptableFiles);
      if (kDebugMode &&
          (undecryptableProjects.isNotEmpty || undecryptableFiles.isNotEmpty)) {
        debugPrint(
          '⚠️ [ProjectStorage] Cannot decrypt ${undecryptableProjects.length} '
          'projects and ${undecryptableFiles.length} files',
        );
      }

      // Save to cache for next time (only once, not via _notifyChanges)
      await _saveToCache();
      // Notify without auto-save since we just saved
      _notifyChanges(updateCache: false);

      // Legacy and old-build rows: seal them in the background, each from
      // the snapshot just read (values and updated_at of the same row).
      _queueReseal(resealJobs, user.id);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to load projects: $e\n$st');
      }
      // Don't rethrow if we have cached data
      if (_projectsById.isEmpty) rethrow;
    } finally {
      _isLoadingFromNetwork = false;
      _loadingCompleter?.complete();
      _loadingCompleter = null;
    }
  }

  /// Create a new workspace
  static Future<Workspace> createProject(
    String name, {
    String? description,
    String? customSystemPrompt,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to create projects.');
    }

    try {
      // The name column had a non-empty CHECK; the placeholder now always
      // passes it, so the rule is enforced here.
      final trimmedName = name.trim();
      if (trimmedName.isEmpty) {
        throw ArgumentError('Workspace name cannot be empty');
      }
      final values = <String, String?>{
        'name': trimmedName,
        'description': _blankToNull(description),
        'custom_system_prompt': _blankToNull(customSystemPrompt),
      };

      // The envelope is bound to its row, so the id is chosen here, before
      // sealing (the column's gen_random_uuid() default accepts it).
      final rowId = _uuid.v4();
      final Map<String, dynamic> insertData = {
        'id': rowId,
        'user_id': user.id,
        ...await sealedProjectColumns(
          rowId: rowId,
          name: trimmedName,
          description: values['description'],
          customSystemPrompt: values['custom_system_prompt'],
        ),
      };

      final inserted = await SupabaseService.client
          .from('projects')
          .insert(insertData)
          .select()
          .single();

      final workspace = Workspace.fromJson(
        withResolvedFields(inserted, values),
      );
      _projectsById[workspace.id] = workspace;
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Created workspace: ${workspace.id}');
      }
      return workspace;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to create workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Update an existing workspace
  static Future<Workspace> updateProject(
    String workspaceId, {
    String? name,
    String? description,
    String? customSystemPrompt,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update projects.');
    }

    try {
      if (name == null && description == null && customSystemPrompt == null) {
        throw ArgumentError('At least one field must be updated');
      }
      // One envelope holds all three fields: merge the change over the row
      // as it is on the server now, not over the local model, so a field
      // another device changed since the last load is kept.
      final merged = await mergeProjectUpdate(
        await _fetchProjectFields(workspaceId, user.id),
        name: name,
        description: description,
        customSystemPrompt: customSystemPrompt,
      );

      final updated = await SupabaseService.client
          .from('projects')
          .update(
            await sealedProjectColumns(
              rowId: workspaceId,
              name: merged.name,
              description: merged.description,
              customSystemPrompt: merged.customSystemPrompt,
            ),
          )
          .eq('id', workspaceId)
          .eq('user_id', user.id)
          .select()
          .single();

      final existingProject = _projectsById[workspaceId];
      final workspace = Workspace.fromJson({
        ...withResolvedFields(updated, {
          'name': merged.name,
          'description': merged.description,
          'custom_system_prompt': merged.customSystemPrompt,
        }),
        'chatIds': existingProject?.chatIds ?? [],
        'files': existingProject?.files.map((f) => f.toJson()).toList() ?? [],
      });

      _projectsById[workspaceId] = workspace;
      _undecryptableProjectIds.remove(workspaceId);
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Updated workspace: $workspaceId');
      }
      return workspace;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to update workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Delete a workspace (cascades to project_chats and project_files via DB)
  static Future<void> deleteProject(String workspaceId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete projects.');
    }

    try {
      await SupabaseService.client
          .from('projects')
          .delete()
          .eq('id', workspaceId)
          .eq('user_id', user.id);

      _projectsById.remove(workspaceId);
      if (selectedWorkspaceId == workspaceId) {
        selectedWorkspaceId = null;
      }
      _notifyChanges();

      if (kDebugMode) {
        debugPrint('🗑️ [ProjectStorage] Deleted workspace: $workspaceId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to delete workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Archive or unarchive a workspace
  static Future<void> archiveProject(String workspaceId, bool archived) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to archive projects.');
    }

    try {
      await SupabaseService.client
          .from('projects')
          .update({'is_archived': archived})
          .eq('id', workspaceId)
          .eq('user_id', user.id);

      final existingProject = _projectsById[workspaceId];
      if (existingProject != null) {
        _projectsById[workspaceId] = existingProject.copyWith(
          isArchived: archived,
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '📦 [ProjectStorage] ${archived ? 'Archived' : 'Unarchived'} workspace: $workspaceId',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to archive workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Get a specific workspace by ID
  static Workspace? getWorkspace(String workspaceId) {
    return _projectsById[workspaceId];
  }

  /// Get the workspace associated with a specific chat (if any)
  static Workspace? getWorkspaceForChat(String chatId) {
    for (final ws in _projectsById.values) {
      if (ws.chatIds.contains(chatId)) return ws;
    }
    return null;
  }

  /// Link a chat to a workspace (alias for addChatToProject)
  static Future<void> linkChatToWorkspace(
    String workspaceId,
    String chatId,
  ) => addChatToProject(workspaceId, chatId);

  // ============ CHAT MANAGEMENT ============

  /// Add a chat to a workspace
  static Future<void> addChatToProject(String workspaceId, String chatId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to manage workspace chats.');
    }

    try {
      await SupabaseService.client.from('project_chats').insert({
        'project_id': workspaceId,
        'chat_id': chatId,
      });

      final workspace = _projectsById[workspaceId];
      if (workspace != null && !workspace.chatIds.contains(chatId)) {
        _projectsById[workspaceId] = workspace.copyWith(
          chatIds: [...workspace.chatIds, chatId],
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Added chat $chatId to workspace $workspaceId',
        );
      }
    } catch (e, st) {
      // Ignore unique constraint violations (chat already in workspace)
      if (e.toString().contains('unique_project_chat')) {
        if (kDebugMode) {
          debugPrint('⚠️ [ProjectStorage] Chat already in workspace');
        }
        return;
      }
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to add chat to workspace: $e\n$st');
      }
      rethrow;
    }
  }

  /// Remove a chat from a workspace
  static Future<void> removeChatFromProject(
    String workspaceId,
    String chatId,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to manage workspace chats.');
    }

    try {
      await SupabaseService.client
          .from('project_chats')
          .delete()
          .eq('project_id', workspaceId)
          .eq('chat_id', chatId);

      final workspace = _projectsById[workspaceId];
      if (workspace != null) {
        _projectsById[workspaceId] = workspace.copyWith(
          chatIds: workspace.chatIds.where((id) => id != chatId).toList(),
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Removed chat $chatId from workspace $workspaceId',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '❌ [ProjectStorage] Failed to remove chat from workspace: $e\n$st',
        );
      }
      rethrow;
    }
  }

  /// Get all chats in a workspace
  static Future<List<StoredChat>> getProjectChats(String workspaceId) async {
    final workspace = _projectsById[workspaceId];
    if (workspace == null) return [];

    // Get chats from ChatStorageService
    final allChats = ChatStorageService.savedChats;
    return allChats.where((chat) => workspace.chatIds.contains(chat.id)).toList();
  }


  // ============ AVATAR IMAGE MANAGEMENT ============

  /// Upload an avatar image for a workspace.
  static Future<void> uploadAvatar(
    String workspaceId,
    Uint8List imageBytes,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) throw StateError('User must be signed in.');

    // Delete existing avatar if present
    final existing = _projectsById[workspaceId];
    if (existing?.avatarImagePath != null) {
      try {
        await ImageStorageService.deleteEncryptedImage(
          existing!.avatarImagePath!,
        );
      } catch (_) {}
    }

    final storagePath =
        await ImageStorageService.uploadEncryptedImage(imageBytes);

    try {
      await SupabaseService.client
          .from('projects')
          .update({'avatar_image_path': storagePath})
          .eq('id', workspaceId)
          .eq('user_id', user.id);

      if (_projectsById.containsKey(workspaceId)) {
        _projectsById[workspaceId] = _projectsById[workspaceId]!.copyWith(
          avatarImagePath: storagePath,
        );
        _notifyChanges();
      }
    } catch (e) {
      // Clean up uploaded image on DB failure
      try {
        await ImageStorageService.deleteEncryptedImage(storagePath);
      } catch (_) {}
      rethrow;
    }
  }


  // ============ FILE MANAGEMENT ============

  /// Upload a file to a workspace (encrypted in Supabase Storage)
  /// If [filePath] is provided and [generateMarkdown] is true, will also generate
  /// an AI markdown summary of the file content.
  ///
  /// [onUploadProgress] is called with progress (0.0-1.0) during upload
  /// [onConversionStart] is called when markdown conversion begins
  static Future<WorkspaceFile> uploadFile(
    String workspaceId,
    String fileName,
    Uint8List fileBytes,
    String fileType, {
    String? filePath,
    bool generateMarkdown = true,
    void Function(double progress)? onUploadProgress,
    void Function()? onConversionStart,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to upload files.');
    }

    final session = SupabaseService.auth.currentSession;
    if (session == null) {
      throw StateError('No active session. Please sign in again.');
    }

    // The file_name column had a non-empty CHECK; the placeholder now always
    // passes it, so the rule is enforced here, before the upload.
    if (fileName.trim().isEmpty) {
      throw ArgumentError('File name cannot be empty');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Step 1: Encrypt file content (0-20%)
      onUploadProgress?.call(0.05);
      final fileContent = utf8.decode(fileBytes, allowMalformed: true);
      final encryptedJson = await EncryptionService.encrypt(fileContent);
      final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));
      onUploadProgress?.call(0.20);

      // Step 2: Upload to Supabase Storage (20-90%)
      final fileId = _uuid.v4();
      final storageFileName = '$fileId.enc';
      final storagePath = '${user.id}/$storageFileName';

      // Simulate upload progress in chunks
      onUploadProgress?.call(0.30);
      await SupabaseService.client.storage
          .from(bucketName)
          .uploadBinary(
            storagePath,
            encryptedBytes,
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: false,
            ),
          );
      onUploadProgress?.call(0.90);

      // Step 3: Generate markdown summary
      // Plain text files: read directly (no API call needed)
      // Binary files (PDF, Office docs): use convert-file API
      String? markdownSummary;
      if (generateMarkdown) {
        final extension = fileType.toLowerCase();

        if (FileConstants.isPlainText(extension)) {
          // Plain text file: use content directly
          final content = utf8.decode(fileBytes, allowMalformed: true);

          // Check token limit (40k tokens ≈ 160k chars)
          if (content.length > FileConversionService.maxCharsPerFile) {
            final estimatedTokens = (content.length / 4).round();
            throw StateError(
              'File is too large (~$estimatedTokens tokens). '
              'Maximum allowed is ${FileConversionService.maxTokensPerFile} tokens. '
              'Try a smaller file.',
            );
          }

          markdownSummary =
              '**File: $fileName**\n\n```$extension\n$content\n```';
          if (kDebugMode) {
            debugPrint(
              '📝 [ProjectStorage] Plain text file read directly '
              '(${content.length} chars)',
            );
          }
        } else if (filePath != null &&
            FileConstants.requiresConversion(extension)) {
          // Binary file: use convert-file API - notify UI
          onConversionStart?.call();
          try {
            if (kDebugMode) {
              debugPrint(
                '📝 [ProjectStorage] Generating markdown via API '
                '(.$extension)',
              );
            }
            final result = await FileConversionService.convertFile(
              filePath: filePath,
              accessToken: session.accessToken,
              userId: user.id,
            );
            if (result['success'] == true && result['markdown'] != null) {
              final pageImages = result['pageImages'] as List?;
              if (pageImages != null && pageImages.isNotEmpty) {
                // Scanned PDF: the API returns page images for a chat
                // message to attach. A workspace file holds text only, so
                // say what the file is instead of repeating a note that
                // promises images nobody attached here.
                markdownSummary =
                    '**$fileName** is a scanned document (${pageImages.length} '
                    'page images, no text layer). Attach it to a chat message '
                    'to have its pages read.';
              } else {
                markdownSummary = result['markdown'] as String;
              }
              if (kDebugMode) {
                debugPrint(
                  '✅ [ProjectStorage] Markdown generated successfully',
                );
              }
            } else {
              // Propagate the error to the UI instead of silently continuing
              final error = result['error'] as String?;
              if (error != null && error.contains('tokens')) {
                // Token limit error - throw to show to user
                throw StateError(error);
              }
              if (kDebugMode) {
                debugPrint(
                  '⚠️ [ProjectStorage] Markdown generation failed: $error',
                );
              }
            }
          } catch (e) {
            if (e is StateError) {
              rethrow; // Re-throw token limit errors
            }
            if (kDebugMode) {
              debugPrint('⚠️ [ProjectStorage] Markdown generation error: $e');
            }
            // Continue without markdown - don't fail the upload for other errors
          }
        }
      }
      onUploadProgress?.call(1.0);

      // Step 4: Save metadata to database. Name and text go sealed into
      // encrypted_meta; the plaintext columns keep the placeholder / NULL.
      // The envelope is bound to its row, so the row id is chosen here: a
      // fresh v4, independent of the storage path's uuid.
      final rowId = _uuid.v4();
      final insertData = <String, dynamic>{
        'id': rowId,
        'project_id': workspaceId,
        'storage_path': storagePath,
        'file_type': fileType,
        'file_size': fileBytes.length,
        ...await sealedFileColumns(
          rowId: rowId,
          fileName: fileName,
          markdownSummary: markdownSummary,
        ),
      };

      final inserted = await SupabaseService.client
          .from('project_files')
          .insert(insertData)
          .select()
          .single();

      final projectFile = WorkspaceFile.fromJson(
        withResolvedFields(inserted, {
          'file_name': fileName,
          'markdown_summary': markdownSummary,
        }),
      );

      // Update workspace in cache
      final workspace = _projectsById[workspaceId];
      if (workspace != null) {
        _projectsById[workspaceId] = workspace.copyWith(
          files: [...workspace.files, projectFile],
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint(
          '✅ [ProjectStorage] Uploaded file: ${projectFile.id} to $workspaceId',
        );
      }
      return projectFile;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to upload file: $e\n$st');
      }
      rethrow;
    }
  }

  /// Delete a file from a workspace (also deletes from storage)
  static Future<void> deleteFile(String workspaceId, String fileId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to delete files.');
    }

    try {
      // Find file to get storage path
      final workspace = _projectsById[workspaceId];
      final file = workspace?.files.firstWhere((f) => f.id == fileId);

      // Delete from database first
      await SupabaseService.client
          .from('project_files')
          .delete()
          .eq('id', fileId);

      // Delete from storage
      if (file != null) {
        try {
          await SupabaseService.client.storage.from(bucketName).remove([
            file.storagePath,
          ]);
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [ProjectStorage] Failed to delete file from storage: $e',
            );
          }
          // Continue even if storage deletion fails
        }
      }

      // Update cache
      if (workspace != null) {
        _projectsById[workspaceId] = workspace.copyWith(
          files: workspace.files.where((f) => f.id != fileId).toList(),
        );
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint('🗑️ [ProjectStorage] Deleted file: $fileId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to delete file: $e\n$st');
      }
      rethrow;
    }
  }


  /// Download and decrypt a file's content from Supabase Storage
  static Future<String> decryptFile(String fileId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to download files.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Find file in all projects to get storage path
      WorkspaceFile? file;
      for (final workspace in _projectsById.values) {
        try {
          file = workspace.files.firstWhere((f) => f.id == fileId);
          break;
        } catch (_) {
          // File not in this workspace, continue searching
        }
      }

      if (file == null) {
        throw StateError('File not found');
      }

      // Download encrypted file from storage
      final encryptedBytes = await SupabaseService.client.storage
          .from(bucketName)
          .download(file.storagePath);

      // Convert bytes to string (JSON format)
      final encryptedJson = utf8.decode(encryptedBytes);

      // Decrypt the file content
      final decryptedContent = await EncryptionService.decrypt(encryptedJson);

      return decryptedContent;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '❌ [ProjectStorage] Failed to download/decrypt file: $e\n$st',
        );
      }
      rethrow;
    }
  }

  /// Download and decrypt a file, returning raw bytes
  static Future<Uint8List> downloadFile(String workspaceId, String fileId) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to download files.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Find file in workspace
      final workspace = _projectsById[workspaceId];
      final file = workspace?.files.firstWhere((f) => f.id == fileId);

      if (file == null) {
        throw StateError('File not found');
      }

      // Download encrypted file from storage
      final encryptedBytes = await SupabaseService.client.storage
          .from(bucketName)
          .download(file.storagePath);

      // Convert bytes to string (JSON format)
      final encryptedJson = utf8.decode(encryptedBytes);

      // Decrypt the file content
      final decryptedContent = await EncryptionService.decrypt(encryptedJson);

      // Return as bytes
      return Uint8List.fromList(utf8.encode(decryptedContent));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to download file: $e\n$st');
      }
      rethrow;
    }
  }

  /// Update a file's encrypted content
  static Future<void> updateFileContent(
    String workspaceId,
    String fileId,
    Uint8List newBytes,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update files.');
    }

    if (!EncryptionService.hasKey) {
      final loaded = await EncryptionService.tryLoadKey();
      if (!loaded) {
        throw StateError('Encryption key is missing. Please sign in again.');
      }
    }

    try {
      // Find file in workspace
      final workspace = _projectsById[workspaceId];
      final file = workspace?.files.firstWhere((f) => f.id == fileId);

      if (file == null) {
        throw StateError('File not found');
      }

      // Encrypt new content
      final fileContent = utf8.decode(newBytes);
      final encryptedJson = await EncryptionService.encrypt(fileContent);
      final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));

      // Upload to storage (upsert to replace existing)
      await SupabaseService.client.storage
          .from(bucketName)
          .uploadBinary(
            file.storagePath,
            encryptedBytes,
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: true,
            ),
          );

      // Update file size in database
      await SupabaseService.client
          .from('project_files')
          .update({'file_size': newBytes.length})
          .eq('id', fileId);

      // Update cache
      if (workspace != null) {
        final updatedFiles = workspace.files.map((f) {
          if (f.id == fileId) {
            return WorkspaceFile(
              id: f.id,
              workspaceId: f.workspaceId,
              fileName: f.fileName,
              storagePath: f.storagePath,
              fileType: f.fileType,
              fileSize: newBytes.length,
              uploadedAt: f.uploadedAt,
              markdownSummary: f.markdownSummary,
            );
          }
          return f;
        }).toList();

        _projectsById[workspaceId] = workspace.copyWith(files: updatedFiles);
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Updated file content: $fileId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to update file: $e\n$st');
      }
      rethrow;
    }
  }

  /// Update a file's markdown summary
  static Future<void> updateFileMarkdown(
    String workspaceId,
    String fileId,
    String? markdown,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to update files.');
    }

    try {
      // The envelope holds the name too: read it from the row as it is on
      // the server now, not from the local model.
      final fileName = await currentFileNameForUpdate(
        await _fetchFileNameFields(fileId),
      );

      // Update in database
      await SupabaseService.client
          .from('project_files')
          .update(
            await sealedFileColumns(
              rowId: fileId,
              fileName: fileName,
              markdownSummary: markdown,
            ),
          )
          .eq('id', fileId);
      _undecryptableFileIds.remove(fileId);

      // Update cache
      final workspace = _projectsById[workspaceId];
      if (workspace != null) {
        final updatedFiles = workspace.files.map((f) {
          if (f.id == fileId) {
            return _fileWith(
              f,
              fileName: fileName,
              markdownSummary: markdown,
            );
          }
          return f;
        }).toList();

        _projectsById[workspaceId] = workspace.copyWith(files: updatedFiles);
        _notifyChanges();
      }

      if (kDebugMode) {
        debugPrint('✅ [ProjectStorage] Updated file markdown: $fileId');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectStorage] Failed to update markdown: $e\n$st');
      }
      rethrow;
    }
  }

  // ============ STATE MANAGEMENT ============

  /// Reset all state (on logout)
  static Future<void> reset() async {
    _projectsById.clear();
    _undecryptableProjectIds.clear();
    _undecryptableFileIds.clear();
    _resealAttempted.clear();
    selectedWorkspaceId = null;
    _cacheLoaded = false;
    _isLoadingFromNetwork = false;
    _loadingCompleter = null;
    _notifyDebounceTimer?.cancel();
    _hasPendingNotification = false;
    _notifyChangesImmediate();
  }


}
