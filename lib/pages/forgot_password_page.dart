import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/otp_verification_page.dart';
import 'package:chuk_chat/pages/set_new_password_page.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/input_validator.dart';

/// Page for requesting a password reset code, then verifying it and setting
/// a new password.
///
/// Flow: enter email → Supabase emails a 6-digit recovery code → enter the
/// code ([OtpVerificationPage]) → set a new password ([SetNewPasswordPage]).
/// No magic link is involved, so the flow works identically on web, desktop
/// and mobile.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final AuthService _authService = const AuthService();
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSendResetCode() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final email = _emailCtrl.text.trim();
    try {
      await SupabaseService.auth.resetPasswordForEmail(email);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to send reset code. Please try again.';
        _isSubmitting = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    await _openRecoveryOtpVerification(email);
  }

  /// Pushes the OTP code-entry page. On a valid code the user holds a
  /// recovery session; we then replace the OTP page with the
  /// set-new-password page. Once the new password is set and the encryption
  /// key rotated, we pop back to the app root (the AuthGate is already in its
  /// signed-in state underneath these routes).
  Future<void> _openRecoveryOtpVerification(String email) async {
    final navigator = Navigator.of(context);
    final l = AppLocalizations.of(context)!;

    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => OtpVerificationPage(
          email: email,
          body: l.verifyRecoveryBody(email),
          onSubmit: (code) async {
            await _authService.verifyRecoveryOtp(email: email, token: code);
            if (!navigator.mounted) return;
            // Replace the OTP page with the set-new-password page. Not awaited:
            // pushReplacement's Future only completes when that page is popped.
            unawaited(
              navigator.pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => SetNewPasswordPage(
                    onComplete: () {
                      // Pop every pushed route to reveal the signed-in shell.
                      navigator.popUntil((route) => route.isFirst);
                    },
                  ),
                ),
              ),
            );
          },
          onResend: () => SupabaseService.auth.resetPasswordForEmail(email),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final iconFg = theme.iconTheme.color ?? Colors.white;

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Card(
            color: scaffoldBg.lighten(0.05),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: iconFg.withValues(alpha: 0.2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _buildFormView(theme, iconFg),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFormView(ThemeData theme, Color iconFg) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Reset your password',
            style: theme.textTheme.headlineSmall?.copyWith(color: iconFg),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your email address and we\'ll send you a 6-digit code to '
            'reset your password.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: iconFg.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'After resetting your password, your old chats will still be '
            'available but locked. You can unlock them by entering your '
            'old password in Settings.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: iconFg.withValues(alpha: 0.5),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _emailCtrl,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'you@example.com',
            ),
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) {
              if (!_isSubmitting) _handleSendResetCode();
            },
            validator: (value) => InputValidator.validateEmail(value),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.redAccent,
              ),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _handleSendResetCode,
              child: _isSubmitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send reset code'),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Back to sign in'),
          ),
        ],
      ),
    );
  }
}
