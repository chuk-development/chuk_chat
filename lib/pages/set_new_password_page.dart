import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/key_version_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/input_validator.dart';
import 'package:chuk_chat/widgets/password_strength_meter.dart';

/// Page shown after a user clicks a password reset link.
/// Lets them set a new password and initializes a new encryption key.
class SetNewPasswordPage extends StatefulWidget {
  const SetNewPasswordPage({super.key, this.onComplete});

  /// Called after the password has been successfully changed and encryption
  /// keys rotated. The parent widget should transition to the signed-in view.
  final VoidCallback? onComplete;

  @override
  State<SetNewPasswordPage> createState() => _SetNewPasswordPageState();
}

class _SetNewPasswordPageState extends State<SetNewPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _isSubmitting = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String _currentPassword = '';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _passwordCtrl.addListener(() {
      setState(() => _currentPassword = _passwordCtrl.text);
    });
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSetPassword() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final newPassword = _passwordCtrl.text.trim();

      // 1. Update the Supabase auth password
      await SupabaseService.auth.updateUser(
        UserAttributes(password: newPassword),
      );

      // 2. Get the current user (now authenticated via reset link)
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        throw StateError('No authenticated user after password update.');
      }

      // 3. Preserve old encryption key metadata before creating new key
      final oldSalt = user.userMetadata?['chat_kdf_salt'] as String?;
      if (oldSalt != null && oldSalt.isNotEmpty) {
        // User had encryption set up before — save old key info
        await KeyVersionService.promoteCurrentToPrevious(user);
      }

      // 4. Generate new encryption key with new password
      await EncryptionService.initializeForPasswordReset(newPassword);

      // 5. Bump password revision to invalidate other sessions
      // Re-fetch user since metadata may have changed
      final updatedUser = SupabaseService.auth.currentUser ?? user;
      await PasswordRevisionService.bumpRevision(updatedUser);

      if (!mounted) return;

      // 6. Transition to signed-in view
      widget.onComplete?.call();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error setting new password: $e');
      }
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to set new password. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
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
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.lock_reset,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Set a new password',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: iconFg,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Choose a strong password for your account. '
                      'Your old chats will remain accessible if you '
                      'remember your previous password.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: iconFg.withValues(alpha: 0.6),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _passwordCtrl,
                      decoration: InputDecoration(
                        labelText: 'New password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () {
                            setState(
                              () => _obscurePassword = !_obscurePassword,
                            );
                          },
                        ),
                      ),
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.next,
                      validator: (value) =>
                          InputValidator.validatePassword(value),
                    ),
                    if (_currentPassword.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      PasswordStrengthMeter(password: _currentPassword),
                    ],
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _confirmCtrl,
                      decoration: InputDecoration(
                        labelText: 'Confirm new password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () {
                            setState(
                              () => _obscureConfirm = !_obscureConfirm,
                            );
                          },
                        ),
                      ),
                      obscureText: _obscureConfirm,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (!_isSubmitting) _handleSetPassword();
                      },
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please confirm your password.';
                        }
                        if (value.trim() != _passwordCtrl.text.trim()) {
                          return 'Passwords do not match.';
                        }
                        return null;
                      },
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
                        onPressed: _isSubmitting ? null : _handleSetPassword,
                        child: _isSubmitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Set new password'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
