// lib/pages/download_settings_page.dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
    setState(() => _busy = true);
    try {
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose default download folder',
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
    final iconFg = theme.resolvedIconColor;
    final folder = DownloadPreferencesService.defaultFolderNotifier.value;
    final alwaysAsk = DownloadPreferencesService.alwaysAskNotifier.value;
    final hasFolder = folder != null && folder.isNotEmpty;
    final canDisableAsk = hasFolder;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Downloads'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          SwitchListTile(
            title: const Text('Always ask where to save'),
            subtitle: Text(
              canDisableAsk
                  ? 'Turn off to save directly to your default folder'
                  : 'Set a default folder below to allow turning this off',
            ),
            value: alwaysAsk || !canDisableAsk,
            onChanged: canDisableAsk
                ? (v) => DownloadPreferencesService.setAlwaysAsk(v)
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Default download folder'),
            subtitle: Text(
              hasFolder ? folder : 'Not set — every download will prompt',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: hasFolder
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Clear',
                    onPressed: _busy ? null : _clearFolder,
                  )
                : null,
            onTap: _busy ? null : _pickFolder,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'These settings apply to every download in the app — chat images, '
              'media manager exports, artifact downloads and chat backups.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
