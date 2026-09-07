import 'package:flutter/material.dart';

import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/encryption_service.dart';

/// Minimal email + password login. On success the [AuthGate] stream reacts
/// and swaps to the messenger shell, so this screen has nothing to do after
/// [AuthService.signInWithPassword] returns.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.auth = const AuthService()});

  /// The auth service used to sign in. Injectable so widget tests can supply
  /// a fake that fails without a real Supabase backend.
  final AuthService auth;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final password = _passwordController.text;
      await widget.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: password,
      );
      // Derive the per-user encryption key from the password, here, exactly as
      // chuk_chat does at its own sign-in (bd cowork-6v5). Everything that
      // stores user data encrypted — the system prompt and preferences, the
      // Supabase pairing mirror, the MCP connector mirror — needs this key, and
      // the password is the only moment it can be derived. Restoring a Supabase
      // session alone does not carry it, which is why those reads used to fail
      // with "Encryption key is not available for the current user".
      //
      // A failure here is reported instead of swallowed: the user would be
      // signed in with no key, which is the very bug this fixes.
      await EncryptionService.initializeForPassword(password);
    } on AuthServiceException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not unlock your encrypted data: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Chuk Chat',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        (value == null || !value.contains('@'))
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => (value == null || value.isEmpty)
                        ? 'Enter your password'
                        : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
