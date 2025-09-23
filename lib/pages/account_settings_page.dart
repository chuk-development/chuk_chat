// lib/pages/account_settings_page.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({Key? key}) : super(key: key);

  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  static const _kDisplayNameKey = 'account_display_name';
  static const _kEmailKey = 'account_email';
  static const _kNotificationsKey = 'account_notifications_enabled';
  static const _kWeeklySummaryKey = 'account_weekly_summary_enabled';

  final TextEditingController _displayNameCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();

  bool _notificationsEnabled = true;
  bool _weeklySummaryEnabled = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadAccountSettings();
  }

  @override
  void dispose() {
    _displayNameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAccountSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _displayNameCtrl.text = prefs.getString(_kDisplayNameKey) ?? 'Douglas M.';
      _emailCtrl.text = prefs.getString(_kEmailKey) ?? 'douglas@example.com';
      _notificationsEnabled = prefs.getBool(_kNotificationsKey) ?? true;
      _weeklySummaryEnabled = prefs.getBool(_kWeeklySummaryKey) ?? false;
    });
  }

  Future<void> _saveAccountSettings() async {
    setState(() => _isSaving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDisplayNameKey, _displayNameCtrl.text.trim());
    await prefs.setString(_kEmailKey, _emailCtrl.text.trim());
    await prefs.setBool(_kNotificationsKey, _notificationsEnabled);
    await prefs.setBool(_kWeeklySummaryKey, _weeklySummaryEnabled);
    if (!mounted) return;
    setState(() => _isSaving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Account settings saved'),
        backgroundColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.iconTheme.color!;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Account Settings', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _AccountSectionCard(
            title: 'Profile',
            description: 'Update how your name and email appear inside chuk.chat.',
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
                Text(
                  'Connected devices',
                  style: theme.textTheme.titleMedium,
                ),
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
                        valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.onPrimary),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(_isSaving ? 'Saving…' : 'Save changes'),
              onPressed: _isSaving ? null : _saveAccountSettings,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
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
            Text(
              title,
              style: theme.textTheme.titleLarge,
            ),
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
