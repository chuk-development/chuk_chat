/// Fetches the remote skill catalog and reconciles it into the user's store.
///
/// The catalog is a public GitHub repo — a manifest (`index.json`) the client
/// fetches first, then skill bodies lazily. See
/// https://github.com/chuk-development/chuk-skills and
/// `docs/SKILLS_REMOTE_PLAN.md`.
///
/// Reconciliation never clobbers a user's edits. Each stored catalog skill
/// remembers the catalog hash it was seeded from ([Skill.baselineHash]); on a
/// refresh a skill the user never touched is updated silently, an edited one
/// produces a suggestion, and a skill the user does not have yet is added. The
/// decision logic lives in the pure [planCatalogReconcile] so it can be tested
/// without any network or database.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/skills/user_skills_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// One entry in the catalog manifest.
class CatalogSkill {
  const CatalogSkill({
    required this.name,
    required this.description,
    required this.path,
    required this.hash,
    this.license,
    this.allowedTools = const [],
    this.resources = const [],
    this.enabled = true,
    this.coworkOnly = false,
  });

  final String name;
  final String description;

  /// Repo-relative folder, e.g. `skills/browser-skill`.
  final String path;

  /// `sha256:<hex>` of the SKILL.md, the update trigger.
  final String hash;

  final String? license;
  final List<String> allowedTools;

  /// Repo-relative resource paths (`references/…`, `scripts/…`, `assets/…`).
  final List<String> resources;

  /// Manifest toggle. A `false` entry stays in the catalog but is never exposed
  /// to the model — the reconciler skips it and drops any local copy. Defaults
  /// to true so a manifest without the field behaves exactly as before.
  final bool enabled;

  /// Manifest toggle. A `true` entry is offered only while the app is in CoWork
  /// mode and hidden from the normal chat UI. Carried through to the stored
  /// skill so the registry can gate it at prompt-build time.
  final bool coworkOnly;

  static CatalogSkill? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final description = json['description'];
    final path = json['path'];
    final hash = json['hash'];
    if (name is! String ||
        description is! String ||
        path is! String ||
        hash is! String) {
      return null;
    }
    return CatalogSkill(
      name: name,
      description: description,
      path: path,
      hash: hash,
      license: json['license'] as String?,
      allowedTools:
          (json['allowed_tools'] as List?)?.whereType<String>().toList() ??
          const [],
      resources:
          (json['resources'] as List?)?.whereType<String>().toList() ?? const [],
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      coworkOnly:
          json['cowork_only'] is bool ? json['cowork_only'] as bool : false,
    );
  }
}

/// The local state the reconciler needs about one stored catalog skill.
class LocalSkillState {
  const LocalSkillState({
    required this.id,
    required this.sourceHash,
    required this.baselineHash,
  });

  final String id;

  /// `sha256:<hex>` of the skill's current SKILL.md source.
  final String sourceHash;

  /// The catalog hash the skill was last seeded from, or null.
  final String? baselineHash;

  bool get isEdited => sourceHash != baselineHash;
}

/// An edited skill whose catalog version moved — the user is asked, never
/// overwritten.
class SkillUpdateSuggestion {
  const SkillUpdateSuggestion({required this.id, required this.catalog});

  /// Stored row id of the user's copy.
  final String id;

  /// The newer catalog version being offered.
  final CatalogSkill catalog;
}

/// The outcome of a reconcile: what to add, silently update, and suggest.
class ReconcilePlan {
  const ReconcilePlan({
    required this.toAdd,
    required this.toUpdate,
    required this.suggestions,
    required this.skippedBuiltin,
    this.toRemove = const [],
  });

  /// Catalog skills the user does not have — add automatically.
  final List<CatalogSkill> toAdd;

  /// Pristine copies whose catalog version changed — update silently. The value
  /// is the local row id to replace.
  final List<({String id, CatalogSkill catalog})> toUpdate;

  /// Edited copies whose catalog version changed — ask the user.
  final List<SkillUpdateSuggestion> suggestions;

  /// Catalog skills whose name is a compiled built-in — skipped (the built-in
  /// already provides them; catalog-overrides-builtin is a later enhancement).
  final List<CatalogSkill> skippedBuiltin;

  /// Local row ids of stored catalog skills whose catalog entry is now
  /// `enabled: false` — deleted so a disabled skill vanishes from the prompt.
  /// It reappears (via [toAdd]) if the entry is re-enabled later.
  final List<String> toRemove;

  bool get isEmpty =>
      toAdd.isEmpty &&
      toUpdate.isEmpty &&
      suggestions.isEmpty &&
      toRemove.isEmpty;
}

