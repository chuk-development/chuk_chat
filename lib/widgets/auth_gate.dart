import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/app_initialization_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Switches between [signedInBuilder] and [signedOutBuilder] based on
/// the current Supabase auth session.
///
/// Auth state changes are handled exclusively by [SessionManagerService]
/// (business logic) and this widget (UI switching). There is no duplicate
/// subscription — each listener has a distinct responsibility.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.signedInBuilder,
    required this.signedOutBuilder,
    this.loadingBuilder,
    this.passwordRecoveryBuilder,
  });

  final WidgetBuilder signedInBuilder;
  final WidgetBuilder signedOutBuilder;
  final WidgetBuilder? loadingBuilder;

  /// Builder shown when the user arrives via a password reset link.
  /// If null, the signed-in builder is shown instead.
  final WidgetBuilder? passwordRecoveryBuilder;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;
  bool _checkingSession = true;
  bool _isPasswordRecovery = false;

  @override
  void initState() {
    super.initState();
    _initializeAuthState();
  }

  Future<void> _initializeAuthState() async {
    // Supabase initialization runs in the background (unawaited in main).
    // Wait for it before accessing auth to avoid StateError.
    final ready = await AppInitializationService.instance.waitForSupabase();
    if (!mounted) return;

    if (!ready) {
      // Supabase failed to initialize — show signed-out UI.
      setState(() => _checkingSession = false);
      return;
    }

    _session = SupabaseService.auth.currentSession;

    // Listen for future auth changes (sign-in, sign-out, token refresh).
    _authSubscription = SupabaseService.auth.onAuthStateChange.listen((event) {
      if (!mounted) return;
      setState(() {
        _session = event.session;
        _checkingSession = false;
        _isPasswordRecovery = event.event == AuthChangeEvent.passwordRecovery;
      });
    });

    if (mounted) {
      setState(() {
        _checkingSession = false;
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) {
      return widget.loadingBuilder?.call(context) ??
          const Center(child: CircularProgressIndicator());
    }

    if (_session != null) {
      if (_isPasswordRecovery && widget.passwordRecoveryBuilder != null) {
        return widget.passwordRecoveryBuilder!(context);
      }
      return widget.signedInBuilder(context);
    }

    return widget.signedOutBuilder(context);
  }
}
