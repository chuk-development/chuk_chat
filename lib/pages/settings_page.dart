// lib/pages/settings_page.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cowork/widgets/settings_list_view.dart';
import 'package:cowork/model_selector_page.dart';
import 'package:cowork/models/app_shell_config.dart';
import 'package:cowork/services/developer_options_service.dart';
import 'package:cowork/pages/theme_page.dart';
import 'package:cowork/pages/customization_page.dart';
import 'package:cowork/pages/settings/mcp_connectors_page.dart';
import 'package:cowork/pages/settings/developer_settings_page.dart';
import 'package:cowork/pages/settings/embedding_settings_page.dart';
import 'package:cowork/pages/settings/herenow_settings_page.dart';
import 'package:cowork/pages/secrets_settings_page.dart';
import 'package:cowork/pages/automations_page.dart';
import 'package:cowork/widgets/expressive_settings.dart';
import 'package:cowork/pages/skills_settings_page.dart';
import 'package:cowork/platform_config.dart';
import 'package:cowork/pages/account_settings_page.dart';
import 'package:cowork/pages/about_page.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/diagnostics_log_service.dart';
import 'package:cowork/services/tour_key_registry.dart';
// ignore: unused_import
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/l10n/app_localizations.dart';

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
      body: SettingsListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          ExpressiveSectionHeader('Account'),
          ExpressiveGroup(
            children: [
              _SettingsRow(
                icon: Icons.person_outline,
                title: 'Account',
                subtitle: 'Who is signed in on this device',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AccountSettingsPage(),
                    ),
                  );
                },
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
              if (kFeatureMcp && !kIsWeb)
                _SettingsRow(
                  icon: Icons.extension_outlined,
                  title: l.connectors,
                  subtitle: l.connectorsSubtitle,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const McpConnectorsPage(),
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
            ],
          ),

          // CoWork's own destinations. They have no chuk counterpart because
          // they are about the machine the agent runs on, not about a hosted
          // chat account.
          ExpressiveSectionHeader('CoWork'),
          ExpressiveGroup(
            children: [
              _SettingsRow(
                icon: Icons.place_outlined,
                title: 'here.now',
                subtitle: 'Let a coworker publish a page on your behalf',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const HereNowSettingsPage(),
                    ),
                  );
                },
              ),
              _SettingsRow(
                icon: Icons.memory_outlined,
                title: 'Embedding',
                subtitle: 'The model that indexes what the agent reads',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const EmbeddingSettingsPage(),
                    ),
                  );
                },
              ),
              _SettingsRow(
                icon: Icons.key_outlined,
                title: 'API Keys',
                subtitle: 'Keys the agent can use but never read',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SecretsSettingsPage(),
                    ),
                  );
                },
              ),
              _SettingsRow(
                icon: Icons.schedule_outlined,
                title: 'Automations',
                subtitle: 'Schedules and watchers your coworkers set up',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AutomationsPage(),
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

          ExpressiveSectionHeader('System'),
          ExpressiveGroup(
            children: [
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
                    builder: (_) => const DeveloperSettingsPage(),
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
              'CoWork',
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

}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => ExpressiveRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
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
