import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';

import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/encryption_service.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/shapes.dart';
import 'package:cowork/ui/expressive/staggered.dart';

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
  bool _obscurePassword = true;
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
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
                  // The mark, then the wordmark. The blob is the same
                  // [CookieShape] a coworker's face is cut from, so the first
                  // screen already speaks the language the rest of the app
                  // speaks.
                  StaggeredItem(
                    index: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: ShapeDecoration(
                            color: cs.primaryContainer,
                            shape: const CookieShape(lobes: 7, softness: 0.13),
                          ),
                          child: AppIcon(
                            Icons.forum_rounded,
                            size: 44,
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Chuk Chat',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  StaggeredItem(
                    index: 1,
                    child: TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (value) =>
                          (value == null || !value.contains('@'))
                          ? 'Enter a valid email'
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  StaggeredItem(
                    index: 2,
                    child: TextFormField(
                      key: const ValueKey('login-password-field'),
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          key: const ValueKey(
                            'login-password-visibility-toggle',
                          ),
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          icon: AppIcon(
                            _obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                        ),
                      ),
                      validator: (value) => (value == null || value.isEmpty)
                          ? 'Enter your password'
                          : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // The error rides with the button rather than sitting
                  // between the fields: the child count of the form stays
                  // constant, so an error does not restart the cascade.
                  StaggeredItem(
                    index: 3,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_error != null) ...[
                          Text(
                            _error!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.error,
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? ExpressiveLoader(size: 20, color: cs.onSurface)
                              : const Text('Sign in'),
                        ),
                      ],
                    ),
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
