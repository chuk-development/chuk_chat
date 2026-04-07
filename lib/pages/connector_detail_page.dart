import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

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
    final titleColor = theme.textTheme.titleMedium?.color;
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
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        children: [
          // --- Header ---
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: scaffoldBg.lighten(0.07),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: iconFg.withValues(alpha: 0.12)),
                ),
                child: Icon(
                  widget.icon,
                  size: 28,
                  color: _isEnabled ? primary : iconFg.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.displayName,
                      style: TextStyle(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isEnabled ? l.enabled : l.disabled,
                      style: TextStyle(
                        color: _isEnabled
                            ? Colors.green.shade400
                            : iconFg.withValues(alpha: 0.5),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _isEnabled,
                onChanged: (value) async {
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

          const SizedBox(height: 28),
          _divider(iconFg),
          const SizedBox(height: 20),

          // --- Model Prompt ---
          Text(
            l.modelPrompt,
            style: TextStyle(
              color: titleColor,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l.modelPromptHint,
            style: TextStyle(color: iconFg.lighten(0.2), fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            minLines: 4,
            maxLines: 12,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 13, color: iconFg.lighten(0.3)),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.all(14),
              enabledBorder: OutlineInputBorder(
                borderSide:
                    BorderSide(color: iconFg.withValues(alpha: 0.2)),
                borderRadius: BorderRadius.circular(10),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: primary),
                borderRadius: BorderRadius.circular(10),
              ),
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
                  child:
                      Text(l.reset, style: const TextStyle(fontSize: 13)),
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
                child: Text(l.savePrompt,
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),

          if (widget.tool.parameters.isNotEmpty) ...[
            const SizedBox(height: 24),
            _divider(iconFg),
            const SizedBox(height: 20),

            // --- Parameters ---
            Row(
              children: [
                Text(
                  l.parameters,
                  style: TextStyle(
                    color: titleColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scaffoldBg.lighten(0.07),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${widget.tool.parameters.length}',
                    style: TextStyle(
                      color: iconFg.lighten(0.2),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...widget.tool.parameters.entries.map(
              (entry) => _buildParameterRow(
                entry.key,
                entry.value.toString(),
                scaffoldBg,
                iconFg,
              ),
            ),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildParameterRow(
    String name,
    String description,
    Color scaffoldBg,
    Color iconFg,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scaffoldBg.lighten(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: iconFg.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: scaffoldBg.lighten(0.08),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              name,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                color: iconFg.lighten(0.2),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(Color iconFg) {
    return Container(
      height: 1,
      color: iconFg.withValues(alpha: 0.1),
    );
  }
}
