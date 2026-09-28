import 'package:flutter/material.dart';

import 'package:chuk_chat/services/settings/embedding_model_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

/// Picks the embedding model the host uses for semantic memory.
///
/// Net-new and intentionally light: a static list plus a stored choice. The
/// host cannot yet feed real options or act on the pick, so the page is honest
/// about that in its footer.
class EmbeddingSettingsPage extends StatefulWidget {
  const EmbeddingSettingsPage({super.key});

  @override
  State<EmbeddingSettingsPage> createState() => _EmbeddingSettingsPageState();
}

class _EmbeddingSettingsPageState extends State<EmbeddingSettingsPage> {
  String _selected = EmbeddingModelService.defaultModelId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = await EmbeddingModelService.load();
    if (!mounted) return;
    setState(() {
      _selected = id;
      _loading = false;
    });
  }

  Future<void> _pick(String id) async {
    setState(() => _selected = id);
    await EmbeddingModelService.save(id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: const FloatingAppBar(title: Text('Embedding model')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SettingsListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  'Vectorises memories for semantic recall.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.resolvedIconColor.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 20),
                const ExpressiveSectionHeader('Model'),
                ExpressiveGroup(
                  children: [
                    for (final option in EmbeddingModelService.options)
                      ExpressiveRow(
                        icon: Icons.scatter_plot_outlined,
                        title: option.name,
                        subtitle: '${option.dimensions} dimensions',
                        trailing: option.id == _selected
                            ? AppIcon(
                                Icons.check,
                                color: theme.colorScheme.primary,
                              )
                            : null,
                        onTap: () => _pick(option.id),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const ExpressiveInfoCard(
                  text:
                      'The host runs the memory embedder. This choice is stored '
                      'now; wiring it through to the host is a later step, so '
                      'changing it does not re-embed existing memories yet.',
                ),
              ],
            ),
    );
  }
}
