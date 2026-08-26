// lib/pages/settings_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/customization_page.dart';
import 'package:chuk_chat/pages/diagnostics_settings_page.dart';
import 'package:chuk_chat/pages/sandbox_management_page.dart';
import 'package:chuk_chat/models/app_mode.dart';
import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/pages/tool_calling_settings_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/pages/system_prompt_page.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/onboarding_tour_controller.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
// ignore: unused_import
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:share_plus/share_plus.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/user_status_service.dart';

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
          ExpressiveSectionHeader('Account'),
          ExpressiveGroup(
            children: [
              _AccountRow(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AccountSettingsPage(),
                    ),
                  );
                },
              ),
              KeyedSubtree(
                key: TourKeyRegistry.instance
                    .keyFor(TourSlots.settingsPricingTile),
                child: _SettingsRow(
                  icon: Icons.credit_card,
                  title: l.pricingPlans,
                  subtitle: l.pricingPlansSubtitle,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(name: 'tour:pricing'),
                        builder: (_) => const PricingPage(),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),

          ExpressiveSectionHeader('AI & Chat'),
          ExpressiveGroup(
            children: [
              KeyedSubtree(
                key: TourKeyRegistry.instance
                    .keyFor(TourSlots.settingsModelSelectionTile),
                child: _SettingsRow(
                  icon: Icons.smart_toy_outlined,
                  title: l.modelSelection,
                  subtitle: l.modelSelectionSubtitle,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(
                          name: 'tour:model_selector',
                        ),
                        builder: (_) => const ModelSelectorPage(),
                      ),
                    );
                  },
                ),
              ),
              KeyedSubtree(
                key: TourKeyRegistry.instance
                    .keyFor(TourSlots.settingsAiIdentityTile),
                child: _SettingsRow(
                  icon: Icons.fingerprint,
                  title: l.aiIdentityMemory,
                  subtitle: l.aiIdentityMemorySubtitle,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(
                          name: 'tour:ai_identity',
                        ),
                        builder: (_) => const SystemPromptPage(),
                      ),
                    );
                  },
                ),
              ),
              _SettingsRow(
                icon: Icons.build_circle_outlined,
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
              if (kFeatureMcp && !kIsWeb)
                _SettingsRow(
                  icon: Icons.extension_outlined,
                  title: l.connectors,
                  subtitle: l.connectorsSubtitle,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            McpConnectorsPage(isCoworkActive: isCoworkActive),
                      ),
                    );
                  },
                ),
              _SettingsRow(
                icon: Icons.auto_awesome_outlined,
                title: l.skills,
                subtitle: l.skillsSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SkillsSettingsPage(),
                    ),
                  );
                },
              ),
              // Fix C: the standalone GitHub entry was removed and the
              // GitHub connection now lives inside SandboxManagementPage —
              // the GitHub token is only ever used by `git`/`gh` inside the
              // sandbox, so the entry point belongs there.
              _SettingsRow(
                icon: Icons.developer_board,
                title: 'Sandboxes',
                subtitle:
                    'See and stop running code-execution containers (max 2)',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SandboxManagementPage(),
                    ),
                  );
                },
              ),
            ],
          ),

          ExpressiveSectionHeader('Appearance'),
          ExpressiveGroup(
            children: [
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

          if (_developerOptionsEnabled) ...[
            ExpressiveSectionHeader('Data & Privacy'),
            ExpressiveGroup(
              children: [
                _SettingsRow(
                  icon: Icons.file_download_outlined,
                  title: l.exportChats,
                  subtitle: l.exportChatsSubtitle,
                  onTap: () => _exportChats(context),
                ),
              ],
            ),
          ],

          ExpressiveSectionHeader('System'),
          ExpressiveGroup(
            children: [
              _SettingsRow(
                icon: Icons.school_outlined,
                title: l.onboardingReplayTile,
                subtitle: l.onboardingReplayTileSubtitle,
                onTap: () => _replayOnboarding(context),
              ),
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

  Future<void> _replayOnboarding(BuildContext context) async {
    final navigator = Navigator.of(context);
    // Pop the Settings page first so the tour starts on the chat root.
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
    if (!navigator.mounted) return;
    await AppThemeService.instance.setOnboardingCompleted(false);
    if (!navigator.mounted) return;
    await OnboardingTourController.instance.start(
      navigator.context,
      shellConfig: widget.config,
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
    final l = AppLocalizations.of(context)!;
    final Directory? initialDirectory = await _linuxInitialDirectory();
    final Uri? savedUri = await FilePicker.saveFile(
      dialogTitle: l.saveChatExport,
      fileName: fileName,
      bytes: data,
      mimeType: 'application/json',
      initialDirectory: initialDirectory?.path,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );

    if (savedUri == null) {
      return null;
    }

    // file_picker writes the bytes; on Linux the result is always a file URI.
    return savedUri.scheme == 'file' ? savedUri.toFilePath() : null;
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

class _PlanInfo {
  final String heroLabel;

  const _PlanInfo({required this.heroLabel});
}

class _AccountRow extends StatefulWidget {
  final Future<void> Function() onTap;

  const _AccountRow({required this.onTap});

  @override
  State<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends State<_AccountRow> {
  late Future<_PlanInfo> _planFuture;
  ProfileRecord? _profile;

  @override
  void initState() {
    super.initState();
    _planFuture = _loadPlan();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    try {
      final record = await const ProfileService().loadOrCreateProfile();
      if (!mounted) return;
      setState(() {
        _profile = record;
      });
    } catch (_) {
      // Ignore — fall back to metadata/email.
    }
  }

  Future<_PlanInfo> _loadPlan() async {
    // Cache-first — a paying user should never watch the app decide
    // whether they are a subscriber. UserStatusService refreshes behind
    // this call and notifies listeners when a newer answer lands.
    final Map<String, dynamic>? status = await UserStatusService.load();
    return _planInfoFrom(status);
  }

  static _PlanInfo _planInfoFrom(Map<String, dynamic>? status) {
    const _PlanInfo free = _PlanInfo(heroLabel: 'Free plan');
    if (status == null) return free;
    if (status['has_subscription'] != true) return free;
    final String? currentPlan = status['current_plan'] as String?;
    final String plan = (currentPlan == null || currentPlan.trim().isEmpty)
        ? 'Plus'
        : currentPlan.trim();
    return _PlanInfo(heroLabel: '$plan plan');
  }

  ({String displayName, String email}) _identity() {
    User? user;
    try {
      user = Supabase.instance.client.auth.currentUser;
    } catch (_) {
      user = null;
    }
    final email = user?.email ?? '';
    final profileName = _profile?.displayName.trim() ?? '';
    final rawDisplayName = user?.userMetadata?['display_name'];
    final rawFullName = user?.userMetadata?['full_name'];
    final displayMeta = (rawDisplayName is String) ? rawDisplayName.trim() : '';
    final fullMeta = (rawFullName is String) ? rawFullName.trim() : '';
    final metadataName = displayMeta.isNotEmpty ? displayMeta : fullMeta;
    String displayName;
    if (profileName.isNotEmpty) {
      displayName = profileName;
    } else if (metadataName.isNotEmpty) {
      displayName = metadataName;
    } else if (email.isNotEmpty) {
      displayName = email.split('@').first;
    } else {
      displayName = 'User';
    }
    return (displayName: displayName, email: email);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final id = _identity();

    // The same tile as every other row: a bare InkWell showed the page
    // background through the group and read as a different colour.
    return ExpressiveTile(
      onTap: () async {
        await widget.onTap();
        if (!mounted) return;
        await _loadProfile();
      },
      child: Padding(
        padding: EdgeInsets.zero,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: Icon(
                Icons.account_circle_outlined,
                size: 24,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    id.displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (id.email.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      id.email,
                      style: TextStyle(
                        fontSize: 13,
                        color: m3.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            ValueListenableBuilder<Map<String, dynamic>?>(
              valueListenable: UserStatusService.status,
              builder: (context, status, _) {
                if (status != null) {
                  return _PlanBadge(label: _planInfoFrom(status).heroLabel);
                }
                return FutureBuilder<_PlanInfo>(
                  future: _planFuture,
                  builder: (context, snapshot) {
                    final String label;
                    if (snapshot.connectionState != ConnectionState.done) {
                      label = '\u2026';
                    } else if (snapshot.hasData) {
                      label = snapshot.data!.heroLabel;
                    } else {
                      label = 'Free plan';
                    }
                    return _PlanBadge(label: label);
                  },
                );
              },
            ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_right, size: 20, color: m3.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  final String label;

  const _PlanBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: m3.surfaceContainerHigh,
        border: Border.all(color: m3.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: cs.onSurface,
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

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => ExpressiveRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    trailing: trailing,
    onTap: onTap,
  );
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
                  width: 26,
                  height: 26,
                  child: Icon(
                    Icons.developer_mode,
                    size: 24,
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
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: m3.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
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
                Icon(Icons.chevron_right, size: 20, color: m3.onSurfaceVariant),
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
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
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
            style: TextStyle(fontSize: 11, color: m3.onSurfaceVariant),
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

  _DashedRectPainter({required this.color, required this.radius})
    : dashWidth = 5,
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
