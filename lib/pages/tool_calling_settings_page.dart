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
import 'package:chuk_chat/widgets/settings_kit.dart';

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
      case ToolCategory.sandbox:
        return 12;
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
      case ToolCategory.sandbox:
        return l.catSandbox;
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
      case ToolCategory.sandbox:
        return Icons.code_outlined;
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
      case ToolCategory.sandbox:
        return l.catSandboxDesc;
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

  List<Widget> _buildConnectorSections() {
    final l = AppLocalizations.of(context)!;
    final tools = _visibleTools();
    if (tools.isEmpty) {
      return [
        SettingsInfoCard(
          l.noToolsRegistered,
          tone: SettingsInfoTone.neutral,
          icon: Icons.info_outline,
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

      widgets.add(_CategoryHeader(
        icon: _categoryIcon(category),
        label: _categoryLabel(category),
        description: _categoryDescription(category),
        connectable: connectable,
        connected: connected,
        onConnect: () => _connectService(category),
        onDisconnect: () => _disconnectService(category),
      ));
      widgets.add(const SizedBox(height: 10));

      final rows = <Widget>[];
      for (final tool in toolsInCategory) {
        final isEnabled = _toolExecutor.isToolEnabled(tool.name);
        rows.add(
          _ToolRow(
            icon: _toolIcons[tool.name] ?? Icons.extension,
            iconEnabled: isEnabled,
            title: _displayName(tool.name),
            subtitle:
                _trimDescription(_toolExecutor.getToolDescription(tool.name)),
            value: isEnabled,
            onChanged: (value) async {
              await _toolExecutor.setToolEnabled(tool.name, value);
              if (!mounted) return;
              setState(() {});
            },
            onTap: () => _openToolDetail(tool),
          ),
        );
      }
      widgets.add(SettingsGroupedCard(children: rows));
      widgets.add(const SizedBox(height: 20));
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
        padding: const EdgeInsets.all(16),
        children: [
          const SettingsSectionHeader(
            'Engine',
            padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
          ),
          SettingsGroupedCard(
            children: [
              _SwitchRow(
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
          const SettingsSectionHeader(
            'Behavior',
            padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
          ),
          SettingsGroupedCard(
            children: [
              _SwitchRow(
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
              _SwitchRow(
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
          const SettingsSectionHeader(
            'Display',
            padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
          ),
          SettingsGroupedCard(
            children: [
              _SwitchRow(
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
          const SizedBox(height: 12),
          SettingsInfoCard(
            l.toolCallingTip,
            tone: SettingsInfoTone.neutral,
            icon: Icons.info_outline,
          ),
          const SettingsSectionHeader(
            'Visual Output',
            padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
          ),
          SettingsGroupedCard(
            children: [
              _SwitchRow(
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
              _SwitchRow(
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
          const SettingsSectionHeader(
            'Connectors',
            padding: EdgeInsets.fromLTRB(20, 20, 0, 8),
          ),
          if (_isLoadingToolPreferences)
            SettingsInfoCard(
              l.loadingToolSettings,
              tone: SettingsInfoTone.neutral,
              icon: Icons.hourglass_empty,
            )
          else
            ..._buildConnectorSections(),
          const SizedBox(height: 12),
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
          const SizedBox(height: 16),
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
    final disabled = onChanged == null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 24,
            color: disabled
                ? m3.onSurfaceVariant.withValues(alpha: 0.5)
                : m3.onSurfaceVariant,
          ),
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
                    color: disabled
                        ? cs.onSurface.withValues(alpha: 0.5)
                        : cs.onSurface,
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
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 24,
              color: iconEnabled ? cs.primary : m3.onSurfaceVariant,
            ),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 20, color: m3.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    required this.icon,
    required this.label,
    required this.description,
    required this.connectable,
    required this.connected,
    required this.onConnect,
    required this.onDisconnect,
  });

  final IconData icon;
  final String label;
  final String description;
  final bool connectable;
  final bool connected;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: m3.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: m3.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: m3.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: m3.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (connectable) ...[
            const SizedBox(width: 8),
            if (connected)
              _Badge(label: 'Connected', tone: BadgeTone.success)
            else
              _Badge(label: 'Not connected', tone: BadgeTone.neutral),
            const SizedBox(width: 8),
            connected
                ? OutlinedButton(
                    onPressed: onDisconnect,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 32),
                      shape: const StadiumBorder(),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      l.disconnect,
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                : FilledButton.tonal(
                    onPressed: onConnect,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 32),
                      shape: const StadiumBorder(),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      l.connect,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
          ],
        ],
      ),
    );
  }
}

enum BadgeTone { neutral, primary, success, warning, error }

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.tone = BadgeTone.neutral});
  final String label;
  final BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final Color bg;
    final Color fg;
    switch (tone) {
      case BadgeTone.primary:
        bg = m3.primaryContainer;
        fg = m3.onPrimaryContainer;
        break;
      case BadgeTone.success:
        bg = m3.successContainer;
        fg = m3.onSuccessContainer;
        break;
      case BadgeTone.warning:
        bg = m3.warningContainer;
        fg = m3.onWarningContainer;
        break;
      case BadgeTone.error:
        bg = cs.errorContainer;
        fg = cs.onErrorContainer;
        break;
      case BadgeTone.neutral:
        bg = m3.surfaceContainerHigh;
        fg = m3.onSurfaceVariant;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: fg,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
