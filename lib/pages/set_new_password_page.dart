import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/key_version_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/utils/client_platform.dart';
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
    final l = AppLocalizations.of(context)!;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final newPassword = _passwordCtrl.text.trim();

      // 1. Update the Supabase auth password. Stamp the client platform into
      // user_metadata so the "password changed" notification email can show
      // where the change originated.
      await SupabaseService.auth.updateUser(
        UserAttributes(
          password: newPassword,
          data: {'pw_change_client': clientPlatformName()},
        ),
      );

      // 2. Get the current user (now authenticated via reset link)
      final user = SupabaseService.auth.currentUser;
      if (user == null) {
        throw StateError(l.noAuthenticatedUser);
      }

      // 3. Preserve old encryption key metadata before creating new key
      final oldSalt = user.userMetadata?['chat_kdf_salt'] as String?;
      if (oldSalt != null && oldSalt.isNotEmpty) {
        // User had encryption set up before — save old key info.
        // This MUST succeed or old chats become unrecoverable.
        final promoted = await KeyVersionService.promoteCurrentToPrevious(user);
        if (promoted == null) {
          throw StateError(l.failedToPreserveEncryption);
        }
      }

      // 4. Generate new encryption key with new password
      await EncryptionService.initializeForPasswordReset(newPassword);

      // 5. Bump password revision to invalidate other sessions
      // Re-fetch user since metadata may have changed
      final updatedUser = SupabaseService.auth.currentUser ?? user;
      await PasswordRevisionService.bumpRevision(updatedUser);

      // 6. Web: clear the local plaintext cache so old-key chats reload from
      // the server and surface as locked (recoverable with the old password).
      // Native keeps the cache so the user retains access on their own device.
      if (kIsWeb) {
        await LocalChatCacheService.clear(updatedUser.id);
      }

      if (!mounted) return;

      // 6. Transition to signed-in view
      widget.onComplete?.call();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error setting new password: $e');
      }
      if (!mounted) return;
      setState(() {
        _errorMessage = l.failedToSetNewPassword;
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
    final l = AppLocalizations.of(context)!;

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
                      l.setNewPassword,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: iconFg,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.setNewPasswordInfo,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: iconFg.withValues(alpha: 0.6),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _passwordCtrl,
                      decoration: InputDecoration(
                        labelText: l.newPassword,
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
                        labelText: l.confirmNewPassword,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () {
                            setState(() => _obscureConfirm = !_obscureConfirm);
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
                          return l.pleaseConfirmPassword;
                        }
                        if (value.trim() != _passwordCtrl.text.trim()) {
                          return l.passwordsDoNotMatch;
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
                            : Text(l.setNewPasswordButton),
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
