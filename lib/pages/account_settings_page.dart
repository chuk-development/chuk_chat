import 'package:flutter/material.dart';

import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/supabase_service.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// The account surface: who is signed in, and the way out.
///
/// The email and id come straight from the live Supabase session. Sign-out
/// runs the same [AuthService] the shell's app-bar button does; the auth gate
/// takes the app back to the login screen when the session clears.
class AccountSettingsPage extends StatelessWidget {
  const AccountSettingsPage({super.key, this.onSignOut});

  /// Injectable sign-out, so a test can prove the button without Supabase.
  /// Defaults to the real [AuthService].
  final Future<void> Function()? onSignOut;

  @override
  Widget build(BuildContext context) {
    final user = SupabaseService.isInitialized
        ? SupabaseService.auth.currentUser
        : null;
    final email = user?.email ?? 'Signed in';
    final userId = user?.id ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const ExpressiveTitle('Account', subtitle: 'Your CoWork identity'),
          const ExpressiveSectionHeader('Signed in as'),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.person_outline,
                title: email,
                subtitle: userId.isEmpty ? null : userId,
              ),
            ],
          ),
          const ExpressiveSectionHeader('Session'),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.logout,
                title: 'Sign out',
                subtitle: 'End this session on this device',
                tone: Theme.of(context).colorScheme.errorContainer,
                onTap: () async {
                  final navigator = Navigator.of(context);
                  if (onSignOut != null) {
                    await onSignOut!();
                  } else {
                    await const AuthService().signOut();
                  }
                  navigator.pop();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
