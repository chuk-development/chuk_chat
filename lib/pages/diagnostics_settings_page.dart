// lib/pages/diagnostics_settings_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';
import 'package:share_plus/share_plus.dart';
import 'package:chuk_chat/widgets/settings_kit.dart';

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
    final l = AppLocalizations.of(context)!;
    NiceSnackBar.show(
      context,
      value ? l.devOptionsEnabled : l.devOptionsDisabledMsg,
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
    final l = AppLocalizations.of(context)!;
    NiceSnackBar.show(
      context,
      value ? l.diagnosticsEnabled : l.diagnosticsDisabled,
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
    final l = AppLocalizations.of(context)!;
    NiceSnackBar.show(context, l.copiedRecentLogs);
  }

  Future<void> _copyFocusedModelMenuDebug() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final report = await DiagnosticsLogService.readModelMenuDebugReport();
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      if (report.trim().isEmpty) {
        NiceSnackBar.show(context, l.noFocusedDebugData);
        setState(() => _busy = false);
        return;
      }
      await Clipboard.setData(ClipboardData(text: report));
      if (!mounted) return;
      NiceSnackBar.show(context, l.copiedFocusedDebug);
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      final l = AppLocalizations.of(context)!;
      NiceSnackBar.showError(context, l.failedFocusedDebug(error.toString()));
    }
  }

  Future<void> _shareLogFile() async {
    final path = await DiagnosticsLogService.getLogFilePath();
    if (path == null) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      NiceSnackBar.show(context, l.noDiagnosticsLog);
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      NiceSnackBar.show(context, l.diagnosticsLogNotFound);
      return;
    }

    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], subject: 'Chuk Chat diagnostics log'),
      );
    } catch (error) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      NiceSnackBar.showError(context, l.failedToShareLog(error.toString()));
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
      final l = AppLocalizations.of(context)!;
      NiceSnackBar.show(context, l.diagnosticsLogCleared);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      final l = AppLocalizations.of(context)!;
      NiceSnackBar.showError(context, l.failedToClearLog(error.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.developerOptions),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SettingsInfoCard(
                  'Advanced options — mainly for debugging and support.',
                  tone: SettingsInfoTone.warn,
                  icon: Icons.warning_amber_rounded,
                ),
                const SettingsSectionHeader(
                  'Feature Toggles',
                  padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
                ),
                SettingsGroupedCard(
                  children: [
                    _SwitchRow(
                      icon: Icons.developer_mode,
                      title: l.devOptionsToggle,
                      subtitle: l.devOptionsToggleSubtitle,
                      value: _developerOptionsEnabled,
                      onChanged: _busy ? null : _setDeveloperOptionsEnabled,
                    ),
                    _SwitchRow(
                      icon: Icons.description_outlined,
                      title: l.enableDiagnosticsLogging,
                      subtitle: l.enableDiagnosticsSubtitle,
                      value: _enabled,
                      onChanged: _busy || !_developerOptionsEnabled
                          ? null
                          : _setEnabled,
                    ),
                  ],
                ),
                const SettingsSectionHeader(
                  'Log File',
                  padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: m3.surfaceContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: m3.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(
                          _logPath ?? l.notInitializedYet,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy || !_developerOptionsEnabled
                                ? null
                                : _refreshLogs,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: Text(l.refresh),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                _busy ||
                                    !_developerOptionsEnabled ||
                                    _logPreview.isEmpty
                                ? null
                                : _copyRecentLogs,
                            icon: const Icon(Icons.copy, size: 18),
                            label: Text(l.copyRecent),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy || !_developerOptionsEnabled
                                ? null
                                : _copyFocusedModelMenuDebug,
                            icon: const Icon(
                              Icons.bug_report_outlined,
                              size: 18,
                            ),
                            label: Text(l.copyFocusedDebug),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy || !_developerOptionsEnabled
                                ? null
                                : _shareLogFile,
                            icon: const Icon(Icons.ios_share, size: 18),
                            label: Text(l.shareFile),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy || !_developerOptionsEnabled
                                ? null
                                : _clearLogs,
                            icon: Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: cs.error,
                            ),
                            label: Text(
                              l.clear,
                              style: TextStyle(color: cs.error),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: cs.error,
                              side: BorderSide(
                                color: cs.error.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SettingsSectionHeader(
                  'Recent Log Lines',
                  padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
                ),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 160),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: m3.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: m3.outlineVariant),
                  ),
                  child: SelectableText(
                    !_developerOptionsEnabled
                        ? l.devOptionsDisabledMsg
                        : _logPreview.isEmpty
                        ? l.noLogsYet
                        : _logPreview,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.5,
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ───────── private shared widgets ─────────

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 24, color: m3.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: m3.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
