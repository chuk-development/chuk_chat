// lib/services/mcp/mcp_service.dart
//
// Connecting, storing and sharing MCP connectors — the device half.
//
// This is the Agents adaptation of chuk_chat's McpService. The connectors UI
// (the list, the connect card, the detail page) is a verbatim port and calls
// exactly the same surface: `connections`, `connect`, `connectByUrl`,
// `connectWithCredentials`, `disconnect`, `connectionFor`. What changed is what
// sits behind that surface.
//
// chuk_chat ran the live MCP client here and forwarded nothing — the device WAS
// the transport. Agents's transport is the paired local Python backend: the
// host dials each server and discovers the tools when a task runs (see
// McpStore.forwardPayloads and the agent's `mcp_client.py`).
//
// The sign-in, though, stays on the device, verbatim from chuk_chat: the
// browser opens here, the loopback listener catches the redirect here, and the
// token is exchanged here. It has to be — an OAuth consent screen needs a
// person in front of it, and the host has no screen. What the device then
// hands over is the whole record: the access token AND the refresh token, the
// token endpoint and the registered client, so the host mints its own tokens
// for as long as the run lasts, with the app closed.
//
// The connector set is persisted locally by [McpStore] and mirrored, encrypted,
// to Supabase by [McpConnectorSync] — the same owner-only, ciphertext-only
// scheme the pairing record already uses, so connectors survive a reinstall.
//
// MERGE NOTE (chuk_chat merge): this file keeps the Agents structure, because
// the Agents MCP stack is the source of truth (docs/CHAT_UI_IMPORT.md). Two
// things came back from upstream on top of it: the reachability check the
// upstream connectors page reads (`unreachable`, `verifyReachable`,
// `verifyAllReachable`) and the device-side tool call `tool_executor.dart`
// makes (`resolve`, `call`, `_clientFor`, `endpointWithCredentialsForTest`).
// Dropped with no caller left in the merged tree: `refreshTools`, the
// `internal*` sync seams (`mcp_sync_service.dart` is the Agents stub now) and
// upstream's own secret/prefs helpers (`_McpSecrets`, `_readSecrets`,
// `_writeSecrets`, `_persist`, `_readConnectionsRaw`, `_forgetLocal`), all of
// which McpStore has replaced.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
// Only the call path below uses the device-side client; `show` keeps its
// McpTool from clashing with the one in mcp_connection.dart.
import 'package:chuk_chat/services/mcp/mcp_client.dart'
    show McpCallResult, McpClient, McpException, McpUnauthorized;
import 'package:chuk_chat/services/mcp/chuk_mcp_mirror.dart';
import 'package:chuk_chat/services/mcp/mcp_connector_sync.dart';
import 'package:chuk_chat/services/mcp/mcp_oauth.dart';
import 'package:chuk_chat/services/mcp/mcp_redirect.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/mcp/mcp_probe_control.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// The MCP revision the challenge probe claims to speak. It only has to be a
/// version the server recognizes well enough to answer `401` instead of
/// `400`; nothing else of the protocol is spoken here.
const String kMcpProtocolVersion = '2025-06-18';

/// What a connect attempt ended in, for the UI to show.
enum McpConnectStatus { connected, cancelled, failed }

/// A handle the screen keeps so it can stop a connect. On Agents the connect
/// completes at once — the host does the sign-in later — so this rarely fires,
/// but the ported UI keeps it so the screens stay identical to chuk_chat's.
class McpConnectCanceler {
  final Completer<void> _canceled = Completer<void>();

  void cancel() {
    if (!_canceled.isCompleted) _canceled.complete();
  }

  bool get isCanceled => _canceled.isCompleted;
  Future<void> get whenCanceled => _canceled.future;
}

/// Thrown inside [McpService] when the user cancels the sign-in. Private: it
/// never leaves the service — it is turned into [McpConnectStatus.cancelled].
class _ConnectCanceled implements Exception {
  const _ConnectCanceled();
}

class McpConnectResult {
  const McpConnectResult(this.status, {this.message, this.connection});

  final McpConnectStatus status;
  final String? message;
  final McpConnection? connection;
}

class McpService {
  McpService._();

  /// The local persistence. Swappable in tests through [resetForTest].
  static McpStore store = McpStore();

  /// The encrypted Supabase mirror. Swappable in tests through [resetForTest].
  static McpConnectorSync sync = const McpConnectorSync();

  /// chuk_chat's per-connector rows in `service_credentials` (bead
  /// cowork-hza): read after the own mirror to fill what chuk connected.
  static ChukMcpMirror chukMirror = const ChukMcpSync();

  static final ValueNotifier<List<McpConnection>> connections =
      ValueNotifier<List<McpConnection>>(const <McpConnection>[]);

  static bool _loaded = false;

  /// Injected in tests so no browser opens and no real server is called.
  @visibleForTesting
  static Future<bool> Function(Uri url)? launcher;

  /// Injected in tests so the OAuth discovery, registration and token
  /// exchange run against a fake [http.Client] instead of the network.
  @visibleForTesting
  static McpOAuth Function()? oauthFactory;

  /// Injected in tests so the unauthenticated challenge probe answers from a
  /// fake [http.Client] instead of the network.
  @visibleForTesting
  static http.Client Function()? probeClientFactory;

  /// Reset for a test: inject a store / sync and forget the loaded state.
  @visibleForTesting
  static void resetForTest({
    McpStore? store,
    McpConnectorSync? sync,
    ChukMcpMirror? chukMirror,
  }) {
    McpService.store = store ?? McpStore();
    McpService.sync = sync ?? const McpConnectorSync();
    McpService.chukMirror = chukMirror ?? const ChukMcpSync();
    connections.value = const <McpConnection>[];
    launcher = null;
    oauthFactory = null;
    probeClientFactory = null;
    _loaded = false;
    _adopting = null;
    _adoptedAt = null;
    _attemptedAt = null;
    adoptInterval = kDefaultAdoptInterval;
    adoptRetryInterval = kDefaultAdoptRetryInterval;
    clock = DateTime.now;
  }

