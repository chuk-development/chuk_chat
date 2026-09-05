/// Starts and stops chuk_chat's chat storage with the Supabase session.
///
/// chuk_chat does this inside `AppInitializationService` after its login flow.
/// CoWork has no such service: the session is restored by `AuthGate`, and a
/// thread is opened by the shell. So one listener on the auth stream does the
/// two things chuk_chat does — read the sidebar titles from the local cache
/// (instant, no network) and start the 30 s cloud poll — and undoes them on
/// sign-out. `main.dart` calls [CoworkChatStorageBootstrap.start] once.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/chat_sync_service.dart';
import 'package:cowork/services/local_chat_cache_service.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';
import 'package:cowork/services/supabase_service.dart';

class CoworkChatStorageBootstrap {
  CoworkChatStorageBootstrap._();

  static StreamSubscription<AuthState>? _sub;
  static String? _activeUserId;
  static Timer? _flushTimer;

  /// How often the cloud outbox is flushed while signed in. chuk_chat's
  /// `ChatSyncService` polls at the same interval, so a thread written while
  /// the key or the network was missing reaches the cloud within one tick.
  @visibleForTesting
  static Duration flushInterval = const Duration(seconds: 30);

  /// Test seam: what a flush does. Defaults to [CoworkChatStore.flushOutbox].
  @visibleForTesting
  static Future<void> Function()? flushHook;

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
  static void start() {
    if (_sub != null) return;
    final stream = authStream ?? _supabaseAuthStream();
    if (stream == null) return;
    _sub = stream.listen(
      _onAuthState,
      onError: (Object error) {
        if (kDebugMode) debugPrint('[cowork-chat-storage] auth error: $error');
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

  /// Flushes the cloud outbox now (on sign-in, and every [flushInterval]).
  static Future<void> flushNow() async {
    final hook = flushHook;
    if (hook != null) return hook();
    await CoworkChatStore.flushOutbox();
  }

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
        debugPrint('[cowork-chat-storage] sidebar load failed: $error');
      }
    }
    ChatSyncService.start();
    // Threads written while there was no key or no network: upload now and
    // on every tick from here on.
    _startFlushing();
    unawaited(
      LocalChatCacheService.ensureMigrated(userId).catchError((Object e) {
        if (kDebugMode) debugPrint('[cowork-chat-storage] migrate: $e');
      }),
    );
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
