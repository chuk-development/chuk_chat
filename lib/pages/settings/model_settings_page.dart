import 'package:flutter/material.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/chat_mode_service.dart';
import 'package:cowork/services/model_info_service.dart';
import 'package:cowork/widgets/chat_mode_selector.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// The full model catalogue for the composer's mode picker.
///
/// Each mode — Fast and Thinking — carries its own model, provider and
/// reasoning level. This page sets the model and reasoning level for the mode
/// selected at the top, browsing the whole catalogue the composer's quick-pick
/// menu only samples. The composer's "More models" row opens here.
class ModelSettingsPage extends StatefulWidget {
  const ModelSettingsPage({
    super.key,
    this.sessionSource = const SupabaseAccountSession(),
    this.initialMode = ChatMode.fast,
  });

  final AccountSessionSource sessionSource;
  final ChatMode initialMode;

  @override
  State<ModelSettingsPage> createState() => _ModelSettingsPageState();
}

class _ModelSettingsPageState extends State<ModelSettingsPage> {
  late ChatMode _mode = widget.initialMode;
  ModeConfig _config = ChatModeService.defaultConfig(ChatMode.fast);
  List<Map<String, dynamic>> _models = const <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await ChatModeService.loadConfig(_mode);
    final token = widget.sessionSource.current()?.accessToken ?? '';
    final models = await ModelInfoService.loadModels(accessToken: token);
    if (!mounted) return;
    setState(() {
      _config = config;
      _models = models;
      _loading = false;
    });
  }

  Future<void> _onModeChanged(ChatMode mode) async {
    final config = await ChatModeService.loadConfig(mode);
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _config = config;
    });
  }

  Future<void> _selectModel(Map<String, dynamic> model) async {
    final id = model['id'];
    if (id is! String || id.isEmpty) return;
    final provider = ModelInfoService.defaultProviderSlug(model);
    final config = await ChatModeService.setModelForMode(
      _mode,
      modelId: id,
      providerSlug: provider,
    );
    if (!mounted) return;
    setState(() => _config = config);
  }

  Future<void> _selectReasoning(String level) async {
    final config = await ChatModeService.setReasoningForMode(_mode, level);
    if (!mounted) return;
    setState(() => _config = config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reasoningLevels = ChatModeService.reasoningLevelsFor(
      providerSlug: _config.providerSlug,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Model')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                const ExpressiveTitle(
                  'Model',
                  subtitle: 'The model behind each composer mode',
                ),
                const ExpressiveSectionHeader('Mode'),
                SegmentedButton<ChatMode>(
                  segments: const <ButtonSegment<ChatMode>>[
                    ButtonSegment<ChatMode>(
                      value: ChatMode.fast,
                      icon: Icon(Icons.bolt),
                      label: Text('Fast'),
                    ),
                    ButtonSegment<ChatMode>(
                      value: ChatMode.thinking,
                      icon: Icon(Icons.psychology_outlined),
                      label: Text('Thinking'),
                    ),
                  ],
                  selected: <ChatMode>{_mode},
                  onSelectionChanged: (set) => _onModeChanged(set.first),
                ),
                if (reasoningLevels.length > 1) ...[
                  const ExpressiveSectionHeader('Reasoning'),
                  ExpressiveGroup(
                    children: [
                      for (final level in reasoningLevels)
                        ExpressiveRow(
                          icon: Icons.tune,
                          title: ChatModeService.reasoningLabel(level),
                          trailing: level == _config.reasoningEffort
                              ? Icon(Icons.check, color: theme.colorScheme.primary)
                              : null,
                          onTap: () => _selectReasoning(level),
                        ),
                    ],
                  ),
                ],
                const ExpressiveSectionHeader('Catalogue'),
                if (_models.isEmpty)
                  const ExpressiveInfoCard(
                    text:
                        'No models cached yet. Connect once so the app can fetch '
                        'the catalogue, then this list fills in.',
                  )
                else
                  ExpressiveGroup(
                    children: [
                      for (final model in _models)
                        ExpressiveRow(
                          icon: Icons.smart_toy_outlined,
                          title: _nameOf(model),
                          subtitle: _providerOf(model),
                          trailing: model['id'] == _config.modelId
                              ? Icon(Icons.check,
                                  color: theme.colorScheme.primary)
                              : null,
                          onTap: () => _selectModel(model),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }

  String _nameOf(Map<String, dynamic> model) {
    final name = model['name'];
    if (name is String && name.trim().isNotEmpty) {
      return ChatModeSelector.stripLabPrefix(name.trim());
    }
    final id = model['id'];
    return id is String ? prettyModelId(id) : 'model';
  }

  String? _providerOf(Map<String, dynamic> model) {
    final slug = ModelInfoService.defaultProviderSlug(model);
    return slug.isEmpty ? null : slug;
  }
}
