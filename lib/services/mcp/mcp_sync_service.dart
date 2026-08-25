// lib/services/mcp/mcp_sync_service.dart
//
// Cross-device sync for MCP connectors, end-to-end encrypted.
//
// When a reader connects a server on their phone, the connection and its
// OAuth secrets must show up — and connect themselves — on their laptop, and
// the other way round. Disconnecting on one device removes it on the other.
//
// The secrets never leave the device in clear: each connection is packed into
// one blob and handed to [ServiceCredentialsService], which encrypts it with
// the same AES-256-GCM key the chats already use before it reaches Supabase.
// The server stores ciphertext and nothing else, so it cannot read a token.
//
// The reconcile decision is a pure function ([reconcileMcpSync]) so it can be
// reasoned about and tested without a network: given which ids are here, which
// were synced before and which are on the server, it says what to add, what to
// re-key and what to forget. The IO around it lives in [McpSyncService].

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/mcp/mcp_client.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/service_credentials_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/privacy_logger.dart';

/// One connection as it travels between devices: its metadata without the
/// cached tool list, plus its secrets, if it has any.
///
/// Tools are dropped on purpose. They are fetched live on the receiving
/// device, so a stale copy would only mislead, and leaving them out keeps the
/// blob small.
@immutable
class McpSyncBlob {
  const McpSyncBlob({required this.connection, this.secrets});

  /// The connection to recreate. Its [McpConnection.tools] is always empty
  /// here — the receiver lists them live.
  final McpConnection connection;

  /// The decrypted secrets map (`_McpSecrets.toJson`), or null for connectors
  /// that carry no stored token (an app-session server authenticates with the
  /// live app session instead).
  final Map<String, dynamic>? secrets;

  /// Pack a live connection, stripping its cached tools.
  static McpSyncBlob fromConnection(
    McpConnection connection,
    Map<String, dynamic>? secrets,
  ) => McpSyncBlob(
    connection: connection.copyWith(tools: const <McpTool>[]),
    secrets: secrets,
  );

  Map<String, dynamic> toJson() => {
    'connection': connection.toJson(),
    'secrets': secrets,
  };

  static McpSyncBlob fromJson(Map<String, dynamic> json) {
    final rawConnection = json['connection'];
    final connection = McpConnection.fromJson(
      rawConnection is Map
          ? Map<String, dynamic>.from(rawConnection)
          : const <String, dynamic>{},
    ).copyWith(tools: const <McpTool>[]);
    final rawSecrets = json['secrets'];
    return McpSyncBlob(
      connection: connection,
      secrets: rawSecrets is Map
          ? Map<String, dynamic>.from(rawSecrets)
          : null,
    );
  }

  /// The access token inside the secrets, if any. Used only to notice a token
  /// rotation — it is never logged or sent anywhere in clear.
  String? get accessToken => accessTokenOf(secrets);

  /// When the access token expires, if the secrets say. Used to keep an older
  /// token from clobbering a newer one during reconcile.
  DateTime? get expiresAt => expiresAtOf(secrets);
}

/// The access token buried in a `_McpSecrets.toJson` map, or null. Public only
/// so the pure reconcile tests can reach it; production callers stay in-file.
@visibleForTesting
String? accessTokenOf(Map<String, dynamic>? secrets) {
  if (secrets == null) return null;
  final tokens = secrets['tokens'];
  if (tokens is! Map) return null;
  final token = tokens['access_token'];
  return token is String && token.isNotEmpty ? token : null;
}

/// The access token's expiry from a `_McpSecrets.toJson` map, or null. Public
/// only for the reconcile tests; production callers stay in-file.
@visibleForTesting
DateTime? expiresAtOf(Map<String, dynamic>? secrets) {
  if (secrets == null) return null;
  final tokens = secrets['tokens'];
  if (tokens is! Map) return null;
  return DateTime.tryParse(tokens['expires_at']?.toString() ?? '');
}

/// What one reconcile pass decided to do.
@immutable
class McpSyncPlan {
  const McpSyncPlan({
    required this.toAdd,
    required this.toUpdate,
    required this.toRemove,
    required this.nextKnownSyncedIds,
  });

  /// Remote connections that are not here yet: add them and connect them.
  final Set<String> toAdd;

