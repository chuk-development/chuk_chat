// lib/pages/account_settings_page.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/password_change_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

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

  bool _notificationsEnabled = true;
  bool _weeklySummaryEnabled = false;
  bool _isSaving = false;
  bool _isLoading = true;
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
        _notificationsEnabled = record.notificationsEnabled;
        _weeklySummaryEnabled = record.weeklySummaryEnabled;
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
        notificationsEnabled: _notificationsEnabled,
        weeklySummaryEnabled: _weeklySummaryEnabled,
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
          content: Text(emailNotice ?? 'Account settings saved'),
          backgroundColor: Theme.of(context).colorScheme.primary,
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
          content: Text(notice),
          backgroundColor: Theme.of(context).colorScheme.primary,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.iconTheme.color!;
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
                'Update how your name and email appear inside chuk.chat.',
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
            title: 'Notifications',
            description: 'Choose which updates you want to receive.',
            child: Column(
              children: [
                SwitchListTile(
                  value: _notificationsEnabled,
                  title: const Text('Enable push notifications'),
                  subtitle: const Text('Important activity and chat mentions'),
                  onChanged: (value) {
                    setState(() => _notificationsEnabled = value);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _weeklySummaryEnabled,
                  title: const Text('Weekly summary email'),
                  subtitle: const Text('Sends highlights every Monday morning'),
                  onChanged: (value) {
                    setState(() => _weeklySummaryEnabled = value);
                  },
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
                const SizedBox(height: 24),
                const Divider(height: 1),
                const SizedBox(height: 24),
                Text(
                  'Two-factor authentication',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Coming soon. You\'ll be able to secure logins with authenticator apps.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Connected devices', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Manage the sessions where your account is active once we ship device management.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
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
    final Color border = theme.iconTheme.color!.withValues(alpha: 0.25);

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
                color: theme.iconTheme.color!.withValues(alpha: 0.7),
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
