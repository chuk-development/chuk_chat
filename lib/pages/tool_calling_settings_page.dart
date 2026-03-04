import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class ToolCallingSettingsPage extends StatefulWidget {
  const ToolCallingSettingsPage({super.key, required this.config});

  final AppShellConfig config;

  @override
  State<ToolCallingSettingsPage> createState() =>
      _ToolCallingSettingsPageState();
}

class _ToolCallingSettingsPageState extends State<ToolCallingSettingsPage> {
  static const Map<String, IconData> _toolIcons = {
    'web_search': Icons.search,
    'web_crawl': Icons.language,
    'generate_image': Icons.image_outlined,
    'fetch_image': Icons.download_outlined,
    'view_chat_images': Icons.visibility_outlined,
    'stock_data': Icons.show_chart,
    'weather': Icons.cloud_outlined,
    'search_places': Icons.place_outlined,
    'search_restaurants': Icons.restaurant,
    'geocode': Icons.pin_drop_outlined,
    'get_route': Icons.alt_route,
    'calculate': Icons.calculate,
    'get_time': Icons.access_time,
    'get_device_info': Icons.info_outline,
    'random_number': Icons.casino_outlined,
    'flip_coin': Icons.currency_exchange,
    'roll_dice': Icons.casino,
    'countdown': Icons.timer_outlined,
    'password_generator': Icons.key_outlined,
    'uuid_generator': Icons.fingerprint,
    'notes': Icons.note_outlined,
    'generate_qr': Icons.qr_code_2,
  };

  static const Map<String, String> _toolDisplayNames = {
    'web_search': 'Web Search',
    'web_crawl': 'Web Crawl',
    'generate_image': 'Image Generation',
    'fetch_image': 'Fetch Image',
    'view_chat_images': 'View Chat Images',
    'stock_data': 'Stock Data',
    'weather': 'Weather',
    'search_places': 'Place Search',
    'search_restaurants': 'Restaurant Search',
    'geocode': 'Geocoding',
    'get_route': 'Routing',
    'calculate': 'Calculator',
    'get_time': 'Clock',
    'get_device_info': 'Device Info',
    'random_number': 'Random Number',
    'flip_coin': 'Coin Flip',
    'roll_dice': 'Dice Roll',
    'countdown': 'Countdown',
    'password_generator': 'Password Generator',
    'uuid_generator': 'UUID Generator',
    'notes': 'Notes',
    'generate_qr': 'QR Generator',
  };

  late bool _toolCallingEnabled;
  late bool _toolDiscoveryMode;
  late bool _showToolCalls;
  late bool _allowMarkdownToolCalls;
  bool _mapVisualOutputEnabled = true;
  bool _chartVisualOutputEnabled = true;
  late final ToolExecutor _toolExecutor;
  bool _isLoadingToolPreferences = true;

  @override
  void initState() {
    super.initState();
    _toolCallingEnabled = widget.config.toolCallingEnabled;
    _toolDiscoveryMode = widget.config.toolDiscoveryMode;
    _showToolCalls = widget.config.showToolCalls;
    _allowMarkdownToolCalls = widget.config.allowMarkdownToolCalls;
    _toolExecutor = ToolCallHandler().toolExecutor;
    unawaited(_loadToolPreferences());
  }

  Future<void> _loadToolPreferences() async {
    await _toolExecutor.loadPreferences();
    if (!mounted) {
      return;
    }
    setState(() {
      _mapVisualOutputEnabled = _toolExecutor.mapVisualOutputEnabled;
      _chartVisualOutputEnabled = _toolExecutor.chartVisualOutputEnabled;
      _isLoadingToolPreferences = false;
    });
  }

  int _categoryOrder(ToolCategory category) {
    switch (category) {
      case ToolCategory.search:
        return 0;
      case ToolCategory.basic:
        return 1;
      case ToolCategory.map:
        return 2;
      case ToolCategory.device:
        return 3;
      case ToolCategory.spotify:
        return 4;
      case ToolCategory.bash:
        return 5;
      case ToolCategory.github:
        return 6;
      case ToolCategory.slack:
        return 7;
      case ToolCategory.google:
        return 8;
      case ToolCategory.email:
        return 9;
      case ToolCategory.nextcloud:
        return 10;
    }
  }

