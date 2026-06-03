// lib/pages/account_settings_page.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/recover_chats_page.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/key_version_service.dart';
import 'package:chuk_chat/services/password_change_service.dart';
import 'package:chuk_chat/services/password_reset_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  final ProfileService _profileService = const ProfileService();
  final TextEditingController _displayNameCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _currentPasswordCtrl = TextEditingController();
  final TextEditingController _newPasswordCtrl = TextEditingController();
  final TextEditingController _confirmPasswordCtrl = TextEditingController();

  bool _isSaving = false;
  bool _isLoading = true;
  bool _isDeletingAccount = false;
  bool _isChangingPassword = false;
  bool _obscureCurrentPassword = true;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;
  ProfileRecord? _profile;
  String? _errorMessage;
  String? _passwordChangeError;
  String? _passwordChangeNotice;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _displayNameCtrl.dispose();
    _emailCtrl.dispose();
    _currentPasswordCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final record = await _profileService.loadOrCreateProfile();
      if (!mounted) return;
      setState(() {
        _profile = record;
        _displayNameCtrl.text = record.displayName;
        _emailCtrl.text = record.email;
        _isLoading = false;
      });
    } on ProfileServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.message;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = AppLocalizations.of(context)!.failedToLoadProfile(error.toString());
        _isLoading = false;
      });
    }
  }

  Future<void> _saveAccountSettings() async {
    if (_profile == null) return;

    // Cache localizations before any async gap.
    final l = AppLocalizations.of(context)!;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final updatedRecord = _profile!.copyWith(
        displayName: _displayNameCtrl.text.trim(),
      );

      await _profileService.saveProfile(updatedRecord);

      final newEmail = _emailCtrl.text.trim();
      String? emailNotice;

      if (newEmail.isEmpty) {
        throw ProfileServiceException(l.emailCannotBeEmpty);
      }

      if (newEmail != _profile!.email) {
        await SupabaseService.auth.updateUser(UserAttributes(email: newEmail));
        emailNotice = l.emailUpdated(newEmail);
      }

      if (!mounted) return;
      setState(() {
        _profile = updatedRecord.copyWith(email: newEmail);
        _isSaving = false;
      });

      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            emailNotice ?? l.saved,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = error.message;
      });
    } on ProfileServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = l.failedToSaveProfile(error.toString());
      });
    }
  }

  // Recovery section shows whenever the account has previous encryption keys
  // (i.e. the password was reset/changed at least once). It must NOT gate on
  // lockedChatCount: the local plaintext cache (kept on desktop) can hold
  // readable copies of old-key chats, which zeroes that count even though the
  // server copies are still encrypted with the old key and need recovery.
  Widget _buildRecoverChatsSection([AppLocalizations? localizations]) {
    final l = localizations ?? AppLocalizations.of(context)!;
    final user = SupabaseService.auth.currentUser;
    if (user == null || !KeyVersionService.hasPreviousKeys(user)) {
      return const SizedBox.shrink();
    }

    // Informational only — show the locked count when reliably known (>0),
    // otherwise a generic prompt. Never use it to hide the section.
    final lockedCount = PasswordResetService.lockedChatCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Chat Recovery'),
        _InfoCard(
          text: lockedCount > 0
              ? l.lockedChatsCount(lockedCount)
              : l.recoverOldChatsAvailable,
          tone: InfoTone.neutral,
          icon: Icons.lock_outline,
        ),
        const SizedBox(height: 12),
        _GroupedCard(
          children: [
            _SettingsRow(
              icon: Icons.lock_open,
              title: l.encryptedChatRecovery,
              subtitle: l.recoverChats,
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RecoverChatsPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _changePassword() async {
    if (_isChangingPassword) return;

    final newPassword = _newPasswordCtrl.text;
    final confirmPassword = _confirmPasswordCtrl.text;
    if (newPassword.trim() != confirmPassword.trim()) {
      setState(() {
        _passwordChangeError = AppLocalizations.of(context)!.passwordsDoNotMatch;
        _passwordChangeNotice = null;
      });
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isChangingPassword = true;
      _passwordChangeError = null;
      _passwordChangeNotice = null;
    });

    const service = PasswordChangeService();
    try {
      final notice = await service.changePassword(
        currentPassword: _currentPasswordCtrl.text,
        newPassword: newPassword,
      );
      if (!mounted) return;
      _currentPasswordCtrl.clear();
      _newPasswordCtrl.clear();
      _confirmPasswordCtrl.clear();
      setState(() {
        _isChangingPassword = false;
        _passwordChangeNotice = notice;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            notice,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } on PasswordChangeException catch (error) {
      if (!mounted) return;
      setState(() {
        _isChangingPassword = false;
        _passwordChangeError = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isChangingPassword = false;
        _passwordChangeError = AppLocalizations.of(context)!.failedToChangePassword(error.toString());
      });
    }
  }

  Future<void> _deleteAccount() async {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    // ── Step 1: First warning ──
    final step1 = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: cs.error, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(l.deleteAccountQuestion)),
          ],
        ),
        content: Text(l.deleteAccountConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.yesDelete),
          ),
        ],
      ),
    );

    if (step1 != true || !mounted) return;

    // ── Step 2: Final warning ──
    final step2 = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.delete_forever, color: cs.error, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(l.thisIsPermanent)),
          ],
        ),
        content: Text(l.finalDeleteWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.noKeepMyAccount),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.deleteEverything),
          ),
        ],
      ),
    );

    if (step2 != true || !mounted) return;

    // ── Step 3: Password confirmation ──
    final passwordController = TextEditingController();
    final passwordConfirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String? errorText;
        bool isVerifying = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text(l.confirmYourPassword),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.confirmPasswordBody),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l.password,
                    errorText: errorText,
                    prefixIcon: const Icon(Icons.lock_outline),
                  ),
                  onSubmitted: isVerifying
                      ? null
                      : (_) async {
                          final password = passwordController.text.trim();
                          if (password.isEmpty) {
                            setDialogState(
                              () => errorText = l.passwordRequired,
                            );
                            return;
                          }
                          setDialogState(() {
                            isVerifying = true;
                            errorText = null;
                          });
                          try {
                            final email = Supabase
                                .instance
                                .client
                                .auth
                                .currentUser
                                ?.email;
                            if (email == null) {
                              throw Exception('No email found');
                            }
                            await Supabase.instance.client.auth
                                .signInWithPassword(
                                  email: email,
                                  password: password,
                                );
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                          } on AuthException catch (e) {
                            setDialogState(() {
                              isVerifying = false;
                              errorText = e.message;
                            });
                          } catch (e) {
                            setDialogState(() {
                              isVerifying = false;
                              errorText = l.verificationFailed(e.toString());
                            });
                          }
                        },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: isVerifying
                    ? null
                    : () => Navigator.of(ctx).pop(false),
                child: Text(l.cancel),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: cs.error),
                onPressed: isVerifying
                    ? null
                    : () async {
                        final password = passwordController.text.trim();
                        if (password.isEmpty) {
                          setDialogState(
                            () => errorText = l.passwordRequired,
                          );
                          return;
                        }
                        setDialogState(() {
                          isVerifying = true;
                          errorText = null;
                        });
                        try {
                          final email =
                              Supabase.instance.client.auth.currentUser?.email;
                          if (email == null) {
                            throw Exception('No email found');
                          }
                          await Supabase.instance.client.auth
                              .signInWithPassword(
                                email: email,
                                password: password,
                              );
                          if (ctx.mounted) Navigator.of(ctx).pop(true);
                        } on AuthException catch (e) {
                          setDialogState(() {
                            isVerifying = false;
                            errorText = e.message;
                          });
                        } catch (e) {
                          setDialogState(() {
                            isVerifying = false;
                            errorText = l.verificationFailed(e.toString());
                          });
                        }
                      },
                child: isVerifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.verifyAndDelete),
              ),
            ],
          ),
        );
      },
    );

    passwordController.dispose();
    if (passwordConfirmed != true || !mounted) return;

    // ── Step 4: Execute deletion ──
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isDeletingAccount = true);

    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) throw Exception('Not authenticated');

      final response = await http.delete(
        Uri.parse('${ApiConfigService.apiBaseUrl}/v1/user/delete-account'),
        headers: {'Authorization': 'Bearer ${session.accessToken}'},
      );

      if (response.statusCode != 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        throw Exception(body['detail'] ?? 'Failed to delete account');
      }

      await const AuthService().signOut();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isDeletingAccount = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l.failedToDeleteAccount(error.toString()),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 3),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    Widget bodyContent;

    if (_isLoading) {
      bodyContent = const Center(child: CircularProgressIndicator());
    } else if (_profile == null) {
      bodyContent = Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _errorMessage ?? l.unableToLoadProfile,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadProfile,
                child: Text(l.retry),
              ),
            ],
          ),
        ),
      );
    } else {
      bodyContent = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _InfoCard(
                text: _errorMessage!,
                tone: InfoTone.danger,
                icon: Icons.error_outline,
              ),
            ),

          // Profile
          const _SectionHeader('Profile'),
          _FieldLabel(l.displayName),
          TextFormField(
            controller: _displayNameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: l.displayNameHint,
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l.emailAddress),
          TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              hintText: l.emailAddressHint,
              prefixIcon: const Icon(Icons.mail_outline),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _isSaving
                  ? SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          cs.onPrimary,
                        ),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(_isSaving ? l.saving : l.saveChanges),
              onPressed: _isSaving || _profile == null
                  ? null
                  : _saveAccountSettings,
            ),
          ),

          // Security
          const _SectionHeader('Security'),
          if (_passwordChangeError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _InfoCard(
                text: _passwordChangeError!,
                tone: InfoTone.danger,
                icon: Icons.error_outline,
              ),
            ),
          if (_passwordChangeNotice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _InfoCard(
                text: _passwordChangeNotice!,
                tone: InfoTone.success,
                icon: Icons.check_circle_outline,
              ),
            ),
          _FieldLabel(l.currentPassword),
          TextField(
            controller: _currentPasswordCtrl,
            obscureText: _obscureCurrentPassword,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureCurrentPassword
                      ? Icons.visibility_off
                      : Icons.visibility,
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscureCurrentPassword = !_obscureCurrentPassword;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l.newPassword, helper: l.minCharsPassword),
          TextField(
            controller: _newPasswordCtrl,
            obscureText: _obscureNewPassword,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.lock_reset),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureNewPassword
                      ? Icons.visibility_off
                      : Icons.visibility,
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscureNewPassword = !_obscureNewPassword;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l.confirmNewPassword),
          TextField(
            controller: _confirmPasswordCtrl,
            obscureText: _obscureConfirmPassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!_isChangingPassword) {
                _changePassword();
              }
            },
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.check_circle_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirmPassword
                      ? Icons.visibility_off
                      : Icons.visibility,
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscureConfirmPassword = !_obscureConfirmPassword;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              icon: _isChangingPassword
                  ? SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          cs.onSecondaryContainer,
                        ),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.password),
              label: Text(l.updatePassword),
              onPressed: _isChangingPassword ? null : _changePassword,
            ),
          ),

          // Chat Recovery (conditional).
          _buildRecoverChatsSection(l),

          const SizedBox(height: 24),

          // Danger Zone
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 0, 8),
            child: Text(
              'DANGER ZONE',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
                color: cs.error,
              ),
            ),
          ),
          _InfoCard(
            text: l.deleteAccountWarning,
            tone: InfoTone.danger,
            icon: Icons.warning_amber_rounded,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: cs.errorContainer,
                foregroundColor: cs.onErrorContainer,
              ),
              icon: _isDeletingAccount
                  ? SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          cs.onErrorContainer,
                        ),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.delete_forever),
              onPressed: _isDeletingAccount ? null : _deleteAccount,
              label: Text(l.deleteAccount),
            ),
          ),
          const SizedBox(height: 32),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.accountSettings),
        centerTitle: false,
      ),
      body: bodyContent,
    );
  }
}

