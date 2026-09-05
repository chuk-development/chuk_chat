// COWORK ADAPTATION (chuk_chat/lib/pages/about_page.dart), line by line:
//  - dropped `package:package_info_plus` — not in CoWork's pubspec. The app
//    name is the constant [AboutPage.appName] and the version comes from
//    `--dart-define=APP_VERSION` ([AboutPage.appVersion]).
//  - dropped `package:flutter_svg` + `assets/logo.svg` — CoWork has no such
//    vector asset (see widgets/brand_wordmark.dart); the hero shows an icon.
//  - dropped `services/update_check_service.dart` and the update badge — it
//    polls the chuk_chat release feed, which CoWork does not have.
//  - branding: 'Chuk Chat' -> 'CoWork' in the licences page, the hero name and
//    the link rows; terms/privacy rows removed (no such pages yet), GitHub row
//    points at the CoWork repository.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cowork/widgets/settings_list_view.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/services/developer_options_service.dart';
import 'package:cowork/utils/build_info.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/expressive_settings.dart';
import 'package:cowork/widgets/nice_snackbar.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  /// COWORK ADAPTATION: replaces `PackageInfo.appName`.
  static const String appName = 'CoWork';

  /// COWORK ADAPTATION: replaces `PackageInfo.version`. Empty when the build
  /// did not pass `--dart-define=APP_VERSION=…`; the UI then hides the line.
  static const String appVersion = String.fromEnvironment('APP_VERSION');

  @override
  State<AboutPage> createState() => _AboutPageState();

  static void _openLicenses(BuildContext context, String? version) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ThemedLicensePage(
          applicationName: appName,
          applicationVersion: version,
          applicationLegalese: '© ${DateTime.now().year} $appName',
        ),
      ),
    );
  }

  static Future<void> _launchUrl(String url) async {
    final Uri uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (kDebugMode) {
        debugPrint('Could not launch $url');
      }
    }
  }
}

class _AboutPageState extends State<AboutPage> {
  int _remainingDeveloperTaps = 3;
  DateTime? _lastDeveloperTapAt;