  String _categoryLabel(ToolCategory category) {
    switch (category) {
      case ToolCategory.search:
        return 'Search and Web';
      case ToolCategory.basic:
        return 'Utilities';
      case ToolCategory.map:
        return 'Maps and Location';
      case ToolCategory.device:
        return 'Device';
      case ToolCategory.spotify:
        return 'Spotify';
      case ToolCategory.bash:
        return 'Bash / Terminal';
      case ToolCategory.github:
        return 'GitHub';
      case ToolCategory.slack:
        return 'Slack';
      case ToolCategory.google:
        return 'Google (Calendar / Gmail)';
      case ToolCategory.email:
        return 'Email (IMAP/SMTP)';
      case ToolCategory.nextcloud:
        return 'Nextcloud';
    }
  }

  IconData _categoryIcon(ToolCategory category) {
    switch (category) {
      case ToolCategory.search:
        return Icons.travel_explore;
      case ToolCategory.basic:
        return Icons.build_outlined;
      case ToolCategory.map:
        return Icons.map_outlined;
      case ToolCategory.device:
        return Icons.devices_outlined;
      case ToolCategory.spotify:
        return Icons.music_note_outlined;
      case ToolCategory.bash:
        return Icons.terminal_outlined;
      case ToolCategory.github:
        return Icons.code_outlined;
      case ToolCategory.slack:
        return Icons.chat_outlined;
      case ToolCategory.google:
        return Icons.event_outlined;
      case ToolCategory.email:
        return Icons.email_outlined;
      case ToolCategory.nextcloud:
        return Icons.cloud_outlined;
    }
  }

  String _displayName(String toolName) {
    final mapped = _toolDisplayNames[toolName];
    if (mapped != null) {
      return mapped;
    }

    final parts = toolName.split('_');
    return parts
        .map((part) {
          if (part.isEmpty) {
            return part;
          }
          return '${part[0].toUpperCase()}${part.substring(1)}';
        })
        .join(' ');
  }

