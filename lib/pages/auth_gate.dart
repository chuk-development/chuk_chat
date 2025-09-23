// lib/pages/auth_gate.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/stripe_billing_service.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({required this.child, super.key});

  final Widget child;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  bool _otpRequested = false;
  bool _isLoading = false;
  String? _error;
  String? _lastUserId;
  Future<void>? _postLoginFuture;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _ensurePostLoginSetup(Session session) {
    final userId = session.user.id;
    if (_postLoginFuture != null && _lastUserId == userId) {
      return _postLoginFuture!;
    }

    _lastUserId = userId;
    _postLoginFuture = Future.wait([
      ChatStorageService.loadChats(),
      StripeBillingService.instance.refreshSubscriptionStatus(),
    ]);
    return _postLoginFuture!;
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Please enter your email address.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await AuthService.sendEmailOtp(email);
      setState(() {
        _otpRequested = true;
      });
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _verifyOtp() async {
    final email = _emailController.text.trim();
    final otp = _otpController.text.trim();
    if (email.isEmpty || otp.isEmpty) {
      setState(() => _error = 'Enter both email and the code you received.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await AuthService.verifyEmailOtp(email: email, token: otp);
      _otpController.clear();
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildAuthForm(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            color: theme.cardColor,
            elevation: 6,
            margin: const EdgeInsets.all(24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Sign in', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(
                    'We use passwordless email logins. Enter your email to receive a secure one-time code.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                    enabled: !_isLoading,
                  ),
                  if (_otpRequested) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'One-time code'),
                      enabled: !_isLoading,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _isLoading
                        ? null
                        : _otpRequested
                            ? _verifyOtp
                            : _sendOtp,
                    child: Text(_otpRequested ? 'Verify code' : 'Send login code'),
                  ),
                  if (_otpRequested)
                    TextButton(
                      onPressed: _isLoading ? null : _sendOtp,
                      child: const Text('Resend code'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: AuthService.authStateChanges,
      builder: (context, snapshot) {
        final session = snapshot.data?.session ?? Supabase.instance.client.auth.currentSession;
        if (session != null) {
          return FutureBuilder<void>(
            future: _ensurePostLoginSetup(session),
            builder: (context, futureSnapshot) {
              if (futureSnapshot.connectionState != ConnectionState.done) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              return widget.child;
            },
          );
        }
        return _buildAuthForm(context);
      },
    );
  }
}
