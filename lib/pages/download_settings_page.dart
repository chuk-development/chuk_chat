// lib/pages/download_settings_page.dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/download_preferences_service.dart';
import 'package:chuk_chat/widgets/settings_kit.dart';

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
          const SettingsSectionHeader(
            'BEHAVIOR',
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          ),
          SettingsGroupedCard(
            children: [
              SettingsRow(
                leading: SettingsLeadingIcon(
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
          const SettingsSectionHeader(
            'DEFAULT FOLDER',
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          ),
          SettingsGroupedCard(
            children: [
              SettingsRow(
                onTap: _busy ? null : _pickFolder,
                leading: SettingsLeadingIcon(
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
          SettingsInfoCard(l.downloadsInfo),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
