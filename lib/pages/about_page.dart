import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/update_check_service.dart';
import 'package:chuk_chat/utils/build_info.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();

  static void _openLicenses(
    BuildContext context,
    PackageInfo? info,
    String? version,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ThemedLicensePage(
          applicationName: info?.appName ?? 'Chuk Chat',
          applicationVersion: version,
          applicationLegalese: '© ${DateTime.now().year} Chuk Chat',
        ),
      ),
    );
  }

  static String _formattedVersion(String version, String buildNumber) {
    final String trimmedBuild = buildNumber.trim();
    if (trimmedBuild.isEmpty || trimmedBuild == version) {
      return version;
    }
    return '$version (build $trimmedBuild)';
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
  static final Future<PackageInfo> _packageInfoFuture =
      PackageInfo.fromPlatform();

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
      body: FutureBuilder<PackageInfo>(
        future: _packageInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final PackageInfo? info = snapshot.data;
          final String? versionText = info != null
              ? AboutPage._formattedVersion(info.version, info.buildNumber)
              : null;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Hero header — centered icon, app name, version.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                child: ValueListenableBuilder<UpdateInfo?>(
                  valueListenable: UpdateCheckService.updateAvailable,
                  builder: (context, updateInfo, _) {
                    return Column(
                      children: [
                        GestureDetector(
                          onTap: _handleVersionTap,
                          child: Container(
                            width: 88,
                            height: 88,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              color: m3.surfaceContainerHigh,
                            ),
                            child: SvgPicture.asset(
                              'assets/logo.svg',
                              colorFilter: ColorFilter.mode(
                                colorScheme.onSurface,
                                BlendMode.srcIn,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          info?.appName ?? l.chukChat,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w500,
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
                          Text(
                            l.versionUnavailable,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: m3.onSurfaceVariant,
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
                        const SizedBox(height: 12),
                        if (updateInfo != null)
                          Semantics(
                            button: true,
                            label: l.updateAvailable(updateInfo.latestVersion),
                            child: GestureDetector(
                              onTap: UpdateCheckService.launchDownload,
                              child: _Badge(
                                l.updateAvailable(updateInfo.latestVersion),
                                tone: _BadgeTone.primary,
                                icon: Icons.system_update_outlined,
                              ),
                            ),
                          )
                        else
                          _Badge(
                            'Up to date',
                            tone: _BadgeTone.success,
                            icon: Icons.check_circle_outline,
                          ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),

              const _SectionHeader('LINKS'),
              _GroupedCard(
                children: [
                  _SettingsRow(
                    onTap: () =>
                        AboutPage._openLicenses(context, info, versionText),
                    leading: _LeadingIcon(
                      icon: Icons.article_outlined,
                      tint: m3.onSurfaceVariant,
                    ),
                    title: l.openSourceLicenses,
                    subtitle: l.openSourceLicensesSubtitle,
                    trailing: Icon(
                      Icons.chevron_right,
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                  _SettingsRow(
                    onTap: () =>
                        AboutPage._launchUrl('https://chuk.chat/en/terms/'),
                    leading: _LeadingIcon(
                      icon: Icons.description_outlined,
                      tint: m3.onSurfaceVariant,
                    ),
                    title: l.termsOfService,
                    trailing: Icon(
                      Icons.north_east,
                      size: 18,
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                  _SettingsRow(
                    onTap: () =>
                        AboutPage._launchUrl('https://chuk.chat/en/privacy/'),
                    leading: _LeadingIcon(
                      icon: Icons.lock_outline,
                      tint: m3.onSurfaceVariant,
                    ),
                    title: l.privacyPolicy,
                    trailing: Icon(
                      Icons.north_east,
                      size: 18,
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                  _SettingsRow(
                    onTap: () => AboutPage._launchUrl(
                      'https://github.com/chuk-development/chuk_chat',
                    ),
                    leading: _LeadingIcon(
                      icon: Icons.code,
                      tint: m3.onSurfaceVariant,
                    ),
                    title: 'GitHub',
                    subtitle: 'chuk-development/chuk_chat',
                    trailing: Icon(
                      Icons.north_east,
                      size: 18,
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l.copyrightYear(DateTime.now().year.toString()),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: m3.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(height: 16),
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

          return ListView.builder(
            padding: const EdgeInsets.all(16),
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
                padding: const EdgeInsets.only(top: 12),
                child: _LicenseListTile(package: package),
              );
            },
          );
        },
      ),
    );
  }
}

class _LicenseListTile extends StatelessWidget {
  const _LicenseListTile({required this.package});

  final _LicensePackage package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final String? licenseLabel = _inferLicenseName(package.license);

    return Material(
      color: m3.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _LicenseDetailPage(package: package),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      package.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: m3.onSurfaceVariant,
                  ),
                ],
              ),
              if (licenseLabel != null) ...[
                const SizedBox(height: 10),
                _Badge(
                  licenseLabel,
                  tone: _BadgeTone.primary,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(context)!.tapToViewLicense,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
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

    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(16),
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
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: m3.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.all(16),
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

// ─── Reusable private pieces ─────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          color: colorScheme.primary,
        ),
      ),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupedCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;

    final List<Widget> rows = [];
    for (int i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 56),
          child: Divider(height: 1, thickness: 1, color: m3.outlineVariant),
        ));
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.m3.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _LeadingIcon extends StatelessWidget {
  final IconData icon;
  final Color tint;
  const _LeadingIcon({required this.icon, required this.tint});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Center(
        child: Icon(icon, size: 22, color: tint),
      ),
    );
  }
}

enum _BadgeTone { primary, success, warn, neutral }

class _Badge extends StatelessWidget {
  final String label;
  final _BadgeTone tone;
  final IconData? icon;
  const _Badge(this.label, {this.tone = _BadgeTone.neutral, this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    late Color bg;
    late Color fg;
    switch (tone) {
      case _BadgeTone.primary:
        bg = m3.primaryContainer;
        fg = m3.onPrimaryContainer;
        break;
      case _BadgeTone.success:
        bg = m3.successContainer;
        fg = m3.onSuccessContainer;
        break;
      case _BadgeTone.warn:
        bg = m3.warningContainer;
        fg = m3.onWarningContainer;
        break;
      case _BadgeTone.neutral:
        bg = m3.surfaceContainerHigh;
        fg = m3.onSurfaceVariant;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.15,
            ),
          ),
        ],
      ),
    );
  }
}