  // ─── Storage ───────────────────────────────────────────────────────────

  /// Load the connector set into [connections]. Runs once. Reads the local
  /// store first, then tries the encrypted Supabase mirror; a mirror that is
  /// ahead (the usual case on a fresh install) is adopted into the local
  /// store so the host sees the same set the user's other devices do.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      connections.value = await store.load();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not read connections: $e');
    }
    unawaited(adoptMirrors());
  }

  // MERGE NOTE: upstream moved this list out of SharedPreferences into the
  // SQLite kv_cache (_readConnectionsRaw/_persist, with a one-time migration
  // that DELETES the prefs key). Dropped here: in the Agents structure McpStore
  // owns the same key ('mcp_connections_v1') in SharedPreferences, so running
  // upstream's migration would move the connectors out from under the store and
  // the list would come back empty. Redo the kv_cache move in mcp_store.dart if
  // it is wanted.

  /// Adopt the encrypted mirror and wait for it, for a test. [load] fires the
  /// same work without awaiting it, which a test cannot observe.
  @visibleForTesting
  static Future<void> pullRemoteForTest() => adoptMirrors(force: true);

  @visibleForTesting
  static Future<void> pushRemoteForTest() => _pushRemote();

  // ─── Adopting the mirrors ──────────────────────────────────────────────
  //
  // Reading the mirrors used to happen exactly once, fired by [load] the first
  // time the connectors page was built (bead cowork-7zd). That is too late and
  // too rare on two counts. A user who never opens that page has an empty local
  // store, so `McpStore.forwardPayloads` hands the Python host NOTHING and the
  // agent cannot call a connector the user signed into in chuk_chat. And the
  // one attempt is made whether or not the mirrors are readable yet — no signed
  // in user, no encryption key on a cold start — after which the latch made
  // sure nothing tried again for the life of the process.
  //
  // So the pull is its own throttled, single-flight, retrying operation now,
  // driven from three places: [load] (the page), `McpSyncService` (the chat
  // sync tick, which already fires only when online, signed in and keyed) and
  // `McpStore.forwardPayloads` (the task launch, so the very first task of a
  // cold start still carries what chuk connected).
  //
  // Adopting is deliberately additive. A connector chuk knows and this device
  // does not is added; a secret is taken only when the local record is
  // unusable, so a poll can never sign the user out by writing an older token
  // over a live one.

  /// How long a successful adoption is trusted before the next caller pulls
  /// again. Long enough that a 30-second sync tick is nearly free, short
  /// enough that a connector signed into in chuk_chat shows up here by itself.
  static const Duration kDefaultAdoptInterval = Duration(minutes: 5);

  /// How long to wait after an attempt that could NOT read the mirror (no
  /// user, no key, no network) before trying again.
  static const Duration kDefaultAdoptRetryInterval = Duration(seconds: 20);

  static Duration adoptInterval = kDefaultAdoptInterval;
  static Duration adoptRetryInterval = kDefaultAdoptRetryInterval;

  /// Test seam so a test can move time instead of waiting for it.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static Future<void>? _adopting;
  static DateTime? _adoptedAt;
  static DateTime? _attemptedAt;

  /// True when a pull has read the mirrors at least once.
  static bool get hasAdopted => _adoptedAt != null;

  /// Pull both mirrors and adopt what this device is missing.
  ///
  /// Single-flight: a second caller joins the pull already running rather than
  /// starting its own. Throttled: a successful pull is trusted for
  /// [adoptInterval] and a failed one is retried after [adoptRetryInterval].
  /// [force] ignores both, for a test and for an explicit refresh.
  ///
  /// Never throws — every failure resolves to "nothing adopted this time".
  static Future<void> adoptMirrors({bool force = false}) {
    final running = _adopting;
    if (running != null) return running;
    if (!force && !_isAdoptDue()) return Future<void>.value();
    final future = _adoptOnce();
    _adopting = future;
    return future.whenComplete(() {
      if (identical(_adopting, future)) _adopting = null;
    });
  }

  static bool _isAdoptDue() {
    final now = clock();
    final adopted = _adoptedAt;
    if (adopted != null && now.difference(adopted) < adoptInterval) {
      return false;
    }
    final attempted = _attemptedAt;
    if (attempted != null && now.difference(attempted) < adoptRetryInterval) {
      return false;
    }
    return true;
  }

  static Future<void> _adoptOnce() async {
    _attemptedAt = clock();
    var readable = false;
    try {
      readable = await _pullOwnMirror();
      // Both mirrors always run: the own one holds this user's Agents set, the
      // chuk one what the other app connected, and either may be the ahead one.
      readable = await _pullChukMirror() || readable;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not adopt the mirrors: $e');
    }
    if (readable) _adoptedAt = clock();
  }

  /// Adopt the own encrypted mirror. Returns true when it was readable — a
  /// blob came back, whether or not it held anything new.
  static Future<bool> _pullOwnMirror() async {
    try {
      final blob = await sync.load();
      if (blob == null) return false;
      final rawConnections = blob['connections'];
      if (rawConnections is! List) return true;
      final rawSecrets = blob['secrets'];
      final secrets = rawSecrets is Map
          ? rawSecrets
          : const <Object?, Object?>{};

      for (final entry in rawConnections) {
        if (entry is! Map) continue;
        final connection = McpConnection.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (connection.id.isEmpty || connection.url.isEmpty) continue;

        final secret = secrets[connection.id];
        McpSecrets? record;
        Map<String, String> apiCreds = const <String, String>{};
        if (secret is Map) {
          record = _recordFromMirror(secret);
          final creds = secret['api_credentials'];
          if (creds is Map) {
            apiCreds = <String, String>{
              for (final e in creds.entries)
                e.key.toString(): e.value.toString(),
            };
          }
        }

        await store.upsert(connection);
        // Adopt the mirrored secret only when this device has nothing it could
        // still use. A device that has signed in refreshes its own token, and
        // the mirror is written on connect and disconnect, so it is routinely
        // the older copy — overwriting a live record with it would sign the
        // user back out. But "unusable" is the test, not "absent": a record
        // whose bearer has lapsed with nothing to renew it (a sign-in from
        // before the refresh material was kept) is worth replacing with a good
        // one another device just mirrored.
        if (record != null &&
            _isUsable(record) &&
            !await _hasUsableRecord(connection.id)) {
          await store.setSecrets(connection.id, record);
        }
        if (apiCreds.isNotEmpty) {
          await store.setApiCredentials(connection.id, apiCreds);
        }
      }
      connections.value = await store.load();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not pull the mirror: $e');
      return false;
    }
  }

  /// What chuk_chat connected, adopted where this device has nothing
  /// (bead cowork-hza). A connector chuk knows and Agents does not is added
  /// with chuk's config; its secrets are taken only when the local record is
  /// unusable (47's rule — never over a live one, a mirror can be older); its
  /// API credentials only when none are stored here. Then the list is the
  /// truth again and the next task forwards the tokens to the host.
  static Future<bool> _pullChukMirror() async {
    try {
      final rows = await chukMirror.load();
      // Null is "could not read at all" (no Supabase, no user, no key, no
      // table); an empty map is a mirror that was read and holds nothing.
      if (rows == null) return false;
      if (rows.isEmpty) return true;
      final local = {for (final c in await store.load()) c.id: c};
      var changed = false;
      for (final row in rows.values) {
        final connection = McpConnection.fromJson(
          row.connection,
        ).copyWith(tools: const <McpTool>[]);
        if (connection.id.isEmpty || connection.url.isEmpty) continue;
        if (!local.containsKey(connection.id)) {
          await store.upsert(connection);
          changed = true;
        }
        final secrets = row.secrets;
        if (secrets == null) continue;
        McpSecrets? record;
        try {
          record = McpSecrets.fromJson(secrets);
        } catch (_) {
          record = null;
        }
        if (record != null &&
            _isUsable(record) &&
            !await _hasUsableRecord(connection.id)) {
          await store.setSecrets(connection.id, record);
          changed = true;
        }
        final creds = secrets['api_credentials'];
        if (creds is Map &&
            creds.isNotEmpty &&
            (await store.apiCredentialsFor(connection.id)).isEmpty) {
          await store.setApiCredentials(connection.id, <String, String>{
            for (final e in creds.entries) e.key.toString(): e.value.toString(),
          });
          changed = true;
        }
      }
      // The list is the truth again either way; a pull is rare and cheap.
      if (changed || rows.isNotEmpty) connections.value = await store.load();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not read chuk\'s mirror: $e');
      return false;
    }
  }

  /// Read the whole connector set and its secrets and push it to the encrypted
  /// mirror. Best-effort; never throws into the caller.
  static Future<void> _pushRemote() async {
    try {
      final list = await store.load();
      if (list.isEmpty) {
        await sync.clear();
        return;
      }
      final secrets = <String, dynamic>{};
      for (final c in list) {
        final entry = <String, dynamic>{};
        if (c.auth == McpAuth.oauth) {
          final record = await store.secretsFor(c.id);
          if (record != null && !record.isEmpty) {
            entry['record'] = record.toJson();
            // Older builds of this app read `token`, so keep writing it too.
            // A mirror written here must stay readable by a device that has
            // not updated yet.
            if (record.tokens.accessToken.isNotEmpty) {
              entry['token'] = record.tokens.accessToken;
            }
          }
        }
        if (c.auth == McpAuth.apiKey) {
          final creds = await store.apiCredentialsFor(c.id);
          if (creds.isNotEmpty) entry['api_credentials'] = creds;
        }
        if (entry.isNotEmpty) secrets[c.id] = entry;
      }
      await sync.save(<String, dynamic>{
        'connections': <Map<String, dynamic>>[for (final c in list) c.toJson()],
        'secrets': secrets,
      });
      await _pushChukRows(list);
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not push the mirror: $e');
    }
  }

  /// The write-back into chuk_chat's table (bead cowork-hza): one
  /// `mcp_<id>` row per local connector, in exactly chuk's blob shape
  /// (`connection` without tools, `secrets` = the record with the API
  /// credentials folded in, or null), so a connector connected here shows up
  /// connected in chuk_chat. Rows are only ever upserted here; a delete
  /// happens in [disconnect] alone, after the row was read back and verified.
  static Future<void> _pushChukRows(List<McpConnection> list) async {
    for (final c in list) {
      try {
        await chukMirror.save(await _chukRowFor(c));
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ [MCP] chuk row for ${c.id} skipped: $e');
      }
    }
  }

  static Future<ChukMcpRow> _chukRowFor(McpConnection c) async {
    Map<String, dynamic>? secrets;
    if (c.auth == McpAuth.oauth) {
      final record = await store.secretsFor(c.id);
      if (record != null && !record.isEmpty) secrets = record.toJson();
    }
    if (c.auth == McpAuth.apiKey) {
      final creds = await store.apiCredentialsFor(c.id);
      if (creds.isNotEmpty) {
        secrets = <String, dynamic>{
          'credentials': const {'client_id': ''},
          'tokens': const {'access_token': ''},
          'api_credentials': creds,
        };
      }
    }
    return ChukMcpRow(
      id: c.id,
      connection: c.copyWith(tools: const <McpTool>[]).toJson(),
      secrets: secrets,
    );
  }

  /// Removes chuk's row for [id], but only a row that is really this
  /// connector: read back first and checked to name the same catalogue id.
  /// A missing or foreign row is left alone. Never a bulk delete.
  static Future<void> _deleteChukRow(String id) async {
    try {
      final rows = await chukMirror.load();
      final row = rows?[id];
      if (row == null) return;
      if (row.id != id || (row.connection['id'] ?? '').toString() != id) return;
      await chukMirror.delete(id);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [MCP] chuk row delete for $id skipped: $e');
      }
    }
  }

  // ─── Connecting ────────────────────────────────────────────────────────

  /// Record [url] as a connector the user wants, signing in first when the
  /// server needs it.
  ///
  /// An [McpAuth.oauth] server with no usable record runs the browser sign-in
  /// here and stores what comes out of it — that is the token the host is then
  /// handed. An [McpAuth.appSession] server needs none (the host resolves the
  /// account credential), and a server that is already signed in is not asked
  /// to do it again. Tool discovery still happens host-side when a task runs.
  static Future<McpConnectResult> connect({
    required String id,
    required String name,
    required String url,
    String description = '',
    String? iconUrl,
    bool addedByHand = false,
    McpAuth auth = McpAuth.oauth,
    McpConnectCanceler? canceler,
  }) async {
    final endpoint = Uri.tryParse(url);
    if (endpoint == null || !_isAcceptableEndpoint(endpoint)) {
      return const McpConnectResult(
        McpConnectStatus.failed,
        message: 'That is not an https address.',
      );
    }

    try {
      if (auth == McpAuth.oauth && !await _hasUsableRecord(id)) {
        final token = await _authorize(
          id: id,
          endpoint: endpoint,
          canceler: canceler,
          // A catalogue connector declares that it signs in, so a server that
          // will not is an error worth showing. A URL the user typed declares
          // nothing: plenty of MCP servers are open, and refusing to add one
          // because it published no sign-in metadata would be wrong. It is
          // then recorded without a token and the host finds out for itself.
          signInOptional: addedByHand,
        );
        if (token == null) {
          return const McpConnectResult(McpConnectStatus.cancelled);
        }
      }

      final connection = McpConnection(
        id: id,
        name: name.trim(),
        url: url,
        description: description,
        iconUrl: iconUrl,
        addedByHand: addedByHand,
        auth: auth,
      );
      // The sign-in above already wrote the record; a null token here leaves
      // it, and any token held from an earlier connect, alone.
      await store.upsert(connection);
      connections.value = await store.load();
      unawaited(_pushRemote());
      // The host has the credentials now; ask it to dial before the user goes
      // looking for the tools this connector was signed in for.
      unawaited(probe());
      return McpConnectResult(
        McpConnectStatus.connected,
        connection: connection,
      );
    } on McpAuthException catch (e) {
      return McpConnectResult(McpConnectStatus.failed, message: e.message);
    } catch (e) {
      return McpConnectResult(
        McpConnectStatus.failed,
        message: 'Could not save the connector: $e',
      );
    }
  }

  /// True when [id] already holds a record this device can still use.
  static Future<bool> _hasUsableRecord(String id) async =>
      _isUsable(await store.secretsFor(id));

  /// Whether [record] can still get a request authenticated: a bearer that has
  /// not lapsed, or a refresh token to mint a new one with. Anything else means
  /// the user has to sign in again.
  static bool _isUsable(McpSecrets? record) {
    if (record == null) return false;
    if ((record.tokens.refreshToken ?? '').isNotEmpty) return true;
    if (record.tokens.accessToken.isEmpty) return false;
    return !record.tokens.isExpired;
  }

  /// Record a server that takes the user's own credentials on its URL (an API
  /// key, a project id) instead of a browser sign-in. Only the plain base
  /// [url] is stored in the connection row; the values go to secure storage,
  /// keyed by the connection id, and the host gets them on the URL it dials
  /// (see [McpStore.forwardPayloads]).
  static Future<McpConnectResult> connectWithCredentials({
    required String id,
    required String name,
    required String url,
    required Map<String, String> credentials,
    String description = '',
    String? iconUrl,
    bool addedByHand = false,
  }) async {
    final base = Uri.tryParse(url);
    if (base == null || !_isAcceptableEndpoint(base)) {
      return const McpConnectResult(
        McpConnectStatus.failed,
        message: 'That is not an https address.',
      );
    }

    try {
      final connection = McpConnection(
        id: id,
        name: name.trim(),
        url: url,
        description: description,
        iconUrl: iconUrl,
        addedByHand: addedByHand,
        auth: McpAuth.apiKey,
      );
      await store.upsert(connection);
      await store.setApiCredentials(id, credentials);
      connections.value = await store.load();
      unawaited(_pushRemote());
      // The host has the credentials now; ask it to dial before the user goes
      // looking for the tools this connector was signed in for.
      unawaited(probe());
      return McpConnectResult(
        McpConnectStatus.connected,
        connection: connection,
      );
    } catch (e) {
      return McpConnectResult(
        McpConnectStatus.failed,
        message: 'Could not save the connector: $e',
      );
    }
  }

  /// Add a server the user typed in by hand.
  static Future<McpConnectResult> connectByUrl(
    String url, {
    String? name,
    McpConnectCanceler? canceler,
  }) {
    final trimmed = url.trim();
    final id = slugFor(trimmed);
    // No live server to name it, so fall back to the host — a hand-added row
    // with an empty title is a blank line the reader cannot act on.
    final derivedName = name?.trim().isNotEmpty == true
        ? name!.trim()
        : (Uri.tryParse(trimmed)?.host ?? '');
    return connect(
      id: id,
      name: derivedName,
      url: trimmed,
      addedByHand: true,
      canceler: canceler,
    );
  }

  /// Forget a server: its config and its secrets, here and on the mirror.
  static Future<void> disconnect(String id) async {
    // No connection left, so nothing to report as dead (upstream did this in
    // _forgetLocal, which this structure does not have).
    _recordReachable(id, true);
    await store.remove(id);
    connections.value = await store.load();
    unawaited(_pushRemote());
    unawaited(_deleteChukRow(id));
  }

  // ─── Signing in ────────────────────────────────────────────────────────

  /// Run the OAuth flow for [endpoint] and store what came out of it.
  ///
  /// Returns the access token; an empty string when [signInOptional] is set
  /// and the server named no sign-in at all (nothing to authorize, so nothing
  /// is stored); and null when the user cancelled or closed the browser.
  ///
  /// Ported verbatim from chuk_chat, minus the part that dialed the server:
  /// discovery → dynamic client registration → authorization code with PKCE
  /// and a `resource` parameter → token. No client id is baked into the app,
  /// so any compliant MCP URL can be signed in to.
  static Future<String?> _authorize({
    required String id,
    required Uri endpoint,
    String? wwwAuthenticate,
    McpConnectCanceler? canceler,
    bool signInOptional = false,
  }) async {
    final oauth = (oauthFactory ?? McpOAuth.new)();
    // Ask the server what it wants before guessing. The challenge names the
    // metadata document (a server may publish it somewhere other than the two
    // well-known paths) and the scopes it wants (Atlassian and Linear name
    // theirs only here — without them the token is minted for the wrong grant
    // and every tool call comes back 403). chuk_chat got this for free because
    // it dialed the server with its MCP client; Agents has no device-side MCP
    // client, so it sends one unauthenticated request and reads the header.
    final challenge = wwwAuthenticate ?? await _challengeFor(endpoint);
    final McpAuthServer server;
    try {
      server = await oauth.discover(endpoint, wwwAuthenticate: challenge);
    } on McpAuthException {
      if (signInOptional) return '';
      rethrow;
    }

    final listener = await McpRedirectListener.start();
    try {
      final credentials = await oauth.register(
        server,
        listener.redirectUri,
        scope: server.scopesSupported.join(' '),
      );

      final request = oauth.buildAuthorizationRequest(
        server: server,
        credentials: credentials,
        redirectUri: listener.redirectUri,
        resource: McpOAuth.canonicalResource(endpoint),
        scopes: server.scopesSupported,
      );

      final opened = await (launcher ?? _launch)(request.url);
      if (!opened) {
        throw const McpAuthException('The browser did not open.');
      }

      // Wait for the redirect, but let the user cancel out of it. The cancel
      // and the five-minute timeout both end the wait; only the real callback
      // carries a code on.
      final Uri callback;
      try {
        callback = await Future.any(<Future<Uri>>[
          listener.callback.timeout(
            const Duration(minutes: 5),
            onTimeout: () => throw const McpAuthException(
              'The sign-in took too long. Try again.',
            ),
          ),
          if (canceler != null)
            canceler.whenCanceled.then<Uri>(
              (_) => throw const _ConnectCanceled(),
            ),
        ]);
      } on _ConnectCanceled {
        await _closeBrowser();
        return null;
      }

      // The sign-in tab has done its job — close it so the user lands back in
      // the app instead of on a "you can close this" page.
      await _closeBrowser();

      final tokens = await oauth.exchange(request, callback);
      await store.setSecrets(
        id,
        McpSecrets(
          credentials: credentials,
          tokens: tokens,
          issuer: server.issuer,
          authorizationEndpoint: server.authorizationEndpoint.toString(),
          tokenEndpoint: server.tokenEndpoint.toString(),
          scope: request.scope,
        ),
      );
      return tokens.accessToken;
    } finally {
      await listener.close();
    }
  }

  /// The `WWW-Authenticate` challenge [endpoint] answers an unauthenticated
  /// request with, or null when it does not challenge, cannot be reached, or
  /// the request takes too long.
  ///
  /// This is one request, not a client: an MCP `initialize` body is posted so
  /// the server sees a well-formed call, and only the status and one header
  /// are read. A failure here is not an error — discovery then falls back to
  /// the well-known paths, which is where it was before.
  static Future<String?> _challengeFor(Uri endpoint) async {
    final client = (probeClientFactory ?? http.Client.new)();
    try {
      final response = await client
          .post(
            endpoint,
            headers: const <String, String>{
              'content-type': 'application/json',
              'accept': 'application/json, text/event-stream',
            },
            body: jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': <String, dynamic>{
                'protocolVersion': kMcpProtocolVersion,
                'capabilities': <String, dynamic>{},
                'clientInfo': <String, dynamic>{
                  'name': McpOAuth.clientName,
                  'version': '1',
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 401 && response.statusCode != 403) return null;
      final header = response.headers['www-authenticate'];
      return (header == null || header.isEmpty) ? null : header;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] No challenge from $endpoint: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// Opens the sign-in inside the app: a Custom Tab on Android, a Safari
  /// sheet on iOS, a browser window on desktop. It can be closed again from
  /// here, which a separate browser app cannot.
  static Future<bool> _launch(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      // Desktop has no in-app browser view.
      return launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> _closeBrowser() async {
    // Only the in-app view can be closed, and only where one exists.
    if (launcher != null) return;
    try {
      await closeInAppWebView();
    } catch (_) {
      // Nothing was open, or the platform does not support it.
    }
  }

  /// The secret record inside one mirrored entry. A blob written by this
  /// build carries the whole record under `record`; one written before P5
  /// carries only the bearer under `token`, which still reads as a record
  /// with nothing to refresh with.
  static McpSecrets? _recordFromMirror(Map<Object?, Object?> entry) {
    final record = entry['record'];
    if (record is Map) {
      try {
        return McpSecrets.fromJson(Map<String, dynamic>.from(record));
      } catch (_) {
        // Fall through to the legacy field.
      }
    }
    final token = entry['token'];
    if (token is String && token.isNotEmpty) {
      return McpSecrets(tokens: McpTokens(accessToken: token));
    }
    return null;
  }

  // MERGE NOTE: upstream's _forgetLocal() is dropped — disconnect() above does
  // the same through McpStore, and _forgetLocal reached for _persist() and the
  // device-side secure store, neither of which exists in this structure. Its one
  // new behaviour, clearing the unreachable mark for a connection that is gone,
  // moved into disconnect().

  // ─── Credentials coming back from the host ─────────────────────────────

  /// Take an `mcp_credentials` frame from the host and update the stored
  /// records. Returns how many connectors were updated.
  ///
  /// The host mints its own access tokens from the refresh material this device
  /// handed it, and a provider that rotates refresh tokens kills the old one the
  /// moment it issues a new one — at which point the copy in this keychain is
  /// dead and only the host knows the live one. This frame is how it comes back,
  /// so the connector survives the next sign-in-less week. The frame shape is in
  /// docs/WIRE_CONTRACT.md.
  ///
  /// Only token fields are taken. The device stays the authority on who this
  /// connector is: a frame never creates a connection, never re-points a URL and
  /// never changes the registered client. Anything that does not line up is
  /// dropped in silence — a credentials frame has no user-facing failure, and a
  /// wrong one must not cost the user a working connector.
  ///
  /// The host re-sends a rotation on every task end and every reconnect until
  /// the app forwards the new token back, because there is no durable outbox on
  /// that side and a frame sent to a detached controller is dropped. So the same
  /// frame arrives many times and applying it must be idempotent: last one wins,
  /// and a frame that changes nothing writes nothing.
  static Future<int> applyRotatedCredentials(
    Map<String, dynamic> payload,
  ) async {
    final raw = payload['servers'];
    // One frame carries a list. A host that sends a single connector as the
    // frame itself is read the same way — the entry fields and the frame fields
    // are deliberately the same names.
    final entries = raw is List ? raw : <Object?>[payload];
    var applied = 0;
    for (final entry in entries) {
      if (entry is! Map) continue;
      if (await _applyOneCredential(Map<String, dynamic>.from(entry))) {
        applied++;
      }
    }
    if (applied > 0) {
      // The mirror holds the record too, so a reinstall must not come back with
      // a refresh token the provider has already killed. Pushed once for the
      // whole frame.
      unawaited(_pushRemote());
    }
    return applied;
  }

  /// Ids of connections whose server did not answer the last time it was
  /// asked.
  ///
  /// A connection is a stored token and a stored URL, not a live socket, so
  /// nothing notices when the server goes away: the list happily reports a
  /// server as connected long after it stopped answering. This is what the
  /// UI reads to say otherwise. It is a cache of the last check, never a
  /// claim about right now — a server absent here has not been checked, not
  /// been proven alive.
  static final ValueNotifier<Set<String>> unreachable =
      ValueNotifier<Set<String>>(<String>{});

  /// Ask the server whether it is still there.
  ///
  /// One `initialize` round trip, which is the cheapest thing an MCP server
  /// answers. The result lands in [unreachable] either way, so a check that
  /// succeeds also clears a stale failure.
  ///
  /// MERGE NOTE: upstream asked through its device-side McpClient. There is
  /// none here — the host is the transport — so the same `initialize` goes out
  /// as the one plain request [_challengeFor] already makes. Any HTTP answer,
  /// including 401, proves the server is there; only a dead socket or a
  /// timeout counts as away. Upstream's refreshTools() went with McpClient and
  /// has no caller left: the host discovers the tools and sends them back
  /// through [applyToolsFrame], which [probe] below asks for.
  static Future<bool> verifyReachable(String id) async {
    final connection = connectionFor(id);
    if (connection == null) return false;
    final endpoint = Uri.tryParse(connection.url);
    final bool alive = endpoint == null
        ? false
        : await _answersInitialize(endpoint);
    _recordReachable(id, alive);
    return alive;
  }

  /// Check every connection. Used when the connectors page opens, so the
  /// list the reader is looking at is about the servers as they are now.
  static Future<void> verifyAllReachable() async {
    await Future.wait(connections.value.map((c) => verifyReachable(c.id)));
  }

  static void _recordReachable(String id, bool alive) {
    final next = Set<String>.from(unreachable.value);
    final changed = alive ? next.remove(id) : next.add(id);
    if (changed) unreachable.value = next;
  }

  /// Whether [endpoint] answers an MCP `initialize` at all. The status does
  /// not matter — a server that says 401 is a server that is there.
  static Future<bool> _answersInitialize(Uri endpoint) async {
    final client = (probeClientFactory ?? http.Client.new)();
    try {
      await client
          .post(
            endpoint,
            headers: const <String, String>{
              'content-type': 'application/json',
              'accept': 'application/json, text/event-stream',
            },
            body: jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': <String, dynamic>{
                'protocolVersion': kMcpProtocolVersion,
                'capabilities': <String, dynamic>{},
                'clientInfo': <String, dynamic>{
                  'name': McpOAuth.clientName,
                  'version': '1',
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 10));
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] $endpoint did not answer: $e');
      return false;
    } finally {
      client.close();
    }
  }

  // ─── Asking the host to check them ────────────────────────────────────

  /// Ask the paired host to dial every stored connector now.
  ///
  /// This is what makes a connector the user just signed in to show its tools
  /// straight away instead of after the next task. The sign-in stays here (a
  /// consent screen needs a person); the dialling is the host's, always — it
  /// holds the network the connectors are reachable from and it is the side
  /// that will use them.
  ///
  /// Does nothing when no host is attached: an unpaired app has nobody to ask,
  /// and the list keeps saying "not checked" rather than inventing a zero.
  static Future<void> probe({McpProbeControl? control}) async {
    final McpProbeControl? target =
        control ??
        AgentsRelayLink.instance.controller.value as McpProbeControl?;
    if (target == null) return;
    try {
      final List<Map<String, dynamic>> payloads = await store.forwardPayloads();
      if (payloads.isEmpty) return;
      await target.probeMcpServers(payloads);
    } catch (_) {
      // A probe is a convenience. A relay that is down leaves the list as it
      // was; the next task reports the same thing anyway.
    }
  }

  // ─── What the connectors answered with ─────────────────────────────────

  /// Take an `mcp_tools` frame from the host and record what each connector
  /// offers. Returns how many connectors changed.
  ///
  /// This device never dials an MCP server — the host does, when a task runs —
  /// so the tool list is not something the app can discover. Without this frame
  /// the connector list could only say "0 tools" about a server that is
  /// connected and working, which is exactly what it said (bead cowork-mcp0).
  ///
  /// Matched on the device's own connector id when the host echoed one, else on
  /// the name. A server the device does not know is ignored: the frame reports,
  /// it never creates a connector.
  static Future<int> applyToolsFrame(Map<String, dynamic> payload) async {
    final Object? raw = payload['servers'];
    final List<Object?> entries = raw is List ? raw : <Object?>[payload];
    final List<McpConnection> stored = await store.load();
    var changed = 0;
    for (final Object? entry in entries) {
      if (entry is! Map) continue;
      final Map<String, dynamic> row = Map<String, dynamic>.from(entry);
      final String id = '${row['id'] ?? ''}';
      final String name = '${row['name'] ?? ''}';
      McpConnection? target;
      for (final McpConnection candidate in stored) {
        if (id.isNotEmpty && candidate.id == id) {
          target = candidate;
          break;
        }
        if (id.isEmpty && name.isNotEmpty && candidate.name == name) {
          target = candidate;
        }
      }
      if (target == null) continue;
      final Object? toolsRaw = row['tools'];
      final List<McpTool> tools = <McpTool>[
        if (toolsRaw is List)
          for (final Object? tool in toolsRaw)
            if (tool is Map) McpTool.fromJson(Map<String, dynamic>.from(tool)),
      ];
      final String error = '${row['error'] ?? ''}'.trim();
      final List<String> before = target.tools
          .map((McpTool tool) => tool.name)
          .toList();
      final List<String> after = tools
          .map((McpTool tool) => tool.name)
          .toList();
      final bool sameTools =
          before.length == after.length &&
          before.join('\u0000') == after.join('\u0000');
      final bool sameError = (target.lastError ?? '') == error;
      if (sameTools && sameError && target.checkedAt != null) continue;
      await store.upsert(
        target.copyWith(
          tools: tools,
          checkedAt: DateTime.now(),
          clearError: error.isEmpty,
          lastError: error.isEmpty ? null : error,
        ),
      );
      changed++;
    }
    if (changed > 0) connections.value = await store.load();
    return changed;
  }

  /// One connector out of an `mcp_credentials` frame. True when it was written.
  static Future<bool> _applyOneCredential(Map<String, dynamic> payload) async {
    try {
      final oauth = payload['oauth'];
      if (oauth is! Map) return false;
      final refreshToken = oauth['refresh_token']?.toString() ?? '';
      if (refreshToken.isEmpty) return false;

      final connection = await _connectionFromFrame(payload);
      if (connection == null || connection.auth != McpAuth.oauth) return false;

      final record = await store.secretsFor(connection.id);
      if (record == null) return false;

      // A client id that does not match means this frame belongs to a sign-in
      // that has since been replaced: the user signed in again, dynamic
      // registration issued a new client, and this rotation is against a
      // registration that no longer exists. Applying it would break the fresh
      // sign-in.
      final framedClient = oauth['client_id']?.toString() ?? '';
      final ourClient = record.credentials.clientId;
      if (framedClient.isNotEmpty &&
          ourClient.isNotEmpty &&
          framedClient != ourClient) {
        return false;
      }

      final accessToken = payload['access_token']?.toString() ?? '';
      final next = record.withTokens(
        McpTokens(
          accessToken: accessToken.isNotEmpty
              ? accessToken
              : record.tokens.accessToken,
          refreshToken: refreshToken,
          expiresAt: DateTime.tryParse(oauth['expires_at']?.toString() ?? ''),
          scope: record.tokens.scope,
        ),
      );
      // Nothing new: the host is re-sending a rotation this device already
      // took. Writing it again would churn the keychain and the mirror on every
      // task end until the next forward catches up.
      if (record.tokens.refreshToken == next.tokens.refreshToken &&
          record.tokens.accessToken == next.tokens.accessToken &&
          record.tokens.expiresAt == next.tokens.expiresAt) {
        return false;
      }
      await store.setSecrets(connection.id, next);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] Could not apply credentials: $e');
      return false;
    }
  }

  /// The connection an `mcp_credentials` frame is about, or null when this
  /// device has none. Matched on the connector id the host echoed back; a host
  /// that sent none (or an id this device does not know) falls back to the
  /// url-and-name pair the frame carries.
  static Future<McpConnection?> _connectionFromFrame(
    Map<String, dynamic> payload,
  ) async {
    final stored = await store.load();
    final id = payload['id']?.toString() ?? '';
    if (id.isNotEmpty) {
      for (final c in stored) {
        if (c.id == id) return c;
      }
    }
    final url = payload['url']?.toString() ?? '';
    final name = payload['name']?.toString() ?? '';
    if (url.isEmpty) return null;
    for (final c in stored) {
      if (c.url == url && (name.isEmpty || c.name == name)) return c;
    }
    return null;
  }

  // ─── Lookups ───────────────────────────────────────────────────────────

  static McpConnection? connectionFor(String id) {
    for (final connection in connections.value) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  /// https everywhere, except a server on this machine. A debug build may
  /// point at a loopback host; loopback never leaves the device.
  static bool _isAcceptableEndpoint(Uri endpoint) {
    if (endpoint.isScheme('https')) return true;
    if (!endpoint.isScheme('http')) return false;
    const loopback = {
      'localhost',
      '127.0.0.1',
      '::1',
      // The host machine, seen from the Android emulator.
      '10.0.2.2',
    };
    return loopback.contains(endpoint.host);
  }

  // ─── Calling a tool from the device (upstream) ─────────────────────────
  //
  // MERGE NOTE: kept from upstream because `lib/services/tool_executor.dart`
  // reaches it for every MCP tool a plain chat turn calls — the client tool
  // loop runs on the device there, while an Agents run has the host call the
  // same connector (McpStore.forwardPayloads). Both paths read the same stored
  // records, so a connector signed in here works for either. The client is
  // built from [store] rather than upstream's own secret helpers.

  /// The connection and the server-side tool name behind a registered tool.
  static ({McpConnection connection, String tool})? resolve(String toolName) {
    for (final connection in connections.value) {
      for (final tool in connection.tools) {
        if (connection.toolNameFor(tool.name) == toolName) {
          return (connection: connection, tool: tool.name);
        }
      }
    }
    return null;
  }

  /// Call [toolName] on the server that offers it, from this device.
  static Future<McpCallResult> call(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final target = resolve(toolName);
    if (target == null) {
      return const McpCallResult(
        text: 'That connector is no longer connected.',
        isError: true,
      );
    }

    final client = await _clientFor(target.connection);
    if (client == null) {
      return McpCallResult(
        text:
            '${target.connection.name} is not signed in any more. Open '
            'Connectors and connect it again.',
        isError: true,
      );
    }

    try {
      await client.initialize();
      return await client.callTool(target.tool, arguments);
    } on McpUnauthorized {
      return McpCallResult(
        text:
            '${target.connection.name} refused the token. Connect it again '
            'in Connectors.',
        isError: true,
      );
    } on McpException catch (e) {
      return McpCallResult(text: e.message, isError: true);
    }
  }

  /// A client for [connection], with whatever credential it needs. Null when
  /// the record cannot produce one — the caller then says so to the reader
  /// instead of calling with no token.
  static Future<McpClient?> _clientFor(McpConnection connection) async {
    final endpoint = Uri.tryParse(connection.url);
    if (endpoint == null) return null;

    if (connection.auth == McpAuth.appSession) {
      final token = await _appSessionToken();
      if (token == null) return null;
      return McpClient(endpoint: endpoint, accessToken: token);
    }

    if (connection.auth == McpAuth.apiKey) {
      final creds = await store.apiCredentialsFor(connection.id);
      if (creds.isEmpty) return null;
      return McpClient(endpoint: _endpointWithCredentials(endpoint, creds));
    }

    final secrets = await store.secretsFor(connection.id);
    if (secrets == null) {
      // A server that never asked for a token needs none now either.
      return McpClient(endpoint: endpoint);
    }

    var tokens = secrets.tokens;
    if (tokens.isExpired && tokens.refreshToken != null) {
      final server = secrets.authServer;
      if (server == null) return null;
      final refreshed = await (oauthFactory ?? McpOAuth.new)().refresh(
        server: server,
        credentials: secrets.credentials,
        refreshToken: tokens.refreshToken!,
        resource: McpOAuth.canonicalResource(endpoint),
        scope: secrets.scope,
      );
      if (refreshed == null) return null;
      tokens = refreshed;
      await store.setSecrets(connection.id, secrets.withTokens(refreshed));
      // The token rotated: mirror the new one so the other devices and the
      // host do not keep spending a dead one.
      unawaited(_pushRemote());
    }

    if (tokens.accessToken.isEmpty) return McpClient(endpoint: endpoint);
    return McpClient(endpoint: endpoint, accessToken: tokens.accessToken);
  }

  /// The account's own access token, for a server fronted by our API.
  static Future<String?> _appSessionToken() async {
    var session = SupabaseService.auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) {
      session = await SupabaseService.refreshSession();
    }
    final token = session?.accessToken ?? '';
    return token.isEmpty ? null : token;
  }

  static Uri _endpointWithCredentials(Uri base, Map<String, String> creds) =>
      base.replace(
        queryParameters: <String, String>{...base.queryParameters, ...creds},
      );

  /// The credentialed endpoint, exposed for tests: the reader's key must land
  /// on the request URL, and never in the stored connection row.
  @visibleForTesting
  static Uri endpointWithCredentialsForTest(
    Uri base,
    Map<String, String> creds,
  ) => _endpointWithCredentials(base, creds);
}
