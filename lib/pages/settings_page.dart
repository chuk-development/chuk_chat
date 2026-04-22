// lib/pages/settings_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/customization_page.dart';
import 'package:chuk_chat/pages/diagnostics_settings_page.dart';
import 'package:chuk_chat/pages/tool_calling_settings_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/pages/system_prompt_page.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
// ignore: unused_import
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:share_plus/share_plus.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';

class SettingsPage extends StatefulWidget {
  final AppShellConfig config;

  const SettingsPage({super.key, required this.config});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _developerOptionsEnabled = false;

  @override
  void initState() {
    super.initState();
    _developerOptionsEnabled = DeveloperOptionsService.enabledNotifier.value;
    DeveloperOptionsService.enabledNotifier.addListener(_onDeveloperOptions);
    // Delay remote sync a bit so push transition into sub-pages stays smooth.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 300), () async {
        if (!mounted) return;
        await _refreshDeveloperOptions();
      }),
    );
  }

  @override
  void dispose() {
    DeveloperOptionsService.enabledNotifier.removeListener(_onDeveloperOptions);
    super.dispose();
  }

  void _onDeveloperOptions() {
    if (!mounted) return;
    setState(() {
      _developerOptionsEnabled = DeveloperOptionsService.enabledNotifier.value;
    });
  }

  Future<void> _refreshDeveloperOptions() async {
    final stopwatch = Stopwatch()..start();
    try {
      await DeveloperOptionsService.initialize();
      await DeveloperOptionsService.syncFromSupabase(forceRefresh: false);
      if (!mounted) return;
      setState(() {
        _developerOptionsEnabled =
            DeveloperOptionsService.enabledNotifier.value;
      });
      unawaited(
        DiagnosticsLogService.timing(
          'settings',
          'load_settings_page_developer_options',
          stopwatch.elapsedMilliseconds,
          data: {'developer_options_enabled': _developerOptionsEnabled},
        ),
      );
    } catch (error) {
      unawaited(
        DiagnosticsLogService.warning(
          'settings',
          'Failed to refresh developer options',
          data: {'error': error.toString()},
        ),
      );
      if (kDebugMode) {
        debugPrint('Failed to refresh developer options: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text(l.settings, style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: theme.resolvedIconColor),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _HeroIdentityTile(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AccountSettingsPage()),
              );
            },
          ),

          _SectionHeader(label: 'AI & Chat'),
          _GroupedCard(
            rows: [
              _SettingsRow(
                icon: Icons.psychology_alt,
                iconAccent: true,
                title: l.modelSelection,
                subtitle: 'Claude Opus 4.7 · 1M context',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ModelSelectorPage(),
                    ),
                  );
                },
              ),
              _SettingsRow(
                icon: Icons.psychology,
                iconAccent: true,
                title: l.aiIdentityMemory,
                subtitle: l.aiIdentityMemorySubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SystemPromptPage(),
                    ),
                  );
                },
              ),
              _SettingsRow(
                icon: Icons.build_circle_outlined,
                iconAccent: true,
                title: l.toolCalling,
                subtitle: l.toolCallingSubtitle,
                trailing: const _Badge('On', tone: BadgeTone.success),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ToolCallingSettingsPage(config: widget.config),
                    ),
                  );
                },
              ),
            ],
          ),

          _SectionHeader(label: 'Appearance'),
          _GroupedCard(
            rows: [
              _SettingsRow(
                icon: Icons.palette_outlined,
                title: l.themeSettings,
                subtitle: l.themeSettingsSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ThemePage(config: widget.config),
                    ),
                  );
                },
              ),
              _SettingsRow(
                icon: Icons.tune,
                title: l.customization,
                subtitle: l.customizationSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CustomizationPage(config: widget.config),
                    ),
                  );
                },
              ),
            ],
          ),

          _SectionHeader(label: 'Data & Privacy'),
          _GroupedCard(
            rows: [
              _SettingsRow(
                icon: Icons.file_download_outlined,
                title: l.exportChats,
                subtitle: l.exportChatsSubtitle,
                onTap: () => _exportChats(context),
              ),
            ],
          ),

          _SectionHeader(label: 'Billing'),
          _GroupedCard(
            rows: [
              _SettingsRow(
                icon: Icons.credit_card,
                title: l.pricingPlans,
                subtitle: l.pricingPlansSubtitle,
                trailing: const _Badge('Upgrade', tone: BadgeTone.primary),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PricingPage()),
                  );
                },
              ),
            ],
          ),

          _SectionHeader(label: 'System'),
          _GroupedCard(
            rows: [
              _SettingsRow(
                icon: Icons.info_outline,
                title: l.about,
                subtitle: l.aboutSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AboutPage()),
                  );
                },
              ),
            ],
          ),
          if (_developerOptionsEnabled) ...[
            const SizedBox(height: 12),
            _DevTile(
              title: l.developerOptions,
              subtitle: l.developerOptionsSubtitle,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DeveloperOptionsPage(),
                  ),
                );
              },
            ),
          ],

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.error,
                side: BorderSide(color: m3.outline),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(context);
                try {
                  await const AuthService().signOut();
                  if (!navigator.mounted) return;
                  if (navigator.canPop()) {
                    navigator.pop();
                  }
                } on AuthServiceException catch (error) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        error.message,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      behavior: SnackBarBehavior.floating,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      duration: const Duration(seconds: 2),
                      dismissDirection: DismissDirection.horizontal,
                    ),
                  );
                } catch (error) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Error: $error',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      behavior: SnackBarBehavior.floating,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      duration: const Duration(seconds: 2),
                      dismissDirection: DismissDirection.horizontal,
                    ),
                  );
                }
              },
              child: Text(
                l.logout,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Chuk Chat',
              style: TextStyle(
                fontSize: 11,
                color: m3.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportChats(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChatStorageService.loadSavedChatsForSidebar();
      if (ChatStorageService.savedChats.isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l.noChatsToExport,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
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
        return;
      }
      final jsonPayload = await ChatStorageService.exportChatsAsJson();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'chuk_chat_export_$timestamp.json';
      final data = Uint8List.fromList(utf8.encode(jsonPayload));

      if (kIsWeb) {
        await Clipboard.setData(ClipboardData(text: jsonPayload));
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l.copiedToClipboard,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
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
        return;
      }

      if (Platform.isLinux) {
        final savedPath = await _saveExportToLinux(data, fileName);
        if (savedPath != null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                l.savedToPath(savedPath),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
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
        } else {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                l.exportCancelled,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 1),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        return;
      }

      try {
        final xFile = XFile.fromData(
          data,
          mimeType: 'application/json',
          name: fileName,
        );
        await SharePlus.instance.share(
          ShareParams(
            files: [xFile],
            subject: 'Chuk Chat chat export',
            text: 'Backup of your Chuk Chat conversations.',
          ),
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l.shareOpened,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 1),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
      } on Exception {
        await Clipboard.setData(ClipboardData(text: jsonPayload));
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l.copiedToClipboard,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
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
      }
    } on StateError catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
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
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l.exportFailed(error.toString()),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
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
    }
  }

  Future<String?> _saveExportToLinux(Uint8List data, String fileName) async {
    final Directory? initialDirectory = await _linuxInitialDirectory();
    final l = AppLocalizations.of(context)!;
    final String? outputPath = await FilePicker.saveFile(
      dialogTitle: l.saveChatExport,
      fileName: fileName,
      initialDirectory: initialDirectory?.path,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );

    if (outputPath == null) {
      return null;
    }

    final file = File(outputPath);
    await file.writeAsBytes(data, flush: true);
    return file.path;
  }

  Future<Directory?> _linuxInitialDirectory() async {
    final String? homeDir = Platform.environment['HOME'];
    if (homeDir == null || homeDir.isEmpty) {
      return null;
    }

    final List<String> candidateFolders = <String>[
      '$homeDir/Downloads',
      '$homeDir/Documents',
      homeDir,
    ];

    for (final path in candidateFolders) {
      final directory = Directory(path);
      if (await directory.exists()) {
        return directory;
      }
    }
    return null;
  }
}