/// Pure reconciliation: decide what to do with each catalog entry given the
/// local state. No IO — every branch is unit-tested.
ReconcilePlan planCatalogReconcile({
  required List<CatalogSkill> catalog,
  required Map<String, LocalSkillState> localByCatalogName,
  required Set<String> builtinNames,
}) {
  final toAdd = <CatalogSkill>[];
  final toUpdate = <({String id, CatalogSkill catalog})>[];
  final suggestions = <SkillUpdateSuggestion>[];
  final skippedBuiltin = <CatalogSkill>[];
  final toRemove = <String>[];

  for (final entry in catalog) {
    if (!entry.enabled) {
      // Disabled: never add. Drop a PRISTINE local copy so it leaves the
      // prompt, but never an edited one — user edits are sacred here, the same
      // as the suggestion path never overwrites them. An edited copy the user
      // wants gone is theirs to delete.
      final local = localByCatalogName[entry.name];
      if (local != null && !local.isEdited) toRemove.add(local.id);
      continue;
    }
    if (builtinNames.contains(entry.name)) {
      skippedBuiltin.add(entry);
      continue;
    }
    final local = localByCatalogName[entry.name];
    if (local == null) {
      toAdd.add(entry);
      continue;
    }
    if (entry.hash == local.baselineHash) {
      // Already on this catalog version — nothing to do, edited or not.
      continue;
    }
    if (local.isEdited) {
      suggestions.add(SkillUpdateSuggestion(id: local.id, catalog: entry));
    } else {
      toUpdate.add((id: local.id, catalog: entry));
    }
  }

  return ReconcilePlan(
    toAdd: toAdd,
    toUpdate: toUpdate,
    suggestions: suggestions,
    skippedBuiltin: skippedBuiltin,
    toRemove: toRemove,
  );
}

class SkillsCatalogService {
  const SkillsCatalogService._();

  /// Raw fetch base for the catalog repo. Override with
  /// `--dart-define=SKILLS_CATALOG_BASE=…` (must end with a slash).
  static const String _kBase = String.fromEnvironment(
    'SKILLS_CATALOG_BASE',
    defaultValue:
        'https://raw.githubusercontent.com/chuk-development/chuk-skills/main/',
  );

  static const Duration _cacheTtl = Duration(hours: 24);
  static const Duration _httpTimeout = Duration(seconds: 5);

  static const String _kManifestKey = 'skills_catalog_manifest';
  static const String _kManifestTsKey = 'skills_catalog_manifest_ts';

  static bool _reconciling = false;

  /// Pending update suggestions from the last reconcile, for the settings UI.
  static List<SkillUpdateSuggestion> _suggestions = const [];
  static List<SkillUpdateSuggestion> get suggestions => _suggestions;

  /// Metadata key a catalog skill carries to mark itself CoWork-only. It rides
  /// inside the SKILL.md `metadata` block (parsed into [Skill.metadata]), so
  /// the flag is stored with the skill body and readable synchronously at
  /// prompt-build time — no dependence on the manifest having been fetched yet.
  static const String kCoworkOnlyMetaKey = 'cowork_only';

  /// True when a stored skill is marked CoWork-only via its metadata.
  static bool isCoworkOnly(Skill skill) =>
      skill.metadata[kCoworkOnlyMetaKey]?.trim().toLowerCase() == 'true';

  static String hashOf(String source) =>
      'sha256:${sha256.convert(utf8.encode(source)).toString()}';

  static Uri _manifestUri() => Uri.parse('$_kBase' 'index.json');
  static Uri _bodyUri(CatalogSkill skill) =>
      Uri.parse('$_kBase${skill.path}/SKILL.md');

