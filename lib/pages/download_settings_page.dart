// lib/pages/download_settings_page.dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/download_preferences_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class DownloadSettingsPage extends StatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  State<DownloadSettingsPage> createState() => _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends State<DownloadSettingsPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    DownloadPreferencesService.alwaysAskNotifier.addListener(_onPrefChanged);
    DownloadPreferencesService.defaultFolderNotifier.addListener(_onPrefChanged);
    DownloadPreferencesService.ensureLoaded();
  }

  @override
  void dispose() {
    DownloadPreferencesService.alwaysAskNotifier.removeListener(_onPrefChanged);
    DownloadPreferencesService.defaultFolderNotifier
        .removeListener(_onPrefChanged);
    super.dispose();
  }

  void _onPrefChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _pickFolder() async {
    if (_busy) return;
    final l = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: l.downloadsChooseFolderDialog,
      );
      if (selected != null && selected.isNotEmpty) {
        await DownloadPreferencesService.setDefaultFolder(selected);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearFolder() async {
    await DownloadPreferencesService.setDefaultFolder(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;
    final colorScheme = theme.colorScheme;
    final folder = DownloadPreferencesService.defaultFolderNotifier.value;
    final alwaysAsk = DownloadPreferencesService.alwaysAskNotifier.value;
    final hasFolder = folder != null && folder.isNotEmpty;
    final canDisableAsk = hasFolder;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(l.downloads),
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('BEHAVIOR'),
          _GroupedCard(
            children: [
              _SettingsRow(
                leading: _LeadingIcon(
                  icon: Icons.help_outline,
                  tint: colorScheme.onSurfaceVariant,
                ),
                title: l.downloadsAlwaysAsk,
                subtitle: canDisableAsk
                    ? l.downloadsAlwaysAskHintCan
                    : l.downloadsAlwaysAskHintNoFolder,
                trailing: Switch(
                  value: alwaysAsk || !canDisableAsk,
                  onChanged: canDisableAsk
                      ? (v) => DownloadPreferencesService.setAlwaysAsk(v)
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionHeader('DEFAULT FOLDER'),
          _GroupedCard(
            children: [
              _SettingsRow(
                onTap: _busy ? null : _pickFolder,
                leading: _LeadingIcon(
                  icon: Icons.folder_outlined,
                  tint: colorScheme.primary,
                ),
                title: hasFolder ? folder : l.downloadsDefaultFolder,
                subtitle: hasFolder
                    ? l.downloadsDefaultFolder
                    : l.downloadsDefaultFolderUnset,
                trailing: hasFolder
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: l.downloadsClear,
                        onPressed: _busy ? null : _clearFolder,
                      )
                    : Icon(
                        Icons.chevron_right,
                        color: colorScheme.onSurfaceVariant,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _InfoCard(l.downloadsInfo),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
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
                        color: colorScheme.onSurfaceVariant,
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

class _InfoCard extends StatelessWidget {
  final String text;
  const _InfoCard(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final Color accent = theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: m3.onSurfaceVariant,
          height: 1.4,
        ),
      ),
    );
  }
}
