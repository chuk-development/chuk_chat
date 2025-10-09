import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:chuk_chat/utils/color_extensions.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static final Future<PackageInfo> _packageInfoFuture =
      PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final accent = theme.colorScheme.primary;
    final iconColor = theme.iconTheme.color ?? theme.colorScheme.onSurface;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('About', style: theme.appBarTheme.titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconColor),
      ),
      body: FutureBuilder<PackageInfo>(
        future: _packageInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            );
          }

          final PackageInfo? info = snapshot.data;
          final String? versionText = info != null
              ? _formattedVersion(info.version, info.buildNumber)
              : null;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _AboutCard(
                icon: Icons.info_outline,
                iconColor: accent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info?.appName ?? 'chuk.chat',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _AboutCard(
                icon: Icons.article_outlined,
                iconColor: accent,
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () => _openLicenses(context, info, versionText),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Open Source Licenses',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Review the licenses for every dependency included in this build.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: iconColor.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (versionText != null)
                _AboutCard(
                  icon: Icons.numbers_outlined,
                  iconColor: accent,
                  child: Text(
                    'Version $versionText',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: iconColor.withValues(alpha: 0.85),
                    ),
                  ),
                )
              else
                _AboutCard(
                  icon: Icons.help_outline,
                  iconColor: accent,
                  child: Text(
                    'Version information unavailable.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: iconColor.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              _AboutCard(
                icon: Icons.balance,
                iconColor: accent,
                child: Text(
                  '© ${DateTime.now().year} chuk.chat\nAll rights reserved.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: iconColor.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static void _openLicenses(
    BuildContext context,
    PackageInfo? info,
    String? version,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ThemedLicensePage(
          applicationName: info?.appName ?? 'chuk.chat',
          applicationVersion: version,
          applicationLegalese: '© ${DateTime.now().year} chuk.chat',
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
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({
    required this.icon,
    required this.iconColor,
    required this.child,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final Widget child;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color baseBorderColor =
        (theme.iconTheme.color ?? theme.colorScheme.onSurface).withValues(
          alpha: 0.3,
        );
    final Color cardBg = theme.scaffoldBackgroundColor.lighten(0.05);
    final BorderRadius borderRadius = BorderRadius.circular(12);

    return Card(
      color: cardBg,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(color: baseBorderColor, width: 1),
      ),
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: iconColor),
              const SizedBox(width: 16),
              Expanded(child: child),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

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
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final iconColor = theme.iconTheme.color ?? theme.colorScheme.onSurface;
    final cardBg = scaffoldBg.lighten(0.05);
    final BorderRadius borderRadius = BorderRadius.circular(12);

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Licenses', style: theme.appBarTheme.titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconColor),
      ),
      body: FutureBuilder<List<_LicensePackage>>(
        future: _licensesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.colorScheme.primary,
                ),
              ),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Unable to load licenses.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: iconColor.withValues(alpha: 0.7),
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
                  cardBg: cardBg,
                  borderRadius: borderRadius,
                  borderColor: iconColor.withValues(alpha: 0.3),
                );
              }

              final package = packages[index - 1];
              return Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _LicenseListTile(
                  package: package,
                  cardBg: cardBg,
                  borderRadius: borderRadius,
                  borderColor: iconColor.withValues(alpha: 0.2),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _LicenseListTile extends StatelessWidget {
  const _LicenseListTile({
    required this.package,
    required this.cardBg,
    required this.borderRadius,
    required this.borderColor,
  });

  final _LicensePackage package;
  final Color cardBg;
  final BorderRadius borderRadius;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = theme.iconTheme.color ?? theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;
    final String? licenseLabel = _inferLicenseName(package.license);

    return Card(
      color: cardBg,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(color: borderColor, width: 1),
      ),
      child: InkWell(
        borderRadius: borderRadius,
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
                  Icon(Icons.arrow_forward_ios, size: 16, color: iconColor),
                ],
              ),
              if (licenseLabel != null) ...[
                const SizedBox(height: 10),
                _LicenseChip(
                  label: licenseLabel,
                  background: accent.withValues(alpha: 0.15),
                  foreground: accent,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Tap to view full license text',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: iconColor.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LicenseChip extends StatelessWidget {
  const _LicenseChip({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: foreground,
            letterSpacing: 0.15,
          ),
        ),
      ),
    );
  }
}

class _LicenseHeader extends StatelessWidget {
  const _LicenseHeader({
    required this.applicationName,
    required this.cardBg,
    required this.borderRadius,
    required this.borderColor,
    this.applicationVersion,
    this.applicationLegalese,
  });

  final String applicationName;
  final String? applicationVersion;
  final String? applicationLegalese;
  final Color cardBg;
  final BorderRadius borderRadius;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = theme.iconTheme.color ?? theme.colorScheme.onSurface;

    return Card(
      color: cardBg,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(color: borderColor, width: 1),
      ),
      child: Padding(
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
                  color: iconColor.withValues(alpha: 0.75),
                ),
              ),
            ],
            if (applicationLegalese != null) ...[
              const SizedBox(height: 12),
              Text(
                applicationLegalese!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: iconColor.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
        ),
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
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final iconColor = theme.iconTheme.color ?? theme.colorScheme.onSurface;
    final cardBg = scaffoldBg.lighten(0.05);

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text(package.name, style: theme.appBarTheme.titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconColor),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          color: cardBg,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: iconColor.withValues(alpha: 0.2), width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              package.license,
              style: theme.textTheme.bodySmall?.copyWith(
                color: iconColor.withValues(alpha: 0.75),
                height: 1.4,
              ),
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
