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
    final iconFg = theme.resolvedIconColor;
    final folder = DownloadPreferencesService.defaultFolderNotifier.value;
    final alwaysAsk = DownloadPreferencesService.alwaysAskNotifier.value;
    final hasFolder = folder != null && folder.isNotEmpty;
    final canDisableAsk = hasFolder;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(l.downloads),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          SwitchListTile(
            title: Text(l.downloadsAlwaysAsk),
            subtitle: Text(
              canDisableAsk
                  ? l.downloadsAlwaysAskOn
                  : l.downloadsAlwaysAskOff,
            ),
            value: alwaysAsk || !canDisableAsk,
            onChanged: canDisableAsk
                ? (v) => DownloadPreferencesService.setAlwaysAsk(v)
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(l.downloadsDefaultFolder),
            subtitle: Text(
              hasFolder ? folder : l.downloadsDefaultFolderUnset,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: hasFolder
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: l.downloadsClear,
                    onPressed: _busy ? null : _clearFolder,
                  )
                : null,
            onTap: _busy ? null : _pickFolder,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l.downloadsInfo,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