  /// Connections here whose remote token rotated to a strictly newer one:
  /// rewrite local secrets. A remote token that is not newer than the local
  /// one is left alone, so a stale device cannot clobber a fresh token.
  final Set<String> toUpdate;

  /// Connections here that were synced before but whose remote row is gone:
  /// a disconnect from the other device, honoured by forgetting them here.
  final Set<String> toRemove;

  /// The known-synced set to persist for the next pass — the ids confirmed to
  /// exist on the server this pass. A locally added connection that has not
  /// yet been seen on the server stays out of it, so it is never mistaken for
  /// a remote deletion.
  final Set<String> nextKnownSyncedIds;
}

/// Decide the sync actions. Pure: no IO, no clock, no globals.
///
/// [knownSyncedIds] are ids that a *previous* pull confirmed on the server —
/// not ids merely pushed from here. That distinction is what keeps a
/// just-connected connection, whose push has not come back around yet, from
/// looking like a remote deletion.
McpSyncPlan reconcileMcpSync({
  required Set<String> localIds,
  required Set<String> knownSyncedIds,
  required Set<String> remoteIds,
  required Map<String, String?> localAccessTokens,
  required Map<String, String?> remoteAccessTokens,
  Map<String, DateTime?> localTokenExpiries = const {},
  Map<String, DateTime?> remoteTokenExpiries = const {},
}) {
  final toAdd = remoteIds.difference(localIds);

  // Only ids that were confirmed remote before and are now missing count as a
  // remote deletion. A never-synced local-only connection is not in
  // knownSyncedIds, so it survives.
  final toRemove = localIds
      .intersection(knownSyncedIds)
      .difference(remoteIds);

  final present = remoteIds.intersection(localIds);
  final toUpdate = <String>{
    for (final id in present)
      if (_remoteTokenIsNewer(
        remoteToken: remoteAccessTokens[id],
        localToken: localAccessTokens[id],
        remoteExpiry: remoteTokenExpiries[id],
        localExpiry: localTokenExpiries[id],
      ))
        id,
  };

  return McpSyncPlan(
    toAdd: toAdd,
    toUpdate: toUpdate,
    toRemove: toRemove,
    nextKnownSyncedIds: Set<String>.from(remoteIds),
  );
}

/// True when two connections differ in any synced metadata field. Tools are
/// ignored — they are fetched live per device and never travel in the blob.
@visibleForTesting
bool metadataDiffers(McpConnection a, McpConnection b) =>
    a.name != b.name ||
    a.url != b.url ||
    a.description != b.description ||
    a.iconUrl != b.iconUrl ||
    a.addedByHand != b.addedByHand ||
    a.auth != b.auth;

/// True when the remote token should replace the local one: it exists, it
/// differs, and it is not older. "Not older" means the local expiry is unknown
/// or the remote expiry is strictly later — an older remote token never wins.
bool _remoteTokenIsNewer({
  required String? remoteToken,
  required String? localToken,
  required DateTime? remoteExpiry,
  required DateTime? localExpiry,
}) {
  if (remoteToken == null || remoteToken == localToken) return false;
  if (localExpiry == null) return true;
  return remoteExpiry != null && remoteExpiry.isAfter(localExpiry);
}

/// The IO around [reconcileMcpSync]: push on change, delete on disconnect,
/// pull and reconcile on start and on every sync tick.
class McpSyncService {
  McpSyncService._();

  /// `service_name` prefix in the `service_credentials` table. One row per
  /// connection, named `mcp_<connectionId>`.
  static const String _servicePrefix = 'mcp_';

  /// Where the known-synced ids live between passes.
  static const String _knownKey = 'mcp_synced_ids_v1';

  /// Ids whose remote row a disconnect could not delete yet. Kept so the next
  /// pull retries the delete and does not re-add the connection meanwhile.
  static const String _pendingDeleteKey = 'mcp_pending_delete_v1';

  /// Connectors change rarely, so a pull need not run on every 30 s chat tick.
  /// This floor keeps steady-state decrypt work down without a delay a reader
  /// would notice.
  static const Duration _minPullInterval = Duration(minutes: 2);

  static bool _pulling = false;
  static DateTime? _lastPullAt;

