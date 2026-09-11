import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:cowork/pages/login_page.dart';
import 'package:cowork/pages/messenger_shell.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/session_recovery.dart';
import 'package:cowork/services/settings/theme_controller.dart';
import 'package:cowork/services/supabase_service.dart';

/// The auth gate: swaps between the login screen and the messenger shell on
/// the Supabase session signal — with one exception (bead cowork-2n1).
///
/// A session that gotrue drops for an *expired* refresh token is not a
/// sign-out the user asked for: with a paired host the live pair is usually
/// sitting at the host, which rotated it while the app was away. So before
/// the login page is shown, [SessionRecovery] asks the host for that pair
/// (at startup for the session main() set aside, at runtime for a
/// `signedOut(sessionExpired)`), and only when nothing is left to recover
/// does the login page appear. A user-initiated sign-out still goes straight
/// to the login page.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    this.themeController,
    this.stash,
    this.authChanges,
    this.currentSession,
    this.recover,
    this.pairingStore,
    this.buildShell,
    this.buildLogin,
  });

  /// The app's theme controller, handed to the shell so its settings menu can
  /// edit the theme. Optional so a widget test can mount the gate alone.
  final ThemeController? themeController;

  /// The session main() set aside at startup. Null falls back to
  /// [SessionStash.pending].
  final SessionStash? stash;

  /// Auth event stream; null falls back to Supabase's. Injectable for tests.
  final Stream<AuthState>? authChanges;

  /// Current session reader; null falls back to Supabase's. For tests.
  final Session? Function()? currentSession;

  /// The recovery procedure; null runs [SessionRecovery] through the paired
  /// host. For tests.
  final Future<AccountSession?> Function(SessionStash stash)? recover;

  /// Where the stored pairing is read from for a recovery.
  final CoworkPairingStore? pairingStore;

  /// Builders for the two destinations, so a widget test can mount the gate
  /// without the real shell and login page.
  final WidgetBuilder? buildShell;
  final WidgetBuilder? buildLogin;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Session? _session;

  /// The last session we held: the pair a runtime recovery starts from.
  Session? _lastSession;

  bool _recovering = false;

  /// The stash the running recovery started from, when it names a user.
  ///
  /// A stashed session IS a signed-in user: the tokens are on disk, only the
  /// live pair has to be fetched back. So the shell mounts at once and the
  /// recovery runs behind it (bead cowork-91pn) — the thread the user was in
  /// paints from the local cache in the same frame, instead of sitting behind
  /// a spinner for up to twenty seconds. The wait screen is kept for the one
  /// case it is honest about: a recovery with no user to mount a shell for.
  SessionStash? _recoveringFrom;

  StreamSubscription<AuthState>? _sub;

  Session? _readCurrent() {
    final read = widget.currentSession;
    if (read != null) return read();
    return SupabaseService.isInitialized
        ? SupabaseService.auth.currentSession
        : null;
  }

  Stream<AuthState>? _changes() {
    final stream = widget.authChanges;
    if (stream != null) return stream;
    return SupabaseService.isInitialized
        ? SupabaseService.auth.onAuthStateChange
        : null;
  }

  @override
  void initState() {
    super.initState();
    _session = _readCurrent();
    _lastSession = _session;
    _sub = _changes()?.listen(_onAuth, onError: (Object _) {});
    final stash = widget.stash ?? SessionStash.pending;
    if (_session == null && stash != null) {
      _startRecovery(stash);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onAuth(AuthState state) {
    final session = state.session;
    if (session != null) _lastSession = session;

    if (state.event == AuthChangeEvent.signedOut &&
        state.signOutReason == SignOutReason.sessionExpired &&
        !_recovering) {
      final last = _lastSession;
      final refresh = last?.refreshToken ?? '';
      if (last != null && refresh.isNotEmpty) {
        _startRecovery(
          SessionStash(
            accessToken: last.accessToken,
            refreshToken: refresh,
            userId: last.user.id,
            expiresAt: last.expiresAt,
          ),
        );
        return;
      }
    }

    // While a recovery runs, the adoption's own `signedIn` is not the moment
    // to mount the shell: the recovery link is still attached to the host.
    if (_recovering) return;
    if (!mounted) return;
    setState(() => _session = session);
  }

  Future<AccountSession?> _recoverThroughHost(SessionStash stash) async {
    final store = widget.pairingStore ?? CoworkPairingStore();
    CoworkStoredPairing? pairing;
    try {
      pairing = await store.loadPairing();
    } catch (_) {
      pairing = null;
    }
    final link = pairing == null
        ? null
        : CoworkRelayRecoveryLink(store: store, pairing: pairing);
    return SessionRecovery(stash: stash, link: link).run();
  }

  Future<void> _startRecovery(SessionStash stash) async {
    if (_recovering) return;
    setState(() {
      _recovering = true;
      _recoveringFrom = stash.userId.isEmpty ? null : stash;
    });
    // The shell is mounted alongside this, so it must not race the recovery
    // for the device's one relay socket. It waits on this handle instead; see
    // [SessionRecovery.inFlight].
    final work = (widget.recover ?? _recoverThroughHost)(stash);
    SessionRecovery.inFlight = work.then<void>((_) {}, onError: (Object _) {});
    try {
      await work;
    } catch (_) {
      // Whatever happened, the session reader below has the last word.
    } finally {
      SessionRecovery.inFlight = null;
    }
    if (identical(SessionStash.pending, stash)) SessionStash.pending = null;
    await SessionStash.clearPersisted();
    if (!mounted) return;
    setState(() {
      _recovering = false;
      _recoveringFrom = null;
      _session = _readCurrent();
      _lastSession = _session ?? _lastSession;
    });
  }

  @override
  Widget build(BuildContext context) {
    // A recovery for a stashed user does not hold the shell back: everything
    // the shell needs on the first frame (the cached roster, the local
    // transcript) is on this device already, and the socket reconnects behind
    // it. Only a recovery with no user to show still waits.
    if (_recovering && _recoveringFrom == null) return const _RecoveringView();
    if (_session != null || _recoveringFrom != null) {
      final build = widget.buildShell;
      if (build != null) return build(context);
      return MessengerShell(themeController: widget.themeController);
    }
    final build = widget.buildLogin;
    if (build != null) return build(context);
    return const LoginPage();
  }
}

/// Shown while the host is asked for the live session: a quiet wait, not a
/// login form the user would fill in for nothing.
class _RecoveringView extends StatelessWidget {
  const _RecoveringView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(height: 16),
            Text('Reconnecting to your host…'),
          ],
        ),
      ),
    );
  }
}