  Future<void> _handleVersionTap() async {
    await DeveloperOptionsService.initialize();
    if (!mounted) return;

    final l = AppLocalizations.of(context)!;

    if (DeveloperOptionsService.enabledNotifier.value) {
      NiceSnackBar.show(
        context,
        l.devOptionsAlreadyEnabled,
        duration: const Duration(seconds: 1),
      );
      return;
    }

    final now = DateTime.now();
    if (_lastDeveloperTapAt == null ||
        now.difference(_lastDeveloperTapAt!) > const Duration(seconds: 4)) {
      _remainingDeveloperTaps = 3;
    }
    _lastDeveloperTapAt = now;
    _remainingDeveloperTaps -= 1;

    if (_remainingDeveloperTaps <= 0) {
      await DeveloperOptionsService.setEnabled(true);
      if (!mounted) return;
      setState(() {
        _remainingDeveloperTaps = 3;
      });
      NiceSnackBar.show(
        context,
        l.devOptionsEnabled,
        duration: const Duration(seconds: 2),
      );
      return;
    }

    if (!mounted) return;
    final taps = _remainingDeveloperTaps;
    NiceSnackBar.show(
      context,
      l.devOptionsTaps(taps),
      duration: const Duration(seconds: 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(l.about),
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: Builder(
        builder: (context) {
          // COWORK ADAPTATION: upstream awaits `PackageInfo.fromPlatform()`
          // here. CoWork reads the build-time constants, so there is nothing
          // to await and no loading spinner.
          final String? versionText =
              AboutPage.appVersion.trim().isEmpty
                  ? null
                  : AboutPage.appVersion.trim();

          return SettingsListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              // Hero header — the icon, the name, the version.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _handleVersionTap,
                      child: Container(
                        width: 88,
                        height: 88,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            kExpressiveOuterRadius,
                          ),
                          color: m3.surfaceContainerHigh,
                        ),
                        // COWORK ADAPTATION: upstream draws assets/logo.svg.
                        child: Icon(
                          Icons.diversity_3_outlined,
                          size: 44,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      AboutPage.appName,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (versionText != null) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: _handleVersionTap,
                        child: Text(
                          l.versionText(versionText),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: _handleVersionTap,
                        child: Text(
                          l.versionUnavailable,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    if (BuildInfo.formatted() != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        l.builtOn(BuildInfo.formatted()!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: m3.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    // COWORK ADAPTATION: upstream shows an update badge fed by
                    // UpdateCheckService. CoWork has no release feed, so the
                    // badge states what this build really is.
                    ExpressiveBadge(
                      'Self-hosted build',
                      tone: m3.successContainer,
                      icon: Icons.dns_outlined,
                    ),
                  ],
                ),
              ),

              const ExpressiveSectionHeader('Links'),
              ExpressiveGroup(
                children: [
                  ExpressiveRow(
                    icon: Icons.article_outlined,
                    title: l.openSourceLicenses,
                    subtitle: l.openSourceLicensesSubtitle,
                    trailing: Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: m3.onSurfaceVariant,
                    ),
                    onTap: () => AboutPage._openLicenses(context, versionText),
                  ),
                  ExpressiveRow(
                    icon: Icons.code,
                    title: 'GitHub',
                    subtitle: 'chukfinley/cowork',
                    trailing: Icon(
                      Icons.north_east,
                      size: 18,
                      color: m3.onSurfaceVariant,
                    ),
                    onTap: () => AboutPage._launchUrl(
                      'https://github.com/chukfinley/cowork',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                l.copyrightYear(DateTime.now().year.toString()),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Themed licenses page (unchanged behavior, restyled) ────────────────

class _ThemedLicensePage extends StatefulWidget {
  const _ThemedLicensePage({
    required this.applicationName,
    this.applicationVersion,
    this.applicationLegalese,
  });

  final String applicationName;
  final String? applicationVersion;
  final String? applicationLegalese;

  @override
  State<_ThemedLicensePage> createState() => _ThemedLicensePageState();
}

class _ThemedLicensePageState extends State<_ThemedLicensePage> {
  late final Future<List<_LicensePackage>> _licensesFuture = _loadLicenses();

  Future<List<_LicensePackage>> _loadLicenses() async {
    final List<_LicensePackage> packages = [];
    await for (final LicenseEntry entry in LicenseRegistry.licenses) {
      if (entry.packages.isEmpty) {
        continue;
      }
      final buffer = StringBuffer();
      for (final paragraph in entry.paragraphs) {
        final String text = paragraph.text.trimRight();
        if (text.isEmpty) continue;
        final String indent = ' ' * (paragraph.indent * 2);
        buffer.writeln('$indent$text');
        buffer.writeln();
      }
      final licenseText = buffer.toString().trim();
      for (final packageName in entry.packages) {
        packages.add(_LicensePackage(packageName, licenseText));
      }
    }
    packages.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return packages;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;

    final l = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(l.licenses),
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: FutureBuilder<List<_LicensePackage>>(
        future: _licensesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                l.unableToLoadLicenses,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
            );
          }

          final packages = snapshot.data ?? const <_LicensePackage>[];

          // One tile per package. The list is long enough that a builder
          // matters, so every package is its own group of one.
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: packages.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return _LicenseHeader(
                  applicationName: widget.applicationName,
                  applicationVersion: widget.applicationVersion,
                  applicationLegalese: widget.applicationLegalese,
                );
              }

              final package = packages[index - 1];
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ExpressiveGroup(
                  children: [_LicenseTile(package: package)],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _LicenseTile extends StatelessWidget {
  const _LicenseTile({required this.package});

  final _LicensePackage package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final String? licenseLabel = _inferLicenseName(package.license);

    return ExpressiveRow(
      title: package.name,
      subtitle: AppLocalizations.of(context)!.tapToViewLicense,
      trailing: licenseLabel == null
          ? Icon(Icons.chevron_right, size: 20, color: m3.onSurfaceVariant)
          : ExpressiveBadge(licenseLabel, tone: m3.primaryContainer),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _LicenseDetailPage(package: package),
          ),
        );
      },
    );
  }
}

class _LicenseHeader extends StatelessWidget {
  const _LicenseHeader({
    required this.applicationName,
    this.applicationVersion,
    this.applicationLegalese,
  });

  final String applicationName;
  final String? applicationVersion;
  final String? applicationLegalese;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;

    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            applicationName,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (applicationVersion != null) ...[
            const SizedBox(height: 8),
            Text(
              applicationVersion!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            ),
          ],
          if (applicationLegalese != null) ...[
            const SizedBox(height: 12),
            Text(
              applicationLegalese!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LicensePackage {
  const _LicensePackage(this.name, this.license);

  final String name;
  final String license;
}

class _LicenseDetailPage extends StatelessWidget {
  const _LicenseDetailPage({required this.package});

  final _LicensePackage package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(package.name),
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: ExpressiveCard(
          child: SelectableText(
            package.license,
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}

String? _inferLicenseName(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('apache license')) {
    if (lower.contains('apache license, version 2.0')) {
      return 'Apache License 2.0';
    }
    return 'Apache License';
  }
  if (lower.contains('mit license')) {
    return 'MIT License';
  }
  if (lower.contains('bsd 2-clause') || lower.contains('bsd 3-clause')) {
    return 'BSD License';
  }
  if (lower.contains('gnu general public license') &&
      lower.contains('lesser')) {
    return 'LGPL';
  }
  if (lower.contains('gnu general public license')) {
    if (lower.contains('version 3')) {
      return 'GPLv3';
    }
    if (lower.contains('version 2')) {
      return 'GPLv2';
    }
    return 'GPL';
  }
  if (lower.contains('mozilla public license')) {
    return 'MPL';
  }
  if (lower.contains('creative commons')) {
    return 'Creative Commons';
  }
  return null;
}
