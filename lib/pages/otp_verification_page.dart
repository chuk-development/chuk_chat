import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

/// Reusable page for entering a 6-digit email verification code.
///
/// Used by both the signup confirmation and password recovery flows. The
/// caller supplies [onSubmit] (verify the code + perform any post-verify
/// action such as initializing encryption or navigating) and [onResend]
/// (request a fresh code). Both callbacks may throw [AuthServiceException];
/// this page maps the known codes to localized messages.
///
/// This page is pushed as a route ON TOP of the AuthGate. A successful
/// verification activates a Supabase session, which flips the AuthGate
/// underneath to its signed-in view — but this pushed route stays visible
/// until [onSubmit] navigates away, so the session change never interrupts
/// the flow.
class OtpVerificationPage extends StatefulWidget {
  const OtpVerificationPage({
    super.key,
    required this.email,
    required this.body,
    required this.onSubmit,
    required this.onResend,
  });

  /// The email address the code was sent to (shown in the body text).
  final String email;

  /// Already-localized explanatory text (typically includes [email]).
  final String body;

  /// Verifies [code] and performs any post-verify work (encryption init,
  /// navigation). Throwing surfaces an error message and keeps the user here.
  final Future<void> Function(String code) onSubmit;

  /// Requests a fresh code be emailed. Throwing surfaces an error message.
  final Future<void> Function() onResend;

  @override
  State<OtpVerificationPage> createState() => _OtpVerificationPageState();
}

class _OtpVerificationPageState extends State<OtpVerificationPage> {
  static const int _resendCooldownSeconds = 60;

  final _formKey = GlobalKey<FormState>();
  final _codeCtrl = TextEditingController();

  bool _isSubmitting = false;
  bool _isResending = false;
  String? _errorMessage;
  int _resendSecondsLeft = _resendCooldownSeconds;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    // A code was just sent before navigating here — start the cooldown.
    _startCooldown();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendSecondsLeft = _resendCooldownSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_resendSecondsLeft <= 1) {
          _resendSecondsLeft = 0;
          timer.cancel();
        } else {
          _resendSecondsLeft--;
        }
      });
    });
  }

  String _messageForError(Object error, String fallback) {
    final l = AppLocalizations.of(context)!;
    if (error is AuthServiceException) {
      switch (error.code) {
        case AuthServiceException.codeOtpInvalidOrExpired:
          return l.invalidCode;
        case AuthServiceException.codeOtpRateLimited:
          return l.tooManyAttempts;
        default:
          return error.message;
      }
    }
    return fallback;
  }

  Future<void> _handleVerify() async {
    if (!_formKey.currentState!.validate()) return;
    final l = AppLocalizations.of(context)!;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await widget.onSubmit(_codeCtrl.text.trim());
      // On success the caller navigates away; nothing more to do here.
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _messageForError(error, l.otpVerificationFailed);
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _handleResend() async {
    if (_resendSecondsLeft > 0 || _isResending) return;
    final l = AppLocalizations.of(context)!;

    setState(() {
      _isResending = true;
      _errorMessage = null;
    });

    try {
      await widget.onResend();
      if (!mounted) return;
      _startCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.codeResent)),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _messageForError(error, l.otpVerificationFailed);
      });
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
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
                      Icons.mark_email_read_outlined,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l.verifyEmailTitle,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: iconFg,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.body,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: iconFg.withValues(alpha: 0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _codeCtrl,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 6,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: iconFg,
                        letterSpacing: 8,
                      ),
                      decoration: InputDecoration(
                        labelText: l.verificationCode,
                        hintText: l.verificationCodeHint,
                        counterText: '',
                      ),
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (!_isSubmitting) _handleVerify();
                      },
                      validator: (value) {
                        if (value == null || value.trim().length != 6) {
                          return l.enterVerificationCode;
                        }
                        return null;
                      },
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.redAccent,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _isSubmitting ? null : _handleVerify,
                        child: _isSubmitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(l.verifyButton),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: (_resendSecondsLeft > 0 || _isResending)
                          ? null
                          : _handleResend,
                      child: Text(
                        _resendSecondsLeft > 0
                            ? l.resendCodeIn('$_resendSecondsLeft')
                            : l.resendCode,
                      ),
                    ),
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: Text(l.changeEmailAddress),
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