  /// A monotonic arm counter per id. Every arm (a disconnect) and every disarm
  /// (a reconnect) bumps it, so a background delete started for one disconnect
  /// can tell its own tombstone from a later one and never clears the wrong
  /// one. In memory only: the ABA it guards plays out within a single session.
  static final Map<String, int> _deleteEpochs = <String, int>{};

  static String _serviceName(String id) => '$_servicePrefix$id';

  /// The persisted tombstone-set key, exposed so tests read the same key the
  /// service writes instead of a duplicated literal.
  @visibleForTesting
  static String get pendingDeleteKeyForTest => _pendingDeleteKey;

  /// Clears in-memory pull and tombstone-arm state so tests start clean.
  @visibleForTesting
  static void resetForTests() {
    _deleteEpochs.clear();
    _pulling = false;
    _lastPullAt = null;
  }

  // ─── Push / delete ───────────────────────────────────────────────────────

  /// Encrypt and upload one connection's blob. Called after a connect and
  /// after any token refresh that rewrote its secrets. Never throws into the
  /// caller — a failed upload is retried on the next tick.
  static Future<void> push(McpConnection connection) async {
    try {
      // A connector the reader disconnected must never be re-uploaded. A token
      // refresh can fire from a reconcile fetch after the local forget, and the
      // resurrected row would be re-added on the next pull. Guarding here covers
      // every call site — connect, token refresh, re-push and repair.
      if ((await _loadIdSet(_pendingDeleteKey)).contains(connection.id)) return;
      // Upload the live entry's metadata, never a possibly-stale caller
      // snapshot, so a rename made here is not reverted on the remote row.
      final live = McpService.connectionFor(connection.id);
      if (live == null) return;
      final secrets = await McpService.internalReadSecretsJson(live.id);
      final blob = McpSyncBlob.fromConnection(live, secrets);
      await ServiceCredentialsService.save(_serviceName(live.id), blob.toJson());
      if (kDebugMode) pLog('McpSync: pushed ${live.id}');
    } catch (e) {
      if (kDebugMode) pLog('McpSync: push failed for ${connection.id} – $e');
    }
  }

  /// Delete the remote row for [id] so the disconnect propagates, and drop it
  /// from the known-synced set. Returns true when the remote row was removed;
  /// false when the delete could not be confirmed, so the caller can leave a
  /// tombstone and let the next pull retry.
  static Future<bool> delete(String id) async {
    try {
      final removed = await ServiceCredentialsService.delete(
            _serviceName(id),
            throwOnError: true,
          ) >
          0;
      if (removed) {
        // Serialise the known-set edit so a concurrent pull cannot overwrite it.
        await _locked(() async {
          final known = await _loadKnownSyncedIds();
          if (known.remove(id)) await _saveKnownSyncedIds(known);
        });
      }
      if (kDebugMode) pLog('McpSync: delete $id removed=$removed');
      return removed;
    } catch (e) {
      if (kDebugMode) pLog('McpSync: delete failed for $id – $e');
      return false;
    }
  }

  /// Remember that [id] must still be deleted remotely. Honoured by the next
  /// pull, which retries the delete and does not re-add the connection. Returns
  /// the epoch of this arm, which [deleteIfStillPending] uses to clear only the
  /// tombstone this disconnect set.
  static Future<int> markPendingDelete(String id) => _locked(() async {
    final pending = await _loadIdSet(_pendingDeleteKey);
    if (pending.add(id)) await _saveIdSet(_pendingDeleteKey, pending);
    final epoch = (_deleteEpochs[id] ?? 0) + 1;
    _deleteEpochs[id] = epoch;
    return epoch;
  });

  /// Forget any pending delete for [id]. Called when the reader reconnects a
  /// server they had disconnected, so its fresh remote row is not deleted by a
  /// stale tombstone on the next pull. Bumps the epoch so any in-flight delete
  /// for the old arm can no longer clear the tombstone.
  static Future<void> clearPendingDelete(String id) => _locked(() async {
    final pending = await _loadIdSet(_pendingDeleteKey);
    if (pending.remove(id)) await _saveIdSet(_pendingDeleteKey, pending);
    _deleteEpochs[id] = (_deleteEpochs[id] ?? 0) + 1;
  });

