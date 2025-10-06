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
  Session? _session = SupabaseService.auth.currentSession;
  bool _checkingSession = true;

  @override
  void initState() {
    super.initState();

    if (_session != null) {
      _checkingSession = false;
    } else {
      // Give Supabase time to recover a stored session before showing the sign-in form.
      Future<void>.delayed(const Duration(milliseconds: 600)).then((_) {
        if (!mounted) return;
        setState(() {
          _checkingSession = false;
        });
      });
    }

    _authSubscription = SupabaseService.auth.onAuthStateChange.listen((event) {
      if (!mounted) return;
      setState(() {
        _session = event.session;
        _checkingSession = false;
      });
    });
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
