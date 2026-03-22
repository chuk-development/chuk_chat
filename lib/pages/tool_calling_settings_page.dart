import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/pages/connector_detail_page.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/tool_handlers/platform_tools.dart' as platform_tools;
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
    'crypto_data': Icons.currency_bitcoin,
    'weather': Icons.cloud_outlined,
    'search_places': Icons.place_outlined,
    'search_restaurants': Icons.restaurant,
    'geocode': Icons.pin_drop_outlined,
    'get_route': Icons.alt_route,
    'calculate': Icons.calculate,
    'get_time': Icons.access_time,
    'random_number': Icons.casino_outlined,
    'flip_coin': Icons.currency_exchange,
    'roll_dice': Icons.casino,
    'countdown': Icons.timer_outlined,
    'password_generator': Icons.key_outlined,
    'uuid_generator': Icons.fingerprint,
    'notes': Icons.note_outlined,
    'generate_qr': Icons.qr_code_2,
    'whoop': Icons.monitor_heart_outlined,
  };

  static const Map<String, String> _toolDisplayNames = {
    'web_search': 'Web Search',
    'web_crawl': 'Web Crawl',
    'generate_image': 'Image Generation',
    'fetch_image': 'Fetch Image',
    'view_chat_images': 'View Chat Images',
    'crypto_data': 'Crypto Data',
    'weather': 'Weather',
    'search_places': 'Place Search',
    'search_restaurants': 'Restaurant Search',
    'geocode': 'Geocoding',
    'get_route': 'Routing',
    'calculate': 'Calculator',
    'get_time': 'Clock',
    'random_number': 'Random Number',
    'flip_coin': 'Coin Flip',
    'roll_dice': 'Dice Roll',
    'countdown': 'Countdown',
    'password_generator': 'Password Generator',
    'uuid_generator': 'UUID Generator',
    'notes': 'Notes',
    'generate_qr': 'QR Generator',
    'whoop': 'WHOOP Health',
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Keep route transition smooth, then hydrate tool prefs.
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250), () async {
          if (!mounted) return;
          await _loadToolPreferences();
        }),
      );
    });
  }

  Future<void> _loadToolPreferences() async {
    final stopwatch = Stopwatch()..start();
    try {
      await Future.wait([
        _toolExecutor.loadPreferences(),
        platform_tools.initPlatformServices(),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _mapVisualOutputEnabled = _toolExecutor.mapVisualOutputEnabled;
        _chartVisualOutputEnabled = _toolExecutor.chartVisualOutputEnabled;
        _isLoadingToolPreferences = false;
      });
      unawaited(
        DiagnosticsLogService.timing(
          'settings',
          'load_tool_calling_preferences',
          stopwatch.elapsedMilliseconds,
          data: {
            'tool_count': _toolExecutor.allRegisteredTools.length,
            'map_visual': _mapVisualOutputEnabled,
            'chart_visual': _chartVisualOutputEnabled,
          },
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingToolPreferences = false;
      });
      unawaited(
        DiagnosticsLogService.warning(
          'settings',
          'Failed to load tool calling preferences',
          data: {'error': error.toString()},
        ),
      );
    }
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
      case ToolCategory.whoop:
        return 10;
      case ToolCategory.nextcloud:
        return 11;
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
      case ToolCategory.whoop:
        return 'WHOOP';
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
      case ToolCategory.whoop:
        return Icons.monitor_heart_outlined;
      case ToolCategory.nextcloud:
        return Icons.cloud_outlined;
    }
  }

  String _categoryDescription(ToolCategory category) {
    switch (category) {
      case ToolCategory.search:
        return 'Search the web, fetch pages, generate images, and look up data';
      case ToolCategory.basic:
        return 'Calculator, clock, notes, QR codes, and other utilities';
      case ToolCategory.map:
        return 'Find places, geocode addresses, and calculate routes';
      case ToolCategory.device:
        return 'Access device features like GPS, calendar, and reminders';
      case ToolCategory.spotify:
        return 'Control playback and browse your Spotify library';
      case ToolCategory.bash:
        return 'Run sandboxed shell commands on the desktop';
      case ToolCategory.github:
        return 'Access repos, issues, PRs, and commits from GitHub';
      case ToolCategory.slack:
        return 'Send messages, search channels, and fetch Slack data';
      case ToolCategory.google:
        return 'Manage your schedule and email via Google Calendar and Gmail';
      case ToolCategory.email:
        return 'Send and receive email via IMAP and SMTP';
      case ToolCategory.whoop:
        return 'View recovery, strain, sleep, and workout data from WHOOP';
      case ToolCategory.nextcloud:
        return 'Browse files, calendar, and contacts on Nextcloud';
    }
  }

  /// Map a ToolCategory to the service name used by platform_tools.
  /// Returns null for categories that don't have OAuth connections.
  String? _categoryServiceName(ToolCategory category) {
    switch (category) {
      case ToolCategory.spotify:
        return 'spotify';
      case ToolCategory.github:
        return 'github';
      case ToolCategory.slack:
        return 'slack';
      case ToolCategory.google:
        return 'google';
      case ToolCategory.email:
        return 'email';
      case ToolCategory.whoop:
        return 'whoop';
      default:
        return null;
    }
  }

  bool _isCategoryConnectable(ToolCategory category) {
    final name = _categoryServiceName(category);
    return name != null && platform_tools.connectableServices.contains(name);
  }

  bool _isCategoryConnected(ToolCategory category) {
    final name = _categoryServiceName(category);
    if (name == null) {
      return true; // non-OAuth categories are always "connected"
    }
    return _toolExecutor.isServiceConnected(category);
  }

  Future<void> _connectService(ToolCategory category) async {
    final name = _categoryServiceName(category);
    if (name == null) return;

    try {
      final success = await platform_tools.connectPlatformService(name);
      if (!mounted) return;
      if (success) {
        setState(() {});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${_categoryLabel(category)} connected'),
              backgroundColor: Colors.green.shade700,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to connect ${_categoryLabel(category)}'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to connect ${_categoryLabel(category)}. Please try again.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _disconnectService(ToolCategory category) async {
    final name = _categoryServiceName(category);
    if (name == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Disconnect ${_categoryLabel(category)}?'),
        content: const Text('This will remove your saved credentials.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await platform_tools.disconnectPlatformService(name);
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to disconnect ${_categoryLabel(category)}. Please try again.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
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

  List<Widget> _buildConnectorCards(Color scaffoldBg, Color iconFg) {
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
      final connectable = _isCategoryConnectable(category);
      final connected = _isCategoryConnected(category);
      final toolsInCategory = grouped[category]!;

      // Category header card
      widgets.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scaffoldBg.lighten(0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: iconFg.withValues(alpha: 0.15)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scaffoldBg.lighten(0.07),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: iconFg.withValues(alpha: 0.1),
                  ),
                ),
                child: Icon(
                  _categoryIcon(category),
                  size: 18,
                  color: iconFg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _categoryLabel(category),
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.9),
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      _categoryDescription(category),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: iconFg.lighten(0.2),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (connectable) ...[
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? Colors.green.shade400
                        : iconFg.withValues(alpha: 0.3),
                  ),
                ),
                connected
                    ? TextButton(
                        onPressed: () => _disconnectService(category),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          'Disconnect',
                          style: TextStyle(
                            fontSize: 12,
                            color: iconFg.withValues(alpha: 0.6),
                          ),
                        ),
                      )
                    : FilledButton.tonal(
                        onPressed: () => _connectService(category),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Connect',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
              ],
            ],
          ),
        ),
      );
      widgets.add(const SizedBox(height: 6));

      // Individual tool cards under this category
      for (final tool in toolsInCategory) {
        final isEnabled = _toolExecutor.isToolEnabled(tool.name);

        widgets.add(
          Card(
            color: scaffoldBg.lighten(0.05),
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: iconFg.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              leading: Icon(
                _toolIcons[tool.name] ?? Icons.extension,
                color: isEnabled
                    ? Theme.of(context).colorScheme.primary
                    : iconFg.withValues(alpha: 0.4),
              ),
              title: Text(
                _displayName(tool.name),
                style: TextStyle(
                  color: Theme.of(context).textTheme.titleMedium?.color,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                _trimDescription(
                  _toolExecutor.getToolDescription(tool.name),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: iconFg.lighten(0.2),
                  fontSize: 12,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 28,
                    child: Switch(
                      value: isEnabled,
                      onChanged: (value) async {
                        await _toolExecutor.setToolEnabled(
                          tool.name,
                          value,
                        );
                        if (!mounted) return;
                        setState(() {});
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    color: iconFg.withValues(alpha: 0.4),
                    size: 20,
                  ),
                ],
              ),
              onTap: () => _openToolDetail(tool),
            ),
          ),
        );
        widgets.add(const SizedBox(height: 6));
      }

      widgets.add(const SizedBox(height: 12));
    }

    return widgets;
  }

  Future<void> _openToolDetail(ClientTool tool) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConnectorDetailPage(
          tool: tool,
          toolExecutor: _toolExecutor,
          displayName: _displayName(tool.name),
          icon: _toolIcons[tool.name] ?? Icons.extension,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
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
            'Connectors',
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
            ..._buildConnectorCards(scaffoldBg, iconFg),
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
