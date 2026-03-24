import 'package:flutter/material.dart';

import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/input_validator.dart';

/// Page for requesting a password reset email.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  bool _isSubmitting = false;
  bool _emailSent = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSendResetLink() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final email = _emailCtrl.text.trim();
      await SupabaseService.auth.resetPasswordForEmail(
        email,
        redirectTo: 'https://chat.chuk.chat/reset-callback',
      );

      if (!mounted) return;
      setState(() {
        _emailSent = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to send reset email. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
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
              child: _emailSent ? _buildSuccessView(theme, iconFg) : _buildFormView(theme, iconFg),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuccessView(ThemeData theme, Color iconFg) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.mark_email_read_outlined,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Check your email',
          style: theme.textTheme.headlineSmall?.copyWith(color: iconFg),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'We sent a password reset link to ${_emailCtrl.text.trim()}. '
          'Open the link in your email to set a new password.',
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to sign in'),
        ),
      ],
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
            'Enter your email address and we\'ll send you a link to reset your password.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: iconFg.withValues(alpha: 0.7),
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
              if (!_isSubmitting) _handleSendResetLink();
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
              onPressed: _isSubmitting ? null : _handleSendResetLink,
              child: _isSubmitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send reset link'),
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