  /// Delete the remote row only while the tombstone from *this* disconnect
  /// ([epoch], from [markPendingDelete]) is still the current one. A reconnect
  /// or a later disconnect bumps the epoch, and this call then steps aside so a
  /// fresh remote row — or a newer tombstone — is not clobbered.
  static Future<void> deleteIfStillPending(String id, int epoch) async {
    if (_deleteEpochs[id] != epoch) return;
    if (!(await _loadIdSet(_pendingDeleteKey)).contains(id)) return;
    if (!await delete(id)) return;
    if (_deleteEpochs[id] != epoch) {
      // A reconnect (or a later disconnect) landed while the delete was in
      // flight. The row this delete removed may be the reconnect's fresh one,
      // so repair it rather than leave the connector to be reconciled away.
      await _repairAfterLateDelete(id);
      return;
    }
    // Clear only if this arm is still the current one — atomically, so a
    // concurrent mark/clear cannot lose an update.
    await _locked(() async {
      if (_deleteEpochs[id] != epoch) return;
      final pending = await _loadIdSet(_pendingDeleteKey);
      if (pending.remove(id)) await _saveIdSet(_pendingDeleteKey, pending);
    });
  }

  /// Run one id's reconcile step, swallowing and logging any failure so a
  /// single bad connector (e.g. a locked keystore) cannot abort the rest of
  /// the pass. It is retried on the next tick.
  static Future<void> _isolate(
    String what,
    String id,
    Future<void> Function() op,
  ) async {
    try {
      await op();
    } catch (e) {
      if (kDebugMode) pLog('McpSync: $what failed for $id – $e');
    }
  }

  /// A background delete for one arm can land after a reconnect wrote a fresh
  /// remote row. If the connection is live here and no delete is pending for
  /// it, re-push so the row the delete removed comes back.
  static Future<void> _repairAfterLateDelete(String id) async {
    // push guards against a live tombstone and a forgotten connection, so it
    // re-uploads only when the reconnect's connection is genuinely still here.
    final live = McpService.connectionFor(id);
    if (live != null) await push(live);
  }

  // ─── Pull + reconcile ──────────────────────────────────────────────────────

