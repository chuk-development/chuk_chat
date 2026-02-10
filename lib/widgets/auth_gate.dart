import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/supabase_service.dart';

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
  late StreamSubscription<AuthState> _authSubscription;
  Session? _session;
  bool _checkingSession = true;

  @override
  void initState() {
    super.initState();

    // Check if Supabase is ready, otherwise wait a bit
    _initializeAuthState();
  }

  Future<void> _initializeAuthState() async {
    // Wait briefly for Supabase to initialize
    for (int i = 0; i < 20; i++) {
      try {
        final session = SupabaseService.auth.currentSession;
        _session = session;
        _checkingSession = session == null;

        _authSubscription = SupabaseService.auth.onAuthStateChange.listen((event) {
          if (!mounted) return;
          setState(() {
            _session = event.session;
            _checkingSession = false;
          });
        });

        if (mounted) {
          setState(() {
            if (_session != null) {
              _checkingSession = false;
            }
          });
        }

        // Show UI after brief delay even if no session
        if (_session == null && mounted) {
          await Future.delayed(const Duration(milliseconds: 50));
          if (mounted) {
            setState(() {
              _checkingSession = false;
            });
          }
        }
        return;
      } catch (_) {
        // Supabase not ready yet
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    // Timeout - show UI anyway
    if (mounted) {
      setState(() {
        _checkingSession = false;
      });
    }
  }

  @override
  void dispose() {
    _authSubscription.cancel();
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
