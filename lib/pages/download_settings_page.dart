// lib/pages/download_settings_page.dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/download_preferences_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

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
    final m3 = theme.m3;
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const ExpressiveSectionHeader('Behavior'),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
                icon: Icons.help_outline,
                title: l.downloadsAlwaysAsk,
                subtitle: canDisableAsk
                    ? l.downloadsAlwaysAskHintCan
                    : l.downloadsAlwaysAskHintNoFolder,
                // Without a default folder there is nowhere to save to, so
                // asking is the only thing the app can do.
                value: alwaysAsk || !canDisableAsk,
                onChanged: canDisableAsk
                    ? (v) => DownloadPreferencesService.setAlwaysAsk(v)
                    : null,
              ),
            ],
          ),

          const ExpressiveSectionHeader('Default folder'),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.folder_outlined,
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
                        size: 20,
                        color: m3.onSurfaceVariant,
                      ),
                onTap: _busy ? null : _pickFolder,
              ),
            ],
          ),
          const SizedBox(height: 16),
          ExpressiveInfoCard(text: l.downloadsInfo),
        ],
      ),
    );
  }
}
