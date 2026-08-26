import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/pages/connector_detail_page.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/tool_handlers/platform_tools.dart' as platform_tools;
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

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

  static Map<String, String> _toolDisplayNames(AppLocalizations l) => {
    'web_search': l.toolWebSearch,
    'web_crawl': l.toolWebCrawl,
    'generate_image': l.toolImageGen,
    'fetch_image': l.toolFetchImage,
    'view_chat_images': l.toolViewChatImages,
    'crypto_data': l.toolCryptoData,
    'weather': l.toolWeather,
    'search_places': l.toolPlaceSearch,
    'search_restaurants': l.toolRestaurantSearch,
    'geocode': l.toolGeocoding,
    'get_route': l.toolRouting,
    'calculate': l.toolCalculator,
    'get_time': l.toolClock,
    'random_number': l.toolRandomNumber,
    'flip_coin': l.toolCoinFlip,
    'roll_dice': l.toolDiceRoll,
    'countdown': l.toolCountdown,
    'password_generator': l.toolPasswordGen,
    'uuid_generator': l.toolUuidGen,
    'notes': l.toolNotes,
    'generate_qr': l.toolQrGen,
    'whoop': l.toolWhoopHealth,
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
    DeveloperOptionsService.enabledNotifier.addListener(_onDevOptionsChanged);
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

  @override
  void dispose() {
    DeveloperOptionsService.enabledNotifier.removeListener(
      _onDevOptionsChanged,
    );
    super.dispose();
  }

  void _onDevOptionsChanged() {
    if (!mounted) return;
    setState(() {});
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
      case ToolCategory.sandbox:
        return 12;
      case ToolCategory.mcp:
        return 13;
    }
  }

  String _categoryLabel(ToolCategory category) {
    final l = AppLocalizations.of(context)!;
    switch (category) {
      case ToolCategory.search:
        return l.catSearchWeb;
      case ToolCategory.basic:
        return l.catUtilities;
      case ToolCategory.map:
        return l.catMapsLocation;
      case ToolCategory.device:
        return l.catDevice;
      case ToolCategory.spotify:
        return l.catSpotify;
      case ToolCategory.bash:
        return l.catBashTerminal;
      case ToolCategory.github:
        return l.catGitHub;
      case ToolCategory.slack:
        return l.catSlack;
      case ToolCategory.google:
        return l.catGoogleCalGmail;
      case ToolCategory.email:
        return l.catEmailImapSmtp;
      case ToolCategory.whoop:
        return l.catWhoop;
      case ToolCategory.nextcloud:
        return l.catNextcloud;
      case ToolCategory.sandbox:
        return l.catSandbox;
      case ToolCategory.mcp:
        return 'Connectors';
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
      case ToolCategory.sandbox:
        return Icons.code_outlined;
      case ToolCategory.mcp:
        return Icons.extension_outlined;
    }
  }

  String _categoryDescription(ToolCategory category) {
    final l = AppLocalizations.of(context)!;
    switch (category) {
      case ToolCategory.search:
        return l.catSearchWebDesc;
      case ToolCategory.basic:
        return l.catUtilitiesDesc;
      case ToolCategory.map:
        return l.catMapsLocationDesc;
      case ToolCategory.device:
        return l.catDeviceDesc;
      case ToolCategory.spotify:
        return l.catSpotifyDesc;
      case ToolCategory.bash:
        return l.catBashTerminalDesc;
      case ToolCategory.github:
        return l.catGitHubDesc;
      case ToolCategory.slack:
        return l.catSlackDesc;
      case ToolCategory.google:
        return l.catGoogleCalGmailDesc;
      case ToolCategory.email:
        return l.catEmailImapSmtpDesc;
      case ToolCategory.whoop:
        return l.catWhoopDesc;
      case ToolCategory.nextcloud:
        return l.catNextcloudDesc;
      case ToolCategory.sandbox:
        return l.catSandboxDesc;
      case ToolCategory.mcp:
        return 'Tools from the servers you connected';
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
    final l = AppLocalizations.of(context)!;
    final name = _categoryServiceName(category);
    if (name == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.disconnectCategory(_categoryLabel(category))),
        content: Text(l.removeCredentialsWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.disconnect),
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
    final mapped = _toolDisplayNames(AppLocalizations.of(context)!)[toolName];
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

  // GitHub and Spotify integrations ship behind Developer Options — the
  // server-side OAuth is wired up but we're not advertising them yet.
  static const Set<ToolCategory> _devOnlyCategories = {
    ToolCategory.github,
    ToolCategory.spotify,
  };

  bool _isCategoryDevOnly(ToolCategory category) =>
      _devOnlyCategories.contains(category) &&
      !DeveloperOptionsService.enabledNotifier.value;

  List<ClientTool> _visibleTools() {
    final tools = _toolExecutor.allRegisteredTools
        .where((tool) => tool.name != 'find_tools')
        .where((tool) {
          final category =
              ToolExecutor.toolCategories[tool.name] ?? ToolCategory.basic;
          // Tools from MCP servers are not listed here. A connector is a
          // server you sign in to, and it is managed on the Connectors
          // screen — mixing its tools into this list only made the page
          // longer without giving anything to switch.
          if (category == ToolCategory.mcp) {
            return false;
          }
          return !_isCategoryDevOnly(category);
        })
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

  List<Widget> _buildToolSections() {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final tools = _visibleTools();
    if (tools.isEmpty) {
      return [ExpressiveInfoCard(text: l.noToolsRegistered)];
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
      final description = _categoryDescription(category);
      final toolsInCategory = grouped[category]!;

      widgets.add(ExpressiveSectionHeader(_categoryLabel(category)));

      // A category the assistant signs in to carries its state as a pill and
      // flips it on tap; the rest just get a quiet line of context under the
      // header so the description is never lost.
      if (!connectable) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            ),
          ),
        );
      }

      final rows = <Widget>[
        if (connectable)
          ExpressiveRow(
            icon: connected
                ? Icons.check_circle_outline
                : _categoryIcon(category),
            tone: connected ? m3.successContainer : null,
            title: connected ? l.disconnect : l.connect,
            subtitle: description,
            trailing: connected
                ? ExpressiveBadge('Connected', tone: m3.successContainer)
                : const ExpressiveBadge('Not connected'),
            onTap: connected
                ? () => _disconnectService(category)
                : () => _connectService(category),
          ),
        for (final tool in toolsInCategory)
          _ToolRow(
            icon: _toolIcons[tool.name] ?? Icons.extension,
            iconEnabled: _toolExecutor.isToolEnabled(tool.name),
            title: _displayName(tool.name),
            subtitle: _trimDescription(
              _toolExecutor.getToolDescription(tool.name),
            ),
            value: _toolExecutor.isToolEnabled(tool.name),
            onChanged: (value) async {
              await _toolExecutor.setToolEnabled(tool.name, value);
              if (!mounted) return;
              setState(() {});
            },
            onTap: () => _openToolDetail(tool),
          ),
      ];

      widgets.add(ExpressiveGroup(children: rows));
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
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.resetToolSettingsTitle),
        content: Text(l.resetToolSettingsBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.reset),
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
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.toolCalling),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const ExpressiveSectionHeader('Engine'),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
                icon: Icons.precision_manufacturing_outlined,
                title: l.enableToolCalling,
                subtitle: l.enableToolCallingSubtitle,
                value: _toolCallingEnabled,
                onChanged: (value) {
                  setState(() {
                    _toolCallingEnabled = value;
                  });
                  widget.config.setToolCallingEnabled(value);
                },
              ),
            ],
          ),
          const ExpressiveSectionHeader('Behavior'),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
                icon: Icons.search,
                title: l.requireDiscoveryFirst,
                subtitle: l.requireDiscoverySubtitle,
                value: _toolDiscoveryMode,
                onChanged: _toolCallingEnabled
                    ? (value) {
                        setState(() {
                          _toolDiscoveryMode = value;
                        });
                        widget.config.setToolDiscoveryMode(value);
                      }
                    : null,
              ),
              ExpressiveSwitchRow(
                icon: Icons.code,
                title: l.markdownToolCallFallback,
                subtitle: l.markdownFallbackSubtitle,
                value: _allowMarkdownToolCalls,
                onChanged: _toolCallingEnabled
                    ? (value) {
                        setState(() {
                          _allowMarkdownToolCalls = value;
                        });
                        widget.config.setAllowMarkdownToolCalls(value);
                      }
                    : null,
              ),
            ],
          ),
          const ExpressiveSectionHeader('Display'),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
                icon: Icons.visibility_outlined,
                title: l.showToolActivity,
                subtitle: l.showToolActivitySubtitle,
                value: _showToolCalls,
                onChanged: (value) {
                  setState(() {
                    _showToolCalls = value;
                  });
                  widget.config.setShowToolCalls(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          ExpressiveInfoCard(text: l.toolCallingTip),
          const ExpressiveSectionHeader('Visual output'),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
                icon: Icons.map_outlined,
                title: l.enableMapBlocks,
                subtitle: l.enableMapBlocksSubtitle,
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
              ),
              ExpressiveSwitchRow(
                icon: Icons.insights_outlined,
                title: l.enableChartBlocks,
                subtitle: l.enableChartBlocksSubtitle,
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
              ),
            ],
          ),
          const ExpressiveSectionHeader('Tools'),
          if (_isLoadingToolPreferences)
            ExpressiveInfoCard(
              text: l.loadingToolSettings,
              icon: Icons.hourglass_empty,
            )
          else
            ..._buildToolSections(),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _isLoadingToolPreferences
                  ? null
                  : _resetAllToolPreferences,
              icon: const Icon(Icons.restore),
              label: Text(l.resetAllToolPrefs),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────── private shared widgets ─────────

/// One tool: the switch turns it off, the tile itself opens its detail.
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.icon,
    required this.iconEnabled,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.onTap,
  });

  final IconData icon;
  final bool iconEnabled;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return ExpressiveRow(
      icon: icon,
      tone: iconEnabled ? null : m3.surfaceContainerHighest,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch.adaptive(value: value, onChanged: onChanged),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 20, color: m3.onSurfaceVariant),
        ],
      ),
    );
  }
}

