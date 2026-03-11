// lib/pages/diagnostics_settings_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:share_plus/share_plus.dart';

class DeveloperOptionsPage extends StatefulWidget {
  const DeveloperOptionsPage({super.key});

  @override
  State<DeveloperOptionsPage> createState() => _DeveloperOptionsPageState();
}

class _DeveloperOptionsPageState extends State<DeveloperOptionsPage> {
  bool _loading = true;
  bool _developerOptionsEnabled = false;
  bool _enabled = false;
  bool _busy = false;
  String _logPreview = '';
  String? _logPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final developerEnabled = await DeveloperOptionsService.isEnabled();
    final enabled = await DiagnosticsLogService.isEnabled();
    final path = await DiagnosticsLogService.getLogFilePath();
    final preview = await DiagnosticsLogService.readRecentLogs(maxLines: 180);
    if (!mounted) return;
    setState(() {
      _developerOptionsEnabled = developerEnabled;
      _enabled = enabled;
      _logPath = path;
      _logPreview = preview;
      _loading = false;
    });
  }

  Future<void> _setDeveloperOptionsEnabled(bool value) async {
    setState(() => _busy = true);
    await DeveloperOptionsService.setEnabled(value);
    if (!value && _enabled) {
      await DiagnosticsLogService.setEnabled(false);
    }
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value ? 'Developer options enabled' : 'Developer options disabled',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (!value) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _busy = true);
    await DiagnosticsLogService.setEnabled(value);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Diagnostics logging enabled'
              : 'Diagnostics logging disabled',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _refreshLogs() async {
    setState(() => _busy = true);
    final path = await DiagnosticsLogService.getLogFilePath();
    final preview = await DiagnosticsLogService.readRecentLogs(maxLines: 180);
    if (!mounted) return;
    setState(() {
      _logPath = path;
      _logPreview = preview;
      _busy = false;
    });
  }

  Future<void> _copyRecentLogs() async {
    if (_logPreview.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _logPreview));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied recent logs to clipboard'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _shareLogFile() async {
    final path = await DiagnosticsLogService.getLogFilePath();
    if (path == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No diagnostics log available'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diagnostics log file not found'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], subject: 'Chuk Chat diagnostics log'),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to share diagnostics log: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _clearLogs() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await DiagnosticsLogService.clearLogs();
      final path = await DiagnosticsLogService.getLogFilePath();
      final preview = await DiagnosticsLogService.readRecentLogs(maxLines: 180);
      if (!mounted) return;
      setState(() {
        _logPath = path;
        _logPreview = preview;
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diagnostics log cleared'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to clear diagnostics log: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final iconFg = theme.resolvedIconColor;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: const Text('Developer Options'),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: scaffoldBg.lighten(0.05),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                  ),
                  child: SwitchListTile(
                    value: _developerOptionsEnabled,
                    onChanged: _busy ? null : _setDeveloperOptionsEnabled,
                    title: const Text('Developer options'),
                    subtitle: const Text(
                      'Unlock diagnostics and debug tools. Disable to hide all developer-only settings.',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: scaffoldBg.lighten(0.05),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                  ),
                  child: SwitchListTile(
                    value: _enabled,
                    onChanged: _busy || !_developerOptionsEnabled
                        ? null
                        : _setEnabled,
                    title: const Text('Enable diagnostics logging'),
                    subtitle: const Text(
                      'Works in release builds. Logs app/runtime metadata for troubleshooting lag and tray issues.',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: scaffoldBg.lighten(0.05),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Log file',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          _logPath ?? 'Not initialized yet',
                          style: TextStyle(
                            fontSize: 12,
                            color: iconFg.withValues(alpha: 0.75),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _busy || !_developerOptionsEnabled
                                  ? null
                                  : _refreshLogs,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Refresh'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _busy ||
                                      !_developerOptionsEnabled ||
                                      _logPreview.isEmpty
                                  ? null
                                  : _copyRecentLogs,
                              icon: const Icon(Icons.copy, size: 18),
                              label: const Text('Copy Recent'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy || !_developerOptionsEnabled
                                  ? null
                                  : _shareLogFile,
                              icon: const Icon(Icons.ios_share, size: 18),
                              label: const Text('Share File'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy || !_developerOptionsEnabled
                                  ? null
                                  : _clearLogs,
                              icon: const Icon(Icons.delete_outline, size: 18),
                              label: const Text('Clear'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  color: scaffoldBg.lighten(0.05),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Recent log lines',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(minHeight: 140),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: scaffoldBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: iconFg.withValues(alpha: 0.2),
                            ),
                          ),
                          child: SelectableText(
                            !_developerOptionsEnabled
                                ? 'Developer options disabled.'
                                : _logPreview.isEmpty
                                ? 'No logs yet. Enable diagnostics logging and use the app to collect data.'
                                : _logPreview,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: iconFg.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