// ───────── private shared widgets ─────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 0, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  const _GroupedCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        separated.add(
          Divider(height: 1, color: m3.outlineVariant, indent: 56),
        );
      }
      separated.add(children[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: separated),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label, {this.helper});

  final String label;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: m3.onSurfaceVariant,
            ),
          ),
          if (helper != null) ...[
            const SizedBox(height: 2),
            Text(
              helper!,
              style: TextStyle(
                fontSize: 11.5,
                color: m3.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 24, color: m3.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              IconTheme.merge(
                data: IconThemeData(color: m3.onSurfaceVariant),
                child: trailing!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum InfoTone { neutral, warn, danger, success }

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.text,
    this.tone = InfoTone.neutral,
    this.icon,
  });

  final String text;
  final InfoTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final Color bg;
    final Color fg;
    switch (tone) {
      case InfoTone.warn:
        bg = m3.warningContainer.withValues(alpha: 0.4);
        fg = m3.onWarningContainer;
        break;
      case InfoTone.danger:
        bg = cs.errorContainer.withValues(alpha: 0.4);
        fg = cs.onErrorContainer;
        break;
      case InfoTone.success:
        bg = m3.successContainer.withValues(alpha: 0.4);
        fg = m3.onSuccessContainer;
        break;
      case InfoTone.neutral:
        bg = m3.surfaceContainerLow;
        fg = m3.onSurfaceVariant;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? Icons.info_outline, size: 18, color: fg),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, height: 1.4, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}