// -------- Private widgets (Material You aesthetic) --------

class _HeroIdentityTile extends StatelessWidget {
  final VoidCallback onTap;

  const _HeroIdentityTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    // Avatar initials: service lookup is out-of-scope here, use a neutral glyph.
    const String initials = 'U';
    const String displayName = 'Chuk Chat User';
    const String email = '';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Ink(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [m3.primaryContainer, m3.tertiaryContainer],
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                initials,
                style: TextStyle(
                  color: cs.onPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: m3.onPrimaryContainer,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (email.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      email,
                      style: TextStyle(
                        fontSize: 13,
                        color: m3.onPrimaryContainer.withValues(alpha: 0.85),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Free Plan · ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: m3.onPrimaryContainer,
                          ),
                        ),
                        const Text(
                          'Upgrade →',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFFFD166),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: m3.onPrimaryContainer.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          color: cs.primary,
        ),
      ),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  final List<Widget> rows;

  const _GroupedCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16),
            child: Divider(
              height: 1,
              thickness: 1,
              color: m3.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        );
      }
      children.add(rows[i]);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Material(
        color: m3.surfaceContainer,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool iconAccent;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.iconAccent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final Color iconColor = iconAccent ? cs.primary : m3.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Icon(icon, size: 22, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: m3.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: m3.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _DevTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DevTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: DottedBorderBox(
          color: m3.outlineVariant,
          radius: 20,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Icon(
                    Icons.developer_mode,
                    size: 22,
                    color: m3.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: m3.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: m3.onSurfaceVariant.withValues(alpha: 0.85),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                const _Badge('Dev', tone: BadgeTone.warning),
                const SizedBox(width: 10),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: m3.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum BadgeTone { neutral, primary, success, warning, error }

class _Badge extends StatelessWidget {
  final String label;
  final BadgeTone tone;

  const _Badge(this.label, {required this.tone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    late final Color bg;
    late final Color fg;
    switch (tone) {
      case BadgeTone.primary:
        bg = m3.primaryContainer;
        fg = m3.onPrimaryContainer;
        break;
      case BadgeTone.success:
        bg = m3.successContainer;
        fg = m3.onSuccessContainer;
        break;
      case BadgeTone.warning:
        bg = m3.warningContainer;
        fg = m3.onWarningContainer;
        break;
      case BadgeTone.error:
        bg = cs.errorContainer;
        fg = cs.onErrorContainer;
        break;
      case BadgeTone.neutral:
        bg = m3.secondaryContainer;
        fg = m3.onSecondaryContainer;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

// Retained for future connector chip surfacing (spec'd reusable widget).
// ignore: unused_element
class _MiniChip extends StatelessWidget {
  final String label;
  final bool connected;

  // ignore: unused_element_parameter
  const _MiniChip(this.label, {this.connected = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: m3.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (connected) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: m3.success,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: m3.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints a dashed rounded-rectangle border around [child].
class DottedBorderBox extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;

  const DottedBorderBox({
    super.key,
    required this.child,
    required this.color,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRectPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double dashWidth;
  final double dashSpace;

  _DashedRectPainter({
    required this.color,
    required this.radius,
  })  : dashWidth = 5,
        dashSpace = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      double distance = 0;
      while (distance < metric.length) {
        final extract = metric.extractPath(
          distance,
          (distance + dashWidth).clamp(0, metric.length),
        );
        canvas.drawPath(extract, paint);
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.dashWidth != dashWidth ||
      oldDelegate.dashSpace != dashSpace;
}