  /// Fetch every remote blob, decide what changed and apply it: add and
  /// connect new connections, re-key rotated ones, forget remotely deleted
  /// ones. A no-op when the backend is not ready, the reader is signed out, or
  /// no encryption key is loaded.
  static Future<void> pullAndReconcile() async {
    // Without a live backend, a user and an encryption key there is nothing to
    // fetch, and reconciling would wrongly treat every local connection as
    // deleted. Reading auth before Supabase is initialised throws, so guard on
    // that first — the startup call can land before initialisation completes.
    if (!SupabaseService.isInitialized) return;
    if (SupabaseService.auth.currentUser == null) return;
    if (!EncryptionService.hasKey) return;

    if (_pulling) return;
    final last = _lastPullAt;
    if (last != null && DateTime.now().difference(last) < _minPullInterval) {
      return;
    }
    _pulling = true;
    try {
      // The chat-sync tick can reach here before ToolCallHandler ran load().
      // Reconciling against an unloaded (empty) list would persist over the
      // stored connectors and drop the local-only ones. load() is idempotent.
      await McpService.load();
      // throwOnError so a transient network failure aborts here instead of
      // looking like an empty server and forgetting every synced connection.
      // undecryptable collects rows that are present but unreadable, so they
      // are not mistaken for deletions either.
      final undecryptable = <String>{};
      final Map<String, Map<String, dynamic>> all;
      try {
        all = await ServiceCredentialsService.loadAll(
          throwOnError: true,
          undecryptable: undecryptable,
        );
      } catch (e) {
        if (kDebugMode) pLog('McpSync: fetch failed, skipping reconcile – $e');
        // finally records the attempt, so the floor throttles the retry.
        return;
      }

      final remote = <String, McpSyncBlob>{};
      // Ids whose row is present but whose blob is malformed (unparseable or
      // its id disagrees with the row name). Like unreadable rows, they are
      // "still there", never deletions — otherwise a corrupt blob would delete
      // a working local connector.
      final rejectedIds = <String>{};
      for (final entry in all.entries) {
        if (!entry.key.startsWith(_servicePrefix)) continue;
        final id = entry.key.substring(_servicePrefix.length);
        if (id.isEmpty) continue;
        try {
          final blob = McpSyncBlob.fromJson(entry.value);
          // The row name is the source of truth for the id; a blob that
          // disagrees is malformed and would be re-added on every pass.
          if (blob.connection.id != id) {
            rejectedIds.add(id);
            continue;
          }
          remote[id] = blob;
        } catch (_) {
          rejectedIds.add(id);
        }
      }

      // Rows present but unreadable count as "still there", never as deletions.
      final unreadableIds = <String>{
        for (final name in undecryptable)
          if (name.startsWith(_servicePrefix))
            name.substring(_servicePrefix.length),
      };

      final known = await _loadKnownSyncedIds();
      final pending = await _loadIdSet(_pendingDeleteKey);
      final remoteIds = remote.keys.toSet();
      final localConnections = {
        for (final c in McpService.connections.value) c.id: c,
      };
      final localIds = localConnections.keys.toSet();

      final present = remoteIds.intersection(localIds);
      final localTokens = <String, String?>{};
      final localExpiries = <String, DateTime?>{};
      // Read the per-id secrets in parallel: each is a keystore round trip, and
      // in series they add up on the same isolate as the chat-sync decrypt.
      final presentList = present.toList();
      final localSecrets = await Future.wait(
        presentList.map(McpService.internalReadSecretsJson),
      );
      for (var i = 0; i < presentList.length; i++) {
        localTokens[presentList[i]] = accessTokenOf(localSecrets[i]);
        localExpiries[presentList[i]] = expiresAtOf(localSecrets[i]);
      }
      final remoteTokens = <String, String?>{
        for (final id in present) id: remote[id]!.accessToken,
      };
      final remoteExpiries = <String, DateTime?>{
        for (final id in present) id: remote[id]!.expiresAt,
      };

      final plan = reconcileMcpSync(
        localIds: localIds,
        knownSyncedIds: known,
        remoteIds: remoteIds,
        localAccessTokens: localTokens,
        remoteAccessTokens: remoteTokens,
        localTokenExpiries: localExpiries,
        remoteTokenExpiries: remoteExpiries,
      );

      // A connection this device is still trying to delete must not be re-added
      // from its surviving remote row; retry the remote delete instead.
      final toAdd = plan.toAdd.difference(pending);
      // An unreadable or malformed remote row is not a deletion — keep the
      // working local connector.
      final toRemove =
          plan.toRemove.difference(unreadableIds).difference(rejectedIds);

      // The awaits above can straddle a sign-out or a key clear. An empty
      // remote snapshot read in that state would mark every connector deleted,
      // so re-assert before touching local storage and bail out if it changed.
      if (SupabaseService.auth.currentUser == null ||
          !EncryptionService.hasKey) {
        if (kDebugMode) {
          pLog('McpSync: auth or key lost mid-pull, skipping reconcile');
        }
        return;
      }

      // Each id's work is isolated: a single failure (e.g. a locked keystore)
      // is logged and skipped, never aborting the deletes and re-pushes below.
      for (final id in toAdd) {
        await _isolate('add', id, () => _applyAdd(remote[id]!));
      }
      // _applyAdd already tried a live tool fetch; do not repeat it in the heal
      // pass below for the same ids in the same run.
      final freshlyAdded = Set<String>.from(toAdd);
      for (final id in plan.toUpdate) {
        final secrets = remote[id]!.secrets;
        if (secrets == null) continue;
        // Skip a connection the reader disconnected during the awaits above:
        // writing its secret back would leave key material with no connection.
        if (McpService.connectionFor(id) == null) continue;
        if ((await _loadIdSet(_pendingDeleteKey)).contains(id)) continue;
        // Never re-key a connector pointed at a non-https endpoint.
        if (!McpService.internalIsAcceptableUrl(remote[id]!.connection.url)) {
          continue;
        }
        await _isolate(
          're-key',
          id,
          () => McpService.internalWriteSecretsJson(id, secrets),
        );
      }

      // Propagate metadata a rename, icon or description change made on another
      // device — the token need not have moved. Keep the local tools: the
      // remote blob never carries them. (present and toRemove are disjoint, so
      // iterating present directly is enough.)
      for (final id in present) {
        final local = McpService.connectionFor(id);
        if (local == null) continue;
        if ((await _loadIdSet(_pendingDeleteKey)).contains(id)) continue;
        final remoteConn = remote[id]!.connection;
        // A URL change arriving by sync must not redirect a connector to a
        // plaintext endpoint the local token would then be sent to.
        if (!McpService.internalIsAcceptableUrl(remoteConn.url)) continue;
        if (metadataDiffers(local, remoteConn)) {
          await _isolate(
            'metadata',
            id,
            () => McpService.internalUpsertConnection(
              remoteConn.copyWith(tools: local.tools),
            ),
          );
        }
      }

      // Track forgets that fail (e.g. a locked keystore): the id stays local,
      // so it must also stay in the known set — otherwise the next pull reads
      // it as a local-only connector and re-pushes the connection the other
      // device deleted.
      final failedRemovals = <String>{};
      for (final id in toRemove) {
        try {
          await McpService.internalForgetLocal(id);
        } catch (e) {
          failedRemovals.add(id);
          if (kDebugMode) pLog('McpSync: remove failed for $id – $e');
        }
      }

      // A local connection the server has never seen: an offline connect, or a
      // push that failed silently. Re-push it so it still reaches the other
      // devices. Tombstoned ids and ids just forgotten are excluded.
      final toPush = localIds
          .difference(remoteIds)
          .difference(pending)
          .difference(toRemove);
      for (final id in toPush) {
        // push re-checks live state, so a disconnect during the awaits above
        // cannot resurrect a forgotten or tombstoned connector here.
        final live = McpService.connectionFor(id);
        if (live != null) await push(live);
      }

      // Retry deletes that a disconnect could not confirm earlier.
      await _retryPendingDeletes(pending, remoteIds);

      // Keep unreadable ids in the known set so a later real deletion of them
      // is still detected, and keep ids whose local forget failed so the retry
      // still reads as a remote deletion rather than a local-only re-push.
      // Under the lock, so a concurrent delete's known-set edit is not lost.
      await _locked(() => _saveKnownSyncedIds({
        ...plan.nextKnownSyncedIds,
        ...unreadableIds,
        ...rejectedIds,
        ...failedRemovals,
      }));

      // A connection added while offline keeps an empty tool list; heal it once
      // the server is reachable so it becomes usable without a reconnect. Skip
      // the ids just added this pass — _applyAdd already tried them.
      await _healEmptyTools(remoteIds.difference(freshlyAdded));

      if (kDebugMode) {
        pLog(
          'McpSync: reconciled '
          'add=${toAdd.length} '
          'update=${plan.toUpdate.length} '
          'remove=${toRemove.length}',
        );
      }
    } catch (e) {
      if (kDebugMode) pLog('McpSync: pull failed – $e');
    } finally {
      // Record the attempt regardless of outcome so a pass that keeps throwing
      // (e.g. a failing keystore write) is throttled to the floor like any
      // other, instead of re-running the whole pull on every 30 s chat tick.
      _lastPullAt = DateTime.now();
      _pulling = false;
    }
  }

