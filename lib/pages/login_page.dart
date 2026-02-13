import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/session_tracking_service.dart';
import 'package:chuk_chat/supabase_config.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/input_validator.dart';
import 'package:chuk_chat/widgets/password_strength_meter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();

  final AuthService _authService = const AuthService();

  bool _isSubmitting = false;
  bool _isSignInMode = true;
  bool _obscurePassword = true;
  bool _agreedToTerms = false;
  bool _confirmedAge = false;
  String? _errorMessage;
  String _currentPassword = '';
  bool _wasRemotelySignedOut = false;

  @override
  void initState() {
    super.initState();
    // Listen to password changes for strength meter
    _passwordCtrl.addListener(() {
      setState(() {
        _currentPassword = _passwordCtrl.text;
      });
    });
    _checkRemoteSignOut();
  }

  Future<void> _checkRemoteSignOut() async {
    final wasRemote = await SessionTrackingService.wasRemotelySignedOut();
    if (wasRemote && mounted) {
      setState(() => _wasRemotelySignedOut = true);
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _displayNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Check if user agreed to terms when signing up
    if (!_isSignInMode && !_agreedToTerms) {
      setState(() {
        _errorMessage = 'You must agree to the Terms of Service and Privacy Policy to create an account.';
      });
      return;
    }

    // Check if user confirmed minimum age when signing up
    if (!_isSignInMode && !_confirmedAge) {
      setState(() {
        _errorMessage = 'You must be at least 16 years old to use this service.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final email = _emailCtrl.text.trim();
      final password = _passwordCtrl.text.trim();

      if (_isSignInMode) {
        await _authService.signInWithPassword(email: email, password: password);
        await EncryptionService.initializeForPassword(password);
        try {
          await ChatStorageService.loadSavedChatsForSidebar();
          ChatStorageService.selectedChatIndex = -1;
        } catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Could not sync chats: $error',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 2),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
      } else {
        final displayName = _displayNameCtrl.text.trim();
        await _authService.signUpWithPassword(
          email: email,
          password: password,
          displayName: displayName.isEmpty ? null : displayName,
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Check your email inbox to confirm the account.',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 2),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
        setState(() {
          _isSignInMode = true;
        });
      }
    } on AuthServiceException catch (error) {
      final bool isEmailAlreadyRegistered =
          !_isSignInMode &&
          error.code == AuthServiceException.codeEmailAlreadyRegistered;
      if (isEmailAlreadyRegistered && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              error.message,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 2),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
      }
      setState(() {
        if (isEmailAlreadyRegistered) {
          _isSignInMode = true;
        }
        _errorMessage = error.message;
      });
    } on StateError catch (error) {
      setState(() {
        _errorMessage = error.message;
      });
    } catch (error) {
      setState(() {
        _errorMessage = 'Unexpected error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _toggleMode() {
    setState(() {
      _isSignInMode = !_isSignInMode;
      _errorMessage = null;
      _agreedToTerms = false; // Reset checkbox when switching modes
      _confirmedAge = false;
    });
  }

  String? _validatePassword(String? value) {
    // For sign-in mode, allow any password (backend will validate)
    // For sign-up mode, enforce strong password requirements
    if (value == null || value.isEmpty) {
      return 'Enter your password.';
    }

    if (!_isSignInMode) {
      // Enforce strong password for sign-up
      return InputValidator.validatePassword(value);
    }

    // For sign-in, just check it's not empty (already done above)
    return null;
  }

  Future<void> _launchUrl(String url) async {
    final Uri uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (kDebugMode) {
        debugPrint('Could not launch $url');
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
                    Text(
                      'Welcome to Chuk Chat',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: iconFg,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isSignInMode
                          ? 'Sign in with your email'
                          : 'Create an account with email & password',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: iconFg.withValues(alpha: 0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (_wasRemotelySignedOut) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline,
                                size: 18,
                                color: Colors.orange.shade200),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'You were signed out from another device.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.orange.shade200,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (SupabaseConfig.isUsingPlaceholderValues) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          'Supabase credentials are not configured. Update them before running a production build.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.orange.shade200,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (!_isSignInMode) ...[
                      TextFormField(
                        controller: _displayNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          hintText: 'How other people will see you',
                        ),
                        textCapitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 16),
                    ],
                    Semantics(
                      identifier: 'login_email_field',
                      child: TextFormField(
                        controller: _emailCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          hintText: 'you@example.com',
                        ),
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        validator: (value) {
                          return InputValidator.validateEmail(value);
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      identifier: 'login_password_field',
                      child: TextFormField(
                        controller: _passwordCtrl,
                        decoration: InputDecoration(
                          labelText: 'Password',
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
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (!_isSubmitting) {
                            _handleSubmit();
                          }
                        },
                        validator: _validatePassword,
                      ),
                    ),
                    // Show password strength meter only in sign-up mode
                    if (!_isSignInMode && _currentPassword.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      PasswordStrengthMeter(password: _currentPassword),
                    ],
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                    if (!_isSignInMode) ...[
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _agreedToTerms,
                            onChanged: (bool? value) {
                              setState(() {
                                _agreedToTerms = value ?? false;
                              });
                            },
                            activeColor: theme.colorScheme.primary,
                            fillColor: WidgetStateProperty.resolveWith<Color>((states) {
                              if (states.contains(WidgetState.selected)) {
                                return theme.colorScheme.primary;
                              }
                              return Colors.transparent;
                            }),
                            side: BorderSide(
                              color: iconFg.withValues(alpha: 0.5),
                              width: 2,
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12.0),
                              child: RichText(
                                text: TextSpan(
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: iconFg.withValues(alpha: 0.7),
                                  ),
                                  children: [
                                    const TextSpan(
                                      text: 'I agree to the ',
                                    ),
                                    TextSpan(
                                      text: 'Terms of Service',
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () {
                                          _launchUrl('https://chuk.chat/en/terms/');
                                        },
                                    ),
                                    const TextSpan(
                                      text: ' and ',
                                    ),
                                    TextSpan(
                                      text: 'Privacy Policy',
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () {
                                          _launchUrl('https://chuk.chat/en/privacy/');
                                        },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Checkbox(
                            value: _confirmedAge,
                            onChanged: (bool? value) {
                              setState(() {
                                _confirmedAge = value ?? false;
                              });
                            },
                            activeColor: theme.colorScheme.primary,
                            fillColor: WidgetStateProperty.resolveWith<Color>((states) {
                              if (states.contains(WidgetState.selected)) {
                                return theme.colorScheme.primary;
                              }
                              return Colors.transparent;
                            }),
                            side: BorderSide(
                              color: iconFg.withValues(alpha: 0.5),
                              width: 2,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'I confirm that I am at least 16 years old',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: iconFg.withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 24),
                    Semantics(
                      identifier: 'login_submit_button',
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _isSubmitting ||
                                  (!_isSignInMode && (!_agreedToTerms || !_confirmedAge))
                              ? null
                              : _handleSubmit,
                          child: _isSubmitting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  _isSignInMode ? 'Sign in' : 'Create account',
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _isSubmitting ? null : _toggleMode,
                      child: Text(
                        _isSignInMode
                            ? "Don't have an account? Sign up"
                            : 'Already have an account? Sign in',
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
