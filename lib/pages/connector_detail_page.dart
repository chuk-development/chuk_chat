import 'package:flutter/material.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// Full-screen detail page for a single tool, showing enable/disable,
/// model prompt editor, and parameter details.
class ConnectorDetailPage extends StatefulWidget {
  const ConnectorDetailPage({
    super.key,
    required this.tool,
    required this.toolExecutor,
    required this.displayName,
    required this.icon,
  });

  final ClientTool tool;
  final ToolExecutor toolExecutor;
  final String displayName;
  final IconData icon;

  @override
  State<ConnectorDetailPage> createState() => _ConnectorDetailPageState();
}

class _ConnectorDetailPageState extends State<ConnectorDetailPage> {
  late TextEditingController _promptController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController(
      text: widget.toolExecutor.getToolDescription(widget.tool.name),
    );
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  bool get _isEnabled => widget.toolExecutor.isToolEnabled(widget.tool.name);

  /// Web search / crawl cannot be turned off — the switch is locked on.
  bool get _isAlwaysOn => ToolExecutor.isAlwaysOnTool(widget.tool.name);

  bool get _hasCustomPrompt =>
      widget.toolExecutor.hasCustomDescription(widget.tool.name);

  String get _currentDescription =>
      widget.toolExecutor.getToolDescription(widget.tool.name);

  bool get _promptChanged =>
      _promptController.text.trim() != _currentDescription.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final iconFg = theme.resolvedIconColor;
    final primary = theme.colorScheme.primary;
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: iconFg),
          onPressed: () => Navigator.of(context).pop(),
        ),
        leadingWidth: 40,
        title: Text(
          l.back,
          style: TextStyle(color: iconFg, fontSize: 14),
        ),
        titleSpacing: 0,
      ),
      body: SettingsListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // --- Header: the tool, and its switch ---
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
                icon: widget.icon,
                tone: _isEnabled ? null : theme.m3.surfaceContainerHighest,
                title: widget.displayName,
                subtitle: _isEnabled ? l.enabled : l.disabled,
                value: _isEnabled,
                onChanged: _isAlwaysOn
                    ? null
                    : (value) async {
                        await widget.toolExecutor.setToolEnabled(
                          widget.tool.name,
                          value,
                        );
                        if (!mounted) return;
                        setState(() {});
                      },
              ),
            ],
          ),

          // --- Model prompt ---
          ExpressiveSectionHeader(l.modelPrompt),
          ExpressiveGroup(
            children: [
              ExpressiveCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.modelPromptHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.m3.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _promptController,
                      minLines: 4,
                      maxLines: 12,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(fontSize: 13, color: iconFg.lighten(0.3)),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.all(14),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (_hasCustomPrompt)
                          Text(
                            l.customPromptActive,
                            style: TextStyle(
                              color: primary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        const Spacer(),
                        if (_hasCustomPrompt)
                          TextButton(
                            onPressed: _isSaving
                                ? null
                                : () async {
                                    setState(() => _isSaving = true);
                                    await widget.toolExecutor
                                        .resetToolDescription(widget.tool.name);
                                    if (!mounted) return;
                                    _promptController.text = _currentDescription;
                                    setState(() => _isSaving = false);
                                  },
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              minimumSize: const Size(0, 34),
                            ),
                            child: Text(
                              l.reset,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        const SizedBox(width: 6),
                        FilledButton(
                          onPressed: !_promptChanged || _isSaving
                              ? null
                              : () async {
                                  setState(() => _isSaving = true);
                                  await widget.toolExecutor.setToolDescription(
                                    widget.tool.name,
                                    _promptController.text,
                                  );
                                  if (!mounted) return;
                                  setState(() => _isSaving = false);
                                },
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            minimumSize: const Size(0, 34),
                          ),
                          child: Text(
                            l.savePrompt,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          // --- Parameters ---
          if (widget.tool.parameters.isNotEmpty) ...[
            ExpressiveSectionHeader(
              l.parameters,
              trailing: ExpressiveBadge('${widget.tool.parameters.length}'),
            ),
            ExpressiveGroup(
              children: [
                for (final entry in widget.tool.parameters.entries)
                  _buildParameterRow(entry.key, entry.value.toString()),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildParameterRow(String name, String description) {
    final theme = Theme.of(context);
    return ExpressiveTile(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpressiveBadge(name, tone: theme.m3.surfaceContainerHighest),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.m3.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

}
