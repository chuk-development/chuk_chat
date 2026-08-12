import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:cowork/pages/login_page.dart';
import 'package:cowork/pages/messenger_shell.dart';
import 'package:cowork/services/supabase_service.dart';

/// Minimal auth gate. Watches Supabase auth state and swaps between the
/// login screen and the messenger shell. No local cache, no bootstrap —
/// just the session signal.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: SupabaseService.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session =
            snapshot.data?.session ?? SupabaseService.auth.currentSession;
        if (session != null) {
          return const MessengerShell();
        }
        return const LoginPage();
      },
    );
  }
}