  /// Retry the remote delete for every tombstoned id, dropping the ones that
  /// succeed — or that no longer have a remote row — from the pending set.
  static Future<void> _retryPendingDeletes(
    Set<String> pending,
    Set<String> remoteIds,
  ) async {
    if (pending.isEmpty) return;
    final resolved = <String>{};
    for (final id in pending) {
      // A reconnect may have cleared this tombstone while the pass ran its
      // network awaits. Deleting then would remove the row the reconnect just
      // pushed, and every other device would read that as a deletion.
      final live = await _loadIdSet(_pendingDeleteKey);
      if (!live.contains(id)) continue;
      // Capture the arm this delete belongs to; if a reconnect (and possibly a
      // re-disconnect) bumps it during the delete, the tombstone we resolve is
      // no longer ours to drop.
      final epoch = _deleteEpochs[id];
      if (!remoteIds.contains(id)) {
        if (_deleteEpochs[id] == epoch) resolved.add(id); // already gone
        continue;
      }
      if (await delete(id)) {
        if (_deleteEpochs[id] == epoch) {
          resolved.add(id); // deleted this arm; drop the tombstone
        } else {
          // A reconnect landed during the delete; the removed row may be its
          // fresh one. Repair it, and leave the new tombstone (if any) alone.
          await _repairAfterLateDelete(id);
        }
      }
    }
    // Re-read under the lock: a disconnect may have added a fresh tombstone
    // while this pass ran its network awaits. Drop only what we resolved,
    // never the whole key.
    await _locked(() async {
      final current = await _loadIdSet(_pendingDeleteKey);
      await _saveIdSet(_pendingDeleteKey, current.difference(resolved));
    });
  }

