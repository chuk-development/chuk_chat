/// Starts and stops chuk_chat's chat storage with the Supabase session.
///
/// chuk_chat does this inside `AppInitializationService` after its login flow.
/// Agents has no such service: the session is restored by `AuthGate`, and a
/// thread is opened by the shell. So one listener on the auth stream does the
/// two things chuk_chat does — read the sidebar titles from the local cache
/// (instant, no network) and start the 30 s cloud poll — and undoes them on
/// sign-out. `main.dart` calls [AgentsChatStorageBootstrap.start] once.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_cache_migration.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class AgentsChatStorageBootstrap {
  AgentsChatStorageBootstrap._();

  static StreamSubscription<AuthState>? _sub;
  static String? _activeUserId;
  static Timer? _flushTimer;

  /// How often the cloud outbox is flushed while signed in. chuk_chat's
  /// `ChatSyncService` polls at the same interval, so a thread written while
  /// the key or the network was missing reaches the cloud within one tick.
  @visibleForTesting
  static Duration flushInterval = const Duration(seconds: 30);

  /// Test seam: what a tick does. Defaults to [AgentsChatStore.flushOutbox]
  /// followed by [AgentsChatStore.pullFromCloud].
  @visibleForTesting
  static Future<void> Function()? flushHook;

  /// Test seam: the one-time repairs at sign-in. Defaults to
  /// [AgentsChatCacheMigration.migrateJsonCache] + [dropOrphanCursors].
  @visibleForTesting
  static Future<void> Function(String userId)? migrationHook;

  /// Test seam: the auth events to follow. Defaults to Supabase's stream.
  @visibleForTesting
  static Stream<AuthState>? authStream;

  /// Test seam: who is signed in right now. Defaults to Supabase's session.
  @visibleForTesting
  static String? Function()? currentUserId;

  /// Test seams for the two side effects.
  @visibleForTesting
  static Future<void> Function()? onSignedInHook;
  @visibleForTesting
  static Future<void> Function()? onSignedOutHook;

  /// Idempotent. Safe to call before Supabase is initialised: it then does
  /// nothing until [start] is called again.
  ///
  /// A no-op with FEATURE_AGENTS off: upstream's `SessionManager` /
  /// `AppInitializationService` already load the chats and run the sync, and
  /// nothing Agents-only (outbox flush, cache migration, the remembered read
  /// key) may run in that build.
  static void start() {
    if (!ChatOrigin.agentsEnabled) return;
    if (_sub != null) return;
    final stream = authStream ?? _supabaseAuthStream();
    if (stream == null) return;
    _sub = stream.listen(
      _onAuthState,
      onError: (Object error) {
        if (kDebugMode) debugPrint('[agents-chat-storage] auth error: $error');
      },
    );
    // The stream replays the initial session on subscribe on real Supabase;
    // a session that is already there is handled here as well so a late
    // start (or a test stream that does not replay) still boots.
    final userId = _userId();
    if (userId != null) unawaited(_signedIn(userId));
  }

  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _stopFlushing();
    _activeUserId = null;
  }

  /// Flushes the cloud outbox now (on sign-in, and every [flushInterval]),
  /// then pulls every Agents thread whose `cowork_chats` row is newer than
  /// this device's copy. chuk_chat's `ChatSyncService` polls
  /// `encrypted_chats` only; this is the same poll for the Agents table.
  static Future<void> flushNow() async {
    final hook = flushHook;
    if (hook != null) return hook();
    // One tick at a time: a slow pull must not be overlapped by the next
    // tick, which would fetch and decrypt the same rows again.
    final running = _inFlight;
    if (running != null) return running;
    final run = () async {
      await AgentsChatStore.flushOutbox();
      await AgentsChatStore.pullFromCloud();
    }();
    _inFlight = run;
    try {
      await run;
    } finally {
      if (identical(_inFlight, run)) _inFlight = null;
    }
  }

  static Future<void>? _inFlight;

  static void _startFlushing() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(flushInterval, (_) => unawaited(flushNow()));
    unawaited(flushNow());
  }

  static void _stopFlushing() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  @visibleForTesting
  static Future<void> reset() async {
    await stop();
    authStream = null;
    currentUserId = null;
    onSignedInHook = null;
    onSignedOutHook = null;
    flushHook = null;
    migrationHook = null;
    flushInterval = const Duration(seconds: 30);
  }

  @visibleForTesting
  static String? get activeUserId => _activeUserId;

  // ---------------------------------------------------------------------------

  static Future<void> _onAuthState(AuthState state) async {
    switch (state.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.userUpdated:
        final userId = state.session?.user.id ?? _userId();
        if (userId == null) {
          await _signedOut();
        } else {
          await _signedIn(userId);
        }
      case AuthChangeEvent.signedOut:
        await _signedOut();
      case AuthChangeEvent.tokenRefreshed:
      case AuthChangeEvent.passwordRecovery:
      case AuthChangeEvent.mfaChallengeVerified:
        // Same user, same stores. Nothing to do.
        break;
      // ignore: deprecated_member_use
      case AuthChangeEvent.userDeleted:
        await _signedOut();
    }
  }

  static Future<void> _signedIn(String userId) async {
    if (_activeUserId == userId) return;
    if (_activeUserId != null) await _signedOut();
    _activeUserId = userId;
    // The read key for the NEXT cold start (bead cowork-91pn). The local cache
    // is keyed by user id, and on a cold start the app paints long before
    // gotrue has restored the session — without this the rows are on disk and
    // unreadable, and the thread the user was in comes up empty.
    unawaited(AgentsChatStore.rememberUser(userId));
    final hook = onSignedInHook;
    if (hook != null) {
      await hook();
      _startFlushing();
      return;
    }
    try {
      // Titles from the local cache first (instant), then the cloud poll.
      // This is the chuk_chat order (`_loadUserData` → `_startSyncAfterKey`).
      await ChatStorageService.loadSavedChatsForSidebar();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-chat-storage] sidebar load failed: $error');
      }
    }
    // Before the sync and before any thread opens: bring the P2b JSON files
    // into SQLite and drop cursors that point past a transcript this device
    // no longer holds (bead cowork-izh). Both never throw.
    await _repair(userId);
    ChatSyncService.start();
    // Threads written while there was no key or no network: upload now and
    // on every tick from here on.
    _startFlushing();
    unawaited(
      LocalChatCacheService.ensureMigrated(userId).catchError((Object e) {
        if (kDebugMode) debugPrint('[agents-chat-storage] migrate: $e');
      }),
    );
  }

  static Future<void> _repair(String userId) async {
    final hook = migrationHook;
    if (hook != null) return hook(userId);
    await AgentsChatCacheMigration.migrateJsonCache(userId);
    await AgentsChatCacheMigration.dropOrphanCursors(userId);
  }

  static Future<void> _signedOut() async {
    if (_activeUserId == null) return;
    _activeUserId = null;
    _stopFlushing();
    final hook = onSignedOutHook;
    if (hook != null) {
      await hook();
      return;
    }
    ChatSyncService.stop();
    await ChatStorageService.reset();
  }

  static String? _userId() {
    if (currentUserId != null) return currentUserId!();
    if (!SupabaseService.isInitialized) return null;
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static Stream<AuthState>? _supabaseAuthStream() {
    if (!SupabaseService.isInitialized) return null;
    try {
      return SupabaseService.auth.onAuthStateChange;
    } catch (_) {
      return null;
    }
  }
}