  /// Fetches and parses the manifest, cache-first with a 24h TTL. Returns the
  /// cached copy (even if stale) on any network failure, or null if there is
  /// nothing cached.
  static Future<List<CatalogSkill>?> fetchManifest({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && await _cacheFresh()) {
      final cached = await _readCachedManifest();
      if (cached != null) return cached;
    }

    try {
      final resp = await http
          .get(_manifestUri())
          .timeout(_httpTimeout);
      if (resp.statusCode == 200 && resp.body.isNotEmpty) {
        final parsed = _parseManifest(resp.body);
        if (parsed != null) {
          await LocalChatCacheService.kvSet(_kManifestKey, resp.body);
          await LocalChatCacheService.kvSet(
            _kManifestTsKey,
            DateTime.now().toUtc().toIso8601String(),
          );
          return parsed;
        }
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[SkillsCatalog] manifest fetch failed: $error');
    }
    // Fall back to whatever is cached, even if stale.
    return _readCachedManifest();
  }

  static Future<bool> _cacheFresh() async {
    final ts = await LocalChatCacheService.kvGet(_kManifestTsKey);
    if (ts == null) return false;
    final when = DateTime.tryParse(ts);
    if (when == null) return false;
    return DateTime.now().toUtc().difference(when.toUtc()) < _cacheTtl;
  }

  static Future<List<CatalogSkill>?> _readCachedManifest() async {
    final raw = await LocalChatCacheService.kvGet(_kManifestKey);
    if (raw == null || raw.isEmpty) return null;
    return _parseManifest(raw);
  }

  static List<CatalogSkill>? _parseManifest(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['skills'] is! List) return null;
      final skills = <CatalogSkill>[];
      for (final entry in decoded['skills'] as List) {
        if (entry is Map) {
          final skill = CatalogSkill.fromJson(Map<String, dynamic>.from(entry));
          if (skill != null) skills.add(skill);
        }
      }
      return skills;
    } catch (error) {
      if (kDebugMode) debugPrint('[SkillsCatalog] manifest parse failed: $error');
      return null;
    }
  }

  static Future<String?> _fetchBody(CatalogSkill skill) async {
    try {
      final resp = await http.get(_bodyUri(skill)).timeout(_httpTimeout);
      if (resp.statusCode == 200 && resp.body.isNotEmpty) return resp.body;
    } catch (error) {
      if (kDebugMode) debugPrint('[SkillsCatalog] body fetch failed: $error');
    }
    return null;
  }

  /// Fetches the catalog and applies the plan: adds new skills, silently
  /// updates pristine ones, and records suggestions for edited ones. Safe to
  /// call at startup and on a manual refresh; a no-op when signed out.
  static Future<void> reconcile({bool forceRefresh = false}) async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      String? userId;
      try {
        userId = SupabaseService.auth.currentUser?.id;
      } catch (_) {
        userId = null;
      }
      if (userId == null) return;

      final catalog = await fetchManifest(forceRefresh: forceRefresh);
      if (catalog == null || catalog.isEmpty) return;

      final rows = await LocalChatCacheService.skillRows(userId);
      final localByCatalogName = <String, LocalSkillState>{};
      for (final row in rows) {
        final catalogName = row['catalog_name'] as String?;
        final source = row['source'] as String?;
        final id = row['id']?.toString();
        if (catalogName == null || source == null || id == null) continue;
        localByCatalogName[catalogName] = LocalSkillState(
          id: id,
          sourceHash: hashOf(source),
          baselineHash: row['baseline_hash'] as String?,
        );
      }

      final plan = planCatalogReconcile(
        catalog: catalog,
        localByCatalogName: localByCatalogName,
        builtinNames: SkillRegistry.builtinNames,
      );

      _suggestions = List.unmodifiable(plan.suggestions);
      if (plan.isEmpty) return;

      for (final entry in plan.toAdd) {
        await _applyCatalogSkill(entry);
      }
      for (final update in plan.toUpdate) {
        await _applyCatalogSkill(update.catalog, id: update.id);
      }
      for (final id in plan.toRemove) {
        try {
          await UserSkillsService.delete(id);
        } catch (error) {
          // A disabled skill failing to delete must not abort the reconcile.
          if (kDebugMode) {
            debugPrint('[SkillsCatalog] removing disabled skill failed: $error');
          }
        }
      }

      // Refresh the registry so the newly stored skills reach the prompt.
      await SkillRegistry.refreshUserSkills(forceRefresh: true);
    } catch (error) {
      if (kDebugMode) debugPrint('[SkillsCatalog] reconcile failed: $error');
    } finally {
      _reconciling = false;
    }
  }

  static Future<void> _applyCatalogSkill(
    CatalogSkill entry, {
    String? id,
  }) async {
    final body = await _fetchBody(entry);
    if (body == null) return;
    try {
      await UserSkillsService.save(
        body,
        id: id,
        catalogName: entry.name,
        baselineHash: entry.hash,
      );
    } catch (error) {
      // One skill failing (a spec violation upstream, a name clash) must not
      // abort the whole reconcile.
      if (kDebugMode) {
        debugPrint('[SkillsCatalog] applying "${entry.name}" failed: $error');
      }
    }
  }

  /// Accepts a pending suggestion: replaces the user's copy with the catalog
  /// version. Used by the settings UI.
  static Future<void> acceptSuggestion(SkillUpdateSuggestion suggestion) async {
    await _applyCatalogSkill(suggestion.catalog, id: suggestion.id);
    _suggestions = List.unmodifiable(
      _suggestions.where((s) => s.id != suggestion.id),
    );
    await SkillRegistry.refreshUserSkills(forceRefresh: true);
  }

  @visibleForTesting
  static void resetForTest() {
    _reconciling = false;
    _suggestions = const [];
  }
}
