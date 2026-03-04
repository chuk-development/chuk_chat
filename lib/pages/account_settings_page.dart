// lib/pages/account_settings_page.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/pages/session_management_page.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/password_change_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
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
        _errorMessage = 'Failed to load profile: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveAccountSettings() async {
    if (_profile == null) return;

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
        throw const ProfileServiceException('Email cannot be empty.');
      }

      if (newEmail != _profile!.email) {
        await SupabaseService.auth.updateUser(UserAttributes(email: newEmail));
        emailNotice =
            'Email updated. Confirm the change using the link Supabase sent to $newEmail.';
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
            emailNotice ?? 'Saved',
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
        _errorMessage = 'Failed to save profile: $error';
      });
    }
  }

  Future<void> _changePassword() async {
    if (_isChangingPassword) return;

    final newPassword = _newPasswordCtrl.text;
    final confirmPassword = _confirmPasswordCtrl.text;
    if (newPassword.trim() != confirmPassword.trim()) {
      setState(() {
        _passwordChangeError = 'New passwords do not match.';
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
        _passwordChangeError = 'Failed to change password: $error';
      });
    }
  }

  Future<void> _deleteAccount() async {
    // ── Step 1: First warning ──
    final step1 = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 10),
            Text('Delete Account?'),
          ],
        ),
        content: const Text(
          'Are you sure you want to delete your account?\n\n'
          'This will permanently erase:\n'
          '  - All your chats and messages\n'
          '  - All stored memories\n'
          '  - Your profile and settings\n'
          '  - Any active subscriptions\n\n'
          'This action is irreversible. Your data cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes, I want to delete'),
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
        title: const Row(
          children: [
            Icon(Icons.delete_forever, color: Colors.red, size: 28),
            SizedBox(width: 10),
            Text('This is permanent'),
          ],
        ),
        content: const Text(
          'This is your last chance to turn back.\n\n'
          'Once deleted, there is absolutely no way to recover '
          'your account, chats, memories, or any associated data.\n\n'
          'Everything will be gone forever.\n\n'
          'Do you still want to proceed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No, keep my account'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete everything'),
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
            title: const Text('Confirm your password'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'To confirm account deletion, please enter your password.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    errorText: errorText,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                  ),
                  onSubmitted: isVerifying
                      ? null
                      : (_) async {
                          final password = passwordController.text.trim();
                          if (password.isEmpty) {
                            setDialogState(
                              () => errorText = 'Password is required',
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
                              errorText = 'Verification failed: $e';
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
                child: const Text('Cancel'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: isVerifying
                    ? null
                    : () async {
                        final password = passwordController.text.trim();
                        if (password.isEmpty) {
                          setDialogState(
                            () => errorText = 'Password is required',
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
                            errorText = 'Verification failed: $e';
                          });
                        }
                      },
                child: isVerifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Verify & Delete'),
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
            'Failed to delete account: $error',
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
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.resolvedIconColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

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
                _errorMessage ?? 'Unable to load your profile right now.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadProfile,
                child: const Text('Retry'),
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
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.redAccent,
                ),
              ),
            ),
          _AccountSectionCard(
            title: 'Profile',
            description:
                'Update how your name and email appear inside Chuk Chat.',
            child: Column(
              children: [
                TextFormField(
                  controller: _displayNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    hintText: 'How other people see you',
                  ),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Email address',
                    hintText: 'Where we send notifications',
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _AccountSectionCard(
            title: 'Security',
            description: 'Reassure yourself everything is protected.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Change password', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  'Update your Supabase password and re-encrypt your saved chats.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 16),
                if (_passwordChangeError != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.red.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      _passwordChangeError!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                if (_passwordChangeNotice != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.green.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      _passwordChangeNotice!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.green.shade400,
                      ),
                    ),
                  ),
                TextField(
                  controller: _currentPasswordCtrl,
                  decoration: InputDecoration(
                    labelText: 'Current password',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureCurrentPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureCurrentPassword = !_obscureCurrentPassword;
                        });
                      },
                    ),
                  ),
                  obscureText: _obscureCurrentPassword,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _newPasswordCtrl,
                  decoration: InputDecoration(
                    labelText: 'New password',
                    helperText: 'Minimum 8 characters.',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureNewPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureNewPassword = !_obscureNewPassword;
                        });
                      },
                    ),
                  ),
                  obscureText: _obscureNewPassword,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirmPasswordCtrl,
                  decoration: InputDecoration(
                    labelText: 'Confirm new password',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirmPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword = !_obscureConfirmPassword;
                        });
                      },
                    ),
                  ),
                  obscureText: _obscureConfirmPassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!_isChangingPassword) {
                      _changePassword();
                    }
                  },
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isChangingPassword ? null : _changePassword,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _isChangingPassword
                        ? SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                theme.colorScheme.onPrimary,
                              ),
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Update password'),
                  ),
                ),
                if (kFeatureSessionManagement) ...[
                  const SizedBox(height: 24),
                  const Divider(height: 1),
                  const SizedBox(height: 24),
                  Text('Connected devices', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'See where your account is signed in and sign out other devices remotely.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: iconFg.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.devices, size: 18),
                      label: const Text('Manage devices'),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SessionManagementPage(),
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              icon: _isSaving
                  ? SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.onPrimary,
                        ),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(_isSaving ? 'Saving…' : 'Save changes'),
              onPressed: _isSaving || _profile == null
                  ? null
                  : _saveAccountSettings,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          _AccountSectionCard(
            title: 'Danger Zone',
            description:
                'Irreversible actions that affect your entire account.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Deleting your account will cancel all subscriptions, '
                  'remove your data, and cannot be undone.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _isDeletingAccount ? null : _deleteAccount,
                    child: _isDeletingAccount
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            'Delete Account',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      );
    }

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Account Settings', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: bodyContent,
    );
  }
}

class _AccountSectionCard extends StatelessWidget {
  final String title;
  final String description;
  final Widget child;

  const _AccountSectionCard({
    required this.title,
    required this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color bg = theme.scaffoldBackgroundColor.lighten(0.05);
    final Color iconFg = theme.resolvedIconColor;
    final Color border = iconFg.withValues(alpha: 0.25);

    return Card(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: border, width: 1),
      ),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: iconFg.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}