  /// Recreate a remote connection here and connect it: write its secrets, list
  /// its tools live from the stored token, then add it once with those tools so
  /// the model can use them at once. When the tools cannot be fetched (offline)
  /// the connection is still added empty and healed on a later pass.
  static Future<void> _applyAdd(McpSyncBlob blob) async {
    final connection = blob.connection;
    // Never send a token to a non-https (or non-loopback) endpoint, even one
    // that arrived encrypted from the reader's own device. The URL is the field
    // that decides where key material travels, so validate it here too.
    if (!McpService.internalIsAcceptableUrl(connection.url)) {
      if (kDebugMode) pLog('McpSync: rejected non-https synced url for ${connection.id}');
      return;
    }
    // A disconnect made on this device wins. Check before writing any secret.
    if ((await _loadIdSet(_pendingDeleteKey)).contains(connection.id)) return;
    if (blob.secrets != null) {
      await McpService.internalWriteSecretsJson(connection.id, blob.secrets!);
    }
    // Fetching tools may refresh (rotate) the stored token via _clientFor.
    final tools = await McpService.internalFetchTools(connection);
    // The fetch above can straddle a disconnect the reader made on this device.
    // Do not add back a connection they just forgot.
    if ((await _loadIdSet(_pendingDeleteKey)).contains(connection.id)) {
      // Drop the secret we just wrote so no key material outlives the
      // disconnect.
      await McpService.internalForgetLocal(connection.id);
      return;
    }
    try {
      await McpService.internalUpsertConnection(
        tools == null || tools.isEmpty
            ? connection
            : connection.copyWith(tools: tools),
      );
    } catch (e) {
      // If the connection cannot be persisted, drop the secret we just wrote so
      // no orphan key material is left behind, then let the caller log it.
      await McpService.internalForgetLocal(connection.id);
      rethrow;
    }
    // The connection is live now, so push can run: if the fetch rotated the
    // token, this uploads the fresh one so the other devices pick it up too.
    // Use the live entry, not the pre-fetch snapshot, so no stale metadata is
    // written back over the remote row.
    final live = McpService.connectionFor(connection.id);
    if (live != null) await push(live);
  }

  /// Refetch tools for synced connections that have none yet (added offline).
  static Future<void> _healEmptyTools(Set<String> remoteIds) async {
    for (final connection in McpService.connections.value) {
      if (connection.tools.isNotEmpty) continue;
      if (!remoteIds.contains(connection.id)) continue;
      final tools = await McpService.internalFetchTools(connection);
      if (tools == null || tools.isEmpty) continue;
      // Re-read the live entry: a metadata update during the fetch must not be
      // reverted, and a connection forgotten during it must not come back.
      final live = McpService.connectionFor(connection.id);
      if (live == null) continue;
      await McpService.internalUpsertConnection(live.copyWith(tools: tools));
    }
  }

  // ─── Persisted id sets (known-synced, pending-delete) ──────────────────────

  static Future<Set<String>> _loadKnownSyncedIds() => _loadIdSet(_knownKey);
  static Future<void> _saveKnownSyncedIds(Set<String> ids) =>
      _saveIdSet(_knownKey, ids);

  static Future<Set<String>> _loadIdSet(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(key)?.toSet() ?? <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _saveIdSet(String key, Set<String> ids) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(key, ids.toList());
    } catch (_) {
      // A missed write is recovered on the next pass.
    }
  }

  // A single-slot async lock. Every load-modify-save of a persisted id set has
  // an await between its read and its write, and the pull runs fire-and-forget
  // alongside user connects and disconnects. Serialising the mutations here
  // stops one from overwriting another's change and losing a tombstone.
  static Future<void> _idSetGate = Future<void>.value();

  static Future<T> _locked<T>(Future<T> Function() action) {
    final previous = _idSetGate;
    final completer = Completer<void>();
    _idSetGate = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}
