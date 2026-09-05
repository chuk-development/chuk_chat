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
    setState(() => _recovering = true);
    try {
      await (widget.recover ?? _recoverThroughHost)(stash);
    } catch (_) {
      // Whatever happened, the session reader below has the last word.
    }
    if (identical(SessionStash.pending, stash)) SessionStash.pending = null;
    await SessionStash.clearPersisted();
    if (!mounted) return;
    setState(() {
      _recovering = false;
      _session = _readCurrent();
      _lastSession = _session ?? _lastSession;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_recovering) return const _RecoveringView();
    if (_session != null) {
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
