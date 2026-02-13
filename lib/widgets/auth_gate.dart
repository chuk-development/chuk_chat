import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  });

  final WidgetBuilder signedInBuilder;
  final WidgetBuilder signedOutBuilder;
  final WidgetBuilder? loadingBuilder;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;
  bool _checkingSession = true;

  @override
  void initState() {
    super.initState();
    _initializeAuthState();
  }

  void _initializeAuthState() {
    // Read current session synchronously. Supabase is guaranteed to be
    // initialized by the time AuthGate builds because main.dart calls
    // waitForSupabase() before the first frame that renders this widget.
    try {
      _session = SupabaseService.auth.currentSession;
    } catch (e) {
      // Supabase not yet ready — will rely on onAuthStateChange stream below.
      if (kDebugMode) {
        debugPrint('AuthGate: Could not read initial session: $e');
      }
    }

    // Listen for future auth changes (sign-in, sign-out, token refresh).
    _authSubscription = SupabaseService.auth.onAuthStateChange.listen((event) {
      if (!mounted) return;
      setState(() {
        _session = event.session;
        _checkingSession = false;
      });
    });

    // Show UI immediately — no artificial delay needed.
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
      return widget.signedInBuilder(context);
    }

    return widget.signedOutBuilder(context);
  }
}
