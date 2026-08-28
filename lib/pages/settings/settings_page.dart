import 'package:flutter/material.dart';

import 'package:cowork/pages/settings/account_settings_page.dart';
import 'package:cowork/pages/settings/developer_settings_page.dart';
import 'package:cowork/pages/settings/embedding_settings_page.dart';
import 'package:cowork/pages/settings/mcp_connectors_page.dart';
import 'package:cowork/pages/settings/model_settings_page.dart';
import 'package:cowork/pages/settings/theme_settings_page.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/settings/embedding_model_service.dart';
import 'package:cowork/services/settings/theme_controller.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// The settings hub: a scrolling list of grouped tiles, each pushing a
/// sub-page. Greenfield — the owner asked for the extra settings menu first,
/// knowing it will change — so the structure is deliberately plain: one tile
/// per area, no state on this page beyond what the tiles read for a subtitle.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.themeController,
    this.sessionSource = const SupabaseAccountSession(),
  });

  /// The live theme mode, shown as the Theme tile's subtitle and edited on the
  /// Theme sub-page.
  final ThemeController themeController;

  /// The account session, read by the Account and Model sub-pages.
  final AccountSessionSource sessionSource;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _embeddingModel = EmbeddingModelService.defaultModelId;

  @override
  void initState() {
    super.initState();
    _loadEmbedding();
  }

  Future<void> _loadEmbedding() async {
    final id = await EmbeddingModelService.load();
    if (mounted) setState(() => _embeddingModel = id);
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
    // Refresh subtitles that a sub-page may have changed.
    if (mounted) _loadEmbedding();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const ExpressiveTitle('Settings'),
          const ExpressiveSectionHeader('Account'),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.person_outline,
                title: 'Account',
                subtitle: 'Identity and sign-out',
                trailing: const _Chevron(),
                onTap: () => _push(const AccountSettingsPage()),
              ),
            ],
          ),
          const ExpressiveSectionHeader('AI & Memory'),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.smart_toy_outlined,
                title: 'Model',
                subtitle: 'The model behind each composer mode',
                trailing: const _Chevron(),
                onTap: () => _push(
                  ModelSettingsPage(sessionSource: widget.sessionSource),
                ),
              ),
              ExpressiveRow(
                icon: Icons.hub_outlined,
                title: 'MCP Connectors',
                subtitle: 'Model Context Protocol servers',
                trailing: const _Chevron(),
                onTap: () => _push(const McpConnectorsPage()),
              ),
              ExpressiveRow(
                icon: Icons.scatter_plot_outlined,
                title: 'Embedding model',
                subtitle: EmbeddingModelService.nameFor(_embeddingModel),
                trailing: const _Chevron(),
                onTap: () => _push(const EmbeddingSettingsPage()),
              ),
            ],
          ),
          const ExpressiveSectionHeader('Appearance'),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.palette_outlined,
                title: 'Theme',
                subtitle: ThemeController.label(widget.themeController.value),
                trailing: const _Chevron(),
                onTap: () => _push(
                  ThemeSettingsPage(controller: widget.themeController),
                ),
              ),
            ],
          ),
          const ExpressiveSectionHeader('System'),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.code,
                title: 'Developer',
                subtitle: 'Endpoints and debug options',
                trailing: const _Chevron(),
                onTap: () => _push(const DeveloperSettingsPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) => Icon(
        Icons.chevron_right,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
}
