import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'package:chuk_chat/pages/forgot_password_page.dart';
import 'package:chuk_chat/pages/otp_verification_page.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/supabase_config.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/input_validator.dart';
import 'package:chuk_chat/widgets/password_strength_meter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();

  final AuthService _authService = const AuthService();

  bool _isSubmitting = false;
  bool _isSignInMode = true;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _agreedToTerms = false;
  bool _confirmedAge = false;
  String? _errorMessage;
  String _currentPassword = '';

  @override
  void initState() {
    super.initState();
    // Listen to password changes for strength meter
    _passwordCtrl.addListener(() {
      setState(() {
        _currentPassword = _passwordCtrl.text;
      });
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _displayNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final l = AppLocalizations.of(context)!;

    // Check if user agreed to terms when signing up
    if (!_isSignInMode && !_agreedToTerms) {
      setState(() {
        _errorMessage = l.mustAgreeToTerms;
      });
      return;
    }

    // Check if user confirmed minimum age when signing up
    if (!_isSignInMode && !_confirmedAge) {
      setState(() {
        _errorMessage = l.mustBe16;
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
        // Chat loading is handled by AppInitializationService via AuthGate.
        // No need to call loadSavedChatsForSidebar() here — it would race
        // with the automatic initialization triggered by the auth state change.
      } else {
        final displayName = _displayNameCtrl.text.trim();
        await _authService.signUpWithPassword(
          email: email,
          password: password,
          displayName: displayName.isEmpty ? null : displayName,
        );

        if (!mounted) return;
        // Sign-up succeeded (and the email is new — otherwise
        // signUpWithPassword would have thrown). Move to OTP code entry.
        // The plaintext password is captured by the verify closure so we can
        // initialize the encryption key once the account is confirmed.
        await _openSignupOtpVerification(email: email, password: password);
      }
    } on AuthServiceException catch (error) {
      final bool isEmailAlreadyRegistered =
          !_isSignInMode &&
          error.code == AuthServiceException.codeEmailAlreadyRegistered;
      if (isEmailAlreadyRegistered && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        NiceSnackBar.showOn(messenger, error.message);
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
        _errorMessage = l.unexpectedError(error.toString());
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  /// Pushes the OTP code-entry page after a successful sign-up. On a valid
  /// code the account is confirmed, the encryption key is initialized with
  /// [password], and we pop back — revealing the signed-in app shell (the
  /// AuthGate has already flipped to its signed-in view underneath this
  /// route). No second login is required.
  Future<void> _openSignupOtpVerification({
    required String email,
    required String password,
  }) async {
    final navigator = Navigator.of(context);
    final l = AppLocalizations.of(context)!;

    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => OtpVerificationPage(
          email: email,
          body: l.verifySignupBody(email),
          onSubmit: (code) async {
            await _authService.verifySignupOtp(email: email, token: code);
            // Brand-new account: set up the encryption key for the first time.
            await EncryptionService.initializeForPassword(password);
            navigator.pop();
          },
          onResend: () => _authService.resendSignupOtp(email: email),
        ),
      ),
    );

    // Back from the OTP page without completing (user tapped "use a different
    // email"). Clear sensitive fields so they aren't left populated.
    if (!mounted) return;
    setState(() {
      _passwordCtrl.clear();
      _confirmPasswordCtrl.clear();
      _currentPassword = '';
    });
  }

  void _toggleMode() {
    setState(() {
      _isSignInMode = !_isSignInMode;
      _errorMessage = null;
      _agreedToTerms = false; // Reset checkbox when switching modes
      _confirmedAge = false;
      _confirmPasswordCtrl.clear();
      _obscureConfirmPassword = true;
    });
  }

  String? _validatePassword(String? value) {
    // For sign-in mode, allow any password (backend will validate)
    // For sign-up mode, enforce strong password requirements
    if (value == null || value.isEmpty) {
      return AppLocalizations.of(context)!.enterYourPassword;
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
                    Text(
                      l.welcomeToChukChat,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: iconFg,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isSignInMode
                          ? l.signInWithEmail
                          : l.createAccountWithEmail,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: iconFg.withValues(alpha: 0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
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
                          l.supabaseNotConfigured,
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
                        decoration: InputDecoration(
                          labelText: l.displayName,
                          hintText: l.howOthersSeeYou,
                        ),
                        textCapitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 16),
                    ],
                    Semantics(
                      identifier: 'login_email_field',
                      child: TextFormField(
                        controller: _emailCtrl,
                        decoration: InputDecoration(
                          labelText: l.email,
                          hintText: l.emailPlaceholder,
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
                          labelText: l.password,
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
                    // Show "Forgot password?" link in sign-in mode
                    if (_isSignInMode) ...[
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _isSubmitting
                              ? null
                              : () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const ForgotPasswordPage(),
                                    ),
                                  );
                                },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                          ),
                          child: Text(
                            l.forgotPassword,
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                    // Show password strength meter only in sign-up mode
                    if (!_isSignInMode && _currentPassword.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      PasswordStrengthMeter(password: _currentPassword),
                    ],
                    if (!_isSignInMode) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        identifier: 'login_confirm_password_field',
                        child: TextFormField(
                          controller: _confirmPasswordCtrl,
                          decoration: InputDecoration(
                            labelText: l.confirmPassword,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureConfirmPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () {
                                setState(
                                  () => _obscureConfirmPassword =
                                      !_obscureConfirmPassword,
                                );
                              },
                            ),
                          ),
                          obscureText: _obscureConfirmPassword,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) {
                            if (!_isSubmitting) {
                              _handleSubmit();
                            }
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
                      ),
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
                            fillColor: WidgetStateProperty.resolveWith<Color>((
                              states,
                            ) {
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
                                    TextSpan(text: l.agreeToTerms),
                                    TextSpan(
                                      text: l.termsOfService,
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () {
                                          _launchUrl(
                                            'https://chuk.chat/en/terms/',
                                          );
                                        },
                                    ),
                                    TextSpan(text: l.andText),
                                    TextSpan(
                                      text: l.privacyPolicy,
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () {
                                          _launchUrl(
                                            'https://chuk.chat/en/privacy/',
                                          );
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
                            fillColor: WidgetStateProperty.resolveWith<Color>((
                              states,
                            ) {
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
                              l.confirmAge16,
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
                          onPressed:
                              _isSubmitting ||
                                  (!_isSignInMode &&
                                      (!_agreedToTerms || !_confirmedAge))
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
                                  _isSignInMode ? l.signIn : l.createAccount,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _isSubmitting ? null : _toggleMode,
                      child: Text(
                        _isSignInMode
                            ? l.noAccountSignUp
                            : l.haveAccountSignIn,
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