  String _trimDescription(String text, {int maxChars = 110}) {
    final cleaned = text
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length <= maxChars) {
      return cleaned;
    }
    return '${cleaned.substring(0, maxChars - 3)}...';
  }

  List<ClientTool> _visibleTools() {
    final tools = _toolExecutor.allRegisteredTools
        .where((tool) => tool.name != 'find_tools')
        .toList();

    tools.sort((a, b) {
      final categoryA =
          ToolExecutor.toolCategories[a.name] ?? ToolCategory.basic;
      final categoryB =
          ToolExecutor.toolCategories[b.name] ?? ToolCategory.basic;
      final categoryCompare = _categoryOrder(
        categoryA,
      ).compareTo(_categoryOrder(categoryB));
      if (categoryCompare != 0) {
        return categoryCompare;
      }
      return _displayName(a.name).compareTo(_displayName(b.name));
    });

    return tools;
  }

  List<Widget> _buildPerToolCards(Color scaffoldBg, Color iconFg) {
    final tools = _visibleTools();
    if (tools.isEmpty) {
      return [
        _buildInfoCard(
          context,
          'No tools are registered yet.',
          scaffoldBg,
          iconFg,
        ),
      ];
    }

    final grouped = <ToolCategory, List<ClientTool>>{};
    for (final tool in tools) {
      final category =
          ToolExecutor.toolCategories[tool.name] ?? ToolCategory.basic;
      grouped.putIfAbsent(category, () => <ClientTool>[]).add(tool);
    }

    final orderedCategories = grouped.keys.toList()
      ..sort((a, b) => _categoryOrder(a).compareTo(_categoryOrder(b)));

    final widgets = <Widget>[];
    for (final category in orderedCategories) {
      widgets.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: scaffoldBg.lighten(0.03),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: iconFg.withValues(alpha: 0.2), width: 1),
          ),
          child: Row(
            children: [
              Icon(_categoryIcon(category), size: 16, color: iconFg),
              const SizedBox(width: 8),
              Text(
                _categoryLabel(category),
                style: TextStyle(
                  color: iconFg.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
      widgets.add(const SizedBox(height: 8));

      final toolsInCategory = grouped[category]!;
      for (final tool in toolsInCategory) {
        final isEnabled = _toolExecutor.isToolEnabled(tool.name);
        final hasCustomPrompt = _toolExecutor.hasCustomDescription(tool.name);

        widgets.add(
          Card(
            color: scaffoldBg.lighten(0.05),
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
            ),
            child: ListTile(
              leading: Icon(
                _toolIcons[tool.name] ?? Icons.extension,
                color: isEnabled
                    ? Theme.of(context).colorScheme.primary
                    : iconFg.withValues(alpha: 0.45),
              ),
              title: Text(
                _displayName(tool.name),
                style: TextStyle(
                  color: Theme.of(context).textTheme.titleMedium?.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                hasCustomPrompt
                    ? '${_trimDescription(_toolExecutor.getToolDescription(tool.name))}\nCustom model prompt'
                    : _trimDescription(
                        _toolExecutor.getToolDescription(tool.name),
                      ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasCustomPrompt
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.85)
                      : iconFg.lighten(0.3),
                  fontSize: 12,
                ),
              ),
              trailing: Switch(
                value: isEnabled,
                onChanged: (value) async {
                  await _toolExecutor.setToolEnabled(tool.name, value);
                  if (!mounted) {
                    return;
                  }
                  setState(() {});
                },
              ),
              onTap: () => _showToolDetailsDialog(tool),
            ),
          ),
        );
        widgets.add(const SizedBox(height: 8));
      }

      widgets.add(const SizedBox(height: 8));
    }

    return widgets;
  }

  Future<void> _showToolDetailsDialog(ClientTool tool) async {
    final controller = TextEditingController(
      text: _toolExecutor.getToolDescription(tool.name),
    );
    bool isSaving = false;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              final effectiveDescription = _toolExecutor
                  .getToolDescription(tool.name)
                  .trim();
              final editedDescription = controller.text.trim();
              final descriptionChanged =
                  editedDescription != effectiveDescription;
              final hasCustomDescription = _toolExecutor.hasCustomDescription(
                tool.name,
              );
              final isEnabled = _toolExecutor.isToolEnabled(tool.name);

              return AlertDialog(
                title: Text(_displayName(tool.name)),
                content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enable this tool'),
                          subtitle: const Text(
                            'Disabled tools are hidden from find_tools and cannot execute',
                          ),
                          value: isEnabled,
                          onChanged: isSaving
                              ? null
                              : (value) async {
                                  await _toolExecutor.setToolEnabled(
                                    tool.name,
                                    value,
                                  );
                                  if (!mounted) {
                                    return;
                                  }
                                  setState(() {});
                                  setDialogState(() {});
                                },
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Model Prompt',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'This is the tool description shown to the model after discovery.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: controller,
                          minLines: 4,
                          maxLines: 10,
                          onChanged: (_) => setDialogState(() {}),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        if (tool.parameters.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Parameters',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          ...tool.parameters.entries.map(
                            (entry) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${entry.key}: ${entry.value}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        ],
                        if (hasCustomDescription) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Custom prompt active',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: isSaving
                        ? null
                        : () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                  if (hasCustomDescription)
                    TextButton(
                      onPressed: isSaving
                          ? null
                          : () async {
                              setDialogState(() {
                                isSaving = true;
                              });
                              await _toolExecutor.resetToolDescription(
                                tool.name,
                              );
                              controller.text = _toolExecutor
                                  .getToolDescription(tool.name);
                              if (!mounted) {
                                return;
                              }
                              setState(() {});
                              setDialogState(() {
                                isSaving = false;
                              });
                            },
                      child: const Text('Reset Prompt'),
                    ),
                  FilledButton(
                    onPressed: !descriptionChanged || isSaving
                        ? null
                        : () async {
                            setDialogState(() {
                              isSaving = true;
                            });
                            await _toolExecutor.setToolDescription(
                              tool.name,
                              controller.text,
                            );
                            if (!mounted) {
                              return;
                            }
                            setState(() {});
                            setDialogState(() {
                              isSaving = false;
                            });
                          },
                    child: const Text('Save Prompt'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _resetAllToolPreferences() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset Tool Settings?'),
        content: const Text(
          'This will re-enable all tools and reset all custom tool prompts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await _toolExecutor.resetAllToolPreferences();
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final iconFg = theme.resolvedIconColor;
    final titleTextStyle = theme.appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Tool Calling', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionHeader(
            context,
            'Engine',
            Icons.precision_manufacturing_outlined,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Enable tool calling',
            subtitle:
                'Allow the assistant to discover and execute built-in tools',
            value: _toolCallingEnabled,
            onChanged: (value) {
              setState(() {
                _toolCallingEnabled = value;
              });
              widget.config.setToolCallingEnabled(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(context, 'Behavior', Icons.tune, iconFg),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Require discovery first',
            subtitle:
                'Force find_tools before other tools are allowed in a turn',
            value: _toolDiscoveryMode,
            onChanged: _toolCallingEnabled
                ? (value) {
                    setState(() {
                      _toolDiscoveryMode = value;
                    });
                    widget.config.setToolDiscoveryMode(value);
                  }
                : null,
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Markdown tool-call fallback',
            subtitle:
                'Accept ```tool_call code blocks when models do not emit XML tags',
            value: _allowMarkdownToolCalls,
            onChanged: _toolCallingEnabled
                ? (value) {
                    setState(() {
                      _allowMarkdownToolCalls = value;
                    });
                    widget.config.setAllowMarkdownToolCalls(value);
                  }
                : null,
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(
            context,
            'Display',
            Icons.visibility_outlined,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Show tool activity in chat',
            subtitle:
                'Display running/completed tool chips in assistant messages',
            value: _showToolCalls,
            onChanged: (value) {
              setState(() {
                _showToolCalls = value;
              });
              widget.config.setShowToolCalls(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            context,
            'Tip: Leave markdown fallback enabled for best compatibility. '
            'Disable it only if you want strict XML-only tool calls.',
            scaffoldBg,
            iconFg,
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(
            context,
            'Visual Output (Non-Tool)',
            Icons.insights_outlined,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Enable map blocks (<map>)',
            subtitle:
                'Allow the model prompt to include map rendering instructions',
            value: _mapVisualOutputEnabled,
            onChanged: _toolCallingEnabled
                ? (value) async {
                    await _toolExecutor.setMapVisualOutputEnabled(value);
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _mapVisualOutputEnabled = value;
                    });
                  }
                : null,
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Enable chart blocks (<chart>)',
            subtitle:
                'Allow the model prompt to include chart rendering instructions',
            value: _chartVisualOutputEnabled,
            onChanged: _toolCallingEnabled
                ? (value) async {
                    await _toolExecutor.setChartVisualOutputEnabled(value);
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _chartVisualOutputEnabled = value;
                    });
                  }
                : null,
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(
            context,
            'Per-Tool Controls',
            Icons.extension_outlined,
            iconFg,
          ),
          const SizedBox(height: 12),
          if (_isLoadingToolPreferences)
            _buildInfoCard(
              context,
              'Loading tool settings...',
              scaffoldBg,
              iconFg,
            )
          else
            ..._buildPerToolCards(scaffoldBg, iconFg),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _isLoadingToolPreferences
                  ? null
                  : _resetAllToolPreferences,
              icon: const Icon(Icons.restore),
              label: const Text('Reset All Tool Preferences'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
    Color iconFg,
  ) {
    return Row(
      children: [
        Icon(icon, color: iconFg, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).textTheme.titleMedium?.color,
          ),
        ),
      ],
    );
  }

  Widget _buildToggleCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required Color scaffoldBg,
    required Color iconFg,
  }) {
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).textTheme.titleMedium?.color,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: iconFg.lighten(0.3), fontSize: 13),
        ),
        value: value,
        onChanged: onChanged,
        activeTrackColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.5),
        activeThumbColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context,
    String text,
    Color scaffoldBg,
    Color iconFg,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scaffoldBg.lighten(0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: iconFg.withValues(alpha: 0.2), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: iconFg.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: iconFg.withValues(alpha: 0.8),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
