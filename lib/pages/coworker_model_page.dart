/// A coworker's model: the one place where its model, provider and reasoning
/// level are set.
///
/// The coworker profile, the desktop details pane and the composer's "More
/// models" all open this page, and the composer of the coworker's thread
/// writes the same record ([ChatModelSelectionService]), so there is no
/// second copy to drift. A coworker without a model of its own follows the
/// app default (Settings → Model Selection), and the page says which one.
///
/// The top of the page answers the question the owner had after changing a
/// provider — did it apply? It shows what the next message runs on, and,
/// from the host, what the last run really used.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/coworker_model.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/coworker_model_tile.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/icons/model_logo.dart';
import 'package:chuk_chat/widgets/searchable_picker.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

class CoworkerModelPage extends StatefulWidget {
  const CoworkerModelPage({
    super.key,
    required this.chatId,
    this.coworkerName,
    this.controlSource,
  });

  /// The coworker's thread key, which its model is stored under.
  final String chatId;

  /// Used in the page's sentences ("Every message to Alex …").
  final String? coworkerName;

  /// Where the last run's model comes from. Null builds one over the relay in
  /// the Agents build, and none elsewhere.
  final AgentControlSource? controlSource;

  static Future<void> open(
    BuildContext context, {
    required String chatId,
    String? coworkerName,
    AgentControlSource? controlSource,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CoworkerModelPage(
          chatId: chatId,
          coworkerName: coworkerName,
          controlSource: controlSource,
        ),
      ),
    );
  }

  @override
  State<CoworkerModelPage> createState() => _CoworkerModelPageState();
}

class _CoworkerModelPageState extends State<CoworkerModelPage> {
  /// How many models the page lists before the rest go behind "All models".
  static const int _kListedModels = 8;

  CoworkerModelState? _state;
  List<CoworkerCatalogueModel> _models = const <CoworkerCatalogueModel>[];
  Set<String> _pinned = const <String>{};
  bool _loading = true;
  bool _saving = false;

  /// The catalogue did not load (offline, empty cache, a hung fetch). The
  /// page still shows the stored choice, plus a Retry row.
  bool _catalogueFailed = false;
  bool _retrying = false;
  Timer? _watchdog;

  AgentControlSource? _ownedSource;
  AgentControlSource? get _source => widget.controlSource ?? _ownedSource;

  String get _name {
    final String? name = widget.coworkerName?.trim();
    return (name == null || name.isEmpty) ? 'this coworker' : name;
  }

  @override
  void initState() {
    super.initState();
    if (widget.controlSource == null && agentsChatCore) {
      _ownedSource = RelayAgentControlSource();
    }
    unawaited(_source?.refresh(widget.chatId).catchError((Object _) {}));
    ChatModelSelectionService.instance.addListener(_onStoreChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    ChatModelSelectionService.instance.removeListener(_onStoreChanged);
    _ownedSource?.dispose();
    super.dispose();
  }

  void _onStoreChanged() => unawaited(_loadState());

  /// Loads the coworker's choice, the catalogue and the pinned models, each
  /// on its own: a catalogue that does not come never holds up the choice.
  /// The watchdog ([_startWatchdog]) ends the wait after
  /// [CoworkerModel.loadTimeout] with the stored choice (or the built-in
  /// default) and a Retry row ([_catalogueFailed]); the page never stays on
  /// a spinner.
  Future<void> _load() async {
    _startWatchdog();
    final Future<void> state = _loadState();
    unawaited(
      _loadPinned().then((Set<String> pinned) {
        if (mounted) setState(() => _pinned = pinned);
      }),
    );
    List<CoworkerCatalogueModel> models = const <CoworkerCatalogueModel>[];
    try {
      models = await CoworkerModel.catalogue();
      if (models.isEmpty) {
        await ModelPrefetchService.prefetch();
        models = await CoworkerModel.catalogue();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CoworkerModelPage: catalogue failed: $e');
    }
    if (!mounted) return;
    _watchdog?.cancel();
    setState(() {
      _models = models;
      _catalogueFailed = models.isEmpty;
    });
    await state;
  }

  /// Ends a wait that hangs: what is known shows, and the list offers Retry.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(CoworkerModel.loadTimeout, () {
      if (!mounted) return;
      setState(() {
        _state ??= CoworkerModel.fallbackState();
        _loading = false;
        _retrying = false;
        if (_models.isEmpty) _catalogueFailed = true;
      });
    });
  }

  /// Retry after a catalogue that did not load.
  Future<void> _retryCatalogue() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await _load();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _loadState() async {
    final state = await CoworkerModel.resolveOrFallback(widget.chatId);
    if (!mounted) return;
    setState(() {
      _state = state;
      _loading = false;
    });
  }

  /// The models the reader has enabled on the model screen.
  Future<Set<String>> _loadPinned() async {
    try {
      final String? userId = SupabaseService.auth.currentUser?.id;
      if (userId == null) return const <String>{};
      final prefs = await ModelCacheService.loadProviderPreferences(userId);
      return <String>{
        for (final entry in prefs.entries)
          if (entry.value.trim().isNotEmpty) entry.key,
      };
    } catch (_) {
      return const <String>{};
    }
  }

  CoworkerCatalogueModel? _model(String id) {
    for (final model in _models) {
      if (model.id == id) return model;
    }
    return null;
  }

  // --- writes -------------------------------------------------------------

  Future<void> _write({
    required String modelId,
    required String providerSlug,
    required String reasoningEffort,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await CoworkerModel.setOwn(
        widget.chatId,
        modelId: modelId,
        providerSlug: providerSlug,
        reasoningEffort: reasoningEffort,
      );
      await _loadState();
      if (!mounted) return;
      pillToast(
        context,
        'Next message: ${modelLabel(saved.modelId, models: _models)} via '
        '${providerLabel(saved.providerSlug, modelId: saved.modelId, models: _models)}',
        icon: Icons.check_circle_rounded,
      );
    } catch (_) {
      if (mounted) {
        pillToast(context, 'Could not save. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickModel(String modelId) async {
    final state = _state;
    if (state == null || modelId == state.modelId) return;
    final String? provider = await CoworkerModel.providerFor(
      modelId,
      models: _models,
    );
    if (!mounted) return;
    if (provider == null) {
      pillToast(context, 'No provider serves this model right now.');
      return;
    }
    await _write(
      modelId: modelId,
      providerSlug: provider,
      reasoningEffort: state.reasoningEffort,
    );
  }

  Future<void> _pickProvider(String slug) async {
    final state = _state;
    if (state == null ||
        (slug == state.providerSlug && !state.followsDefault)) {
      return;
    }
    await _write(
      modelId: state.modelId,
      providerSlug: slug,
      reasoningEffort: state.reasoningEffort,
    );
  }

  Future<void> _pickEffort(String level) async {
    final state = _state;
    if (state == null || level == state.reasoningEffort) return;
    await _write(
      modelId: state.modelId,
      providerSlug: state.providerSlug,
      reasoningEffort: level,
    );
  }

  Future<void> _useDefault() async {
    try {
      await CoworkerModel.useDefault(widget.chatId);
      await _loadState();
      if (!mounted) return;
      final state = _state;
      pillToast(
        context,
        state == null
            ? 'Back on the app default'
            : 'Back on the app default (${state.defaultLabel})',
        icon: Icons.check_circle_rounded,
      );
    } catch (_) {
      if (mounted) pillToast(context, 'Could not save. Please try again.');
    }
  }

  Future<void> _openDefaults() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ModelSelectorPage()));
    // The default may have changed under a coworker that follows it.
    if (mounted) await _loadState();
  }

  Future<void> _openAllModels(BuildContext anchorContext) async {
    final state = _state;
    if (state == null) return;
    final ColorScheme scheme = Theme.of(anchorContext).colorScheme;
    final String? picked = await showSearchablePicker<String>(
      anchorContext,
      title: 'All models',
      hintText: 'Search models',
      options: <PickerOption<String>>[
        for (final model in _models)
          PickerOption<String>(
            value: model.id,
            label: model.shortName,
            subtitle: model.cheapest?.priceLine,
            searchText: '${model.name} ${model.id}',
            leading: ModelLogo(
              modelId: model.id,
              color: scheme.onSurfaceVariant,
            ),
            selected: model.id == state.modelId,
          ),
      ],
    );
    if (picked != null) await _pickModel(picked);
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const FloatingAppBar(title: Text('Model')),
      body: _loading || state == null
          ? const Center(child: CircularProgressIndicator())
          : SettingsListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: <Widget>[
                _summary(context, state),
                ..._modelSection(context, state),
                ..._providerSection(context, state),
                ..._reasoningSection(context, state),
                ..._defaultSection(context, state),
              ],
            ),
    );
  }

  /// What the next message runs on, and what the last one ran on.
  Widget _summary(BuildContext context, CoworkerModelState state) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String provider = providerLabel(
      state.providerSlug,
      modelId: state.modelId,
      models: _models,
    );
    final String effort = ChatModeService.reasoningLabel(state.reasoningEffort);
    return ExpressiveGroup(
      children: <Widget>[
        ExpressiveTile(
          key: const ValueKey<String>('coworker_model_summary'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  CoworkerModelLogoTile(modelId: state.modelId, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          modelLabel(state.modelId, models: _models),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'via $provider · Reasoning ${effort.toLowerCase()}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.m3.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ExpressiveBadge(
                state.followsDefault
                    ? 'App default · ${state.defaultLabel}'
                    : 'Own choice for ${widget.coworkerName ?? 'this coworker'}',
                icon: state.followsDefault
                    ? Icons.settings_outlined
                    : Icons.check_circle_rounded,
                tone: state.followsDefault ? null : scheme.secondaryContainer,
              ),
            ],
          ),
        ),
        if (_source != null) _lastRun(context, state),
      ],
    );
  }

  Widget _lastRun(BuildContext context, CoworkerModelState state) {
    return ValueListenableBuilder<AgentControlSnapshot>(
      valueListenable: _source!.snapshotFor(widget.chatId),
      builder: (context, snapshot, _) {
        final ControlValue<AgentModelChoice> value = snapshot.model;
        final String subtitle;
        switch (value) {
          case ControlAvailable<AgentModelChoice>(value: final run):
            final String provider = run.provider == null
                ? 'provider not reported'
                : providerLabel(
                    run.provider!,
                    modelId: run.id,
                    models: _models,
                  );
            final String effort = run.reasoningEffort == null
                ? ''
                : ' · ${ChatModeService.reasoningLabel(run.reasoningEffort!).toLowerCase()}';
            final bool same =
                run.id == state.modelId &&
                (run.provider == null || run.provider == state.providerSlug);
            subtitle =
                '${modelLabel(run.id, models: _models)} via $provider$effort'
                '${same ? '' : '\nYour change applies from the next message.'}';
          case ControlLoading<AgentModelChoice>():
            subtitle = 'Asking the host…';
          case ControlUnavailable<AgentModelChoice>(:final reason):
            subtitle = reason;
        }
        return ExpressiveRow(
          key: const ValueKey<String>('coworker_model_last_run'),
          icon: Icons.schedule_outlined,
          tone: Theme.of(context).m3.surfaceContainerHighest,
          title: 'Last run',
          subtitle: subtitle,
        );
      },
    );
  }

  List<Widget> _modelSection(BuildContext context, CoworkerModelState state) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // The model in use, the two app defaults and the models the reader
    // enabled — the same short list the composer's menu offers.
    final List<String> ids = <String>[
      state.modelId,
      ChatModeService.defaultConfig(ChatMode.fast).modelId,
      ChatModeService.defaultConfig(ChatMode.thinking).modelId,
      state.defaultConfig.modelId,
      ..._pinned,
    ];
    final List<CoworkerCatalogueModel> listed = <CoworkerCatalogueModel>[];
    for (final id in ids.toSet()) {
      final model = _model(id);
      if (model != null) listed.add(model);
    }
    listed.sort((a, b) {
      if (a.id == state.modelId) return -1;
      if (b.id == state.modelId) return 1;
      return a.shortName.toLowerCase().compareTo(b.shortName.toLowerCase());
    });
    final bool currentKnown = _model(state.modelId) != null;
    return <Widget>[
      const ExpressiveSectionHeader('Model'),
      ExpressiveGroup(
        children: <Widget>[
          if (_catalogueFailed) _catalogueRetryRow(context),
          if (!currentKnown)
            ExpressiveRow(
              leading: CoworkerModelLogoTile(modelId: state.modelId),
              title: modelLabel(state.modelId),
              subtitle: 'Not in the model list on this device',
              trailing: _check(scheme),
            ),
          for (final model in listed.take(_kListedModels))
            ExpressiveRow(
              key: ValueKey<String>('coworker_model_${model.id}'),
              leading: CoworkerModelLogoTile(modelId: model.id),
              title: model.shortName,
              subtitle: model.cheapest?.priceLine == null
                  ? null
                  : 'From ${model.cheapest!.priceLine}',
              trailing: model.id == state.modelId ? _check(scheme) : null,
              onTap: _saving ? null : () => _pickModel(model.id),
            ),
          if (_models.isNotEmpty)
            Builder(
              builder: (anchorContext) => ExpressiveRow(
                key: const ValueKey<String>('coworker_model_all'),
                icon: Icons.search,
                tone: Theme.of(context).m3.surfaceContainerHighest,
                title: 'All models',
                subtitle: '${_models.length} models',
                trailing: AppIcon(
                  Icons.chevron_right,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                onTap: _saving ? null : () => _openAllModels(anchorContext),
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _providerSection(
    BuildContext context,
    CoworkerModelState state,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final CoworkerCatalogueModel? model = _model(state.modelId);
    final List<CoworkerProvider> providers = <CoworkerProvider>[
      ...?model?.providers,
    ];
    if (providers.isEmpty) {
      return <Widget>[
        const ExpressiveSectionHeader('Provider'),
        ExpressiveGroup(
          children: <Widget>[
            ExpressiveRow(
              icon: Icons.dns_outlined,
              title: providerLabel(state.providerSlug),
              subtitle: 'The only provider this device knows for the model',
              trailing: _check(scheme),
            ),
          ],
        ),
      ];
    }
    providers.sort((a, b) {
      final double pa = a.completionPrice ?? double.infinity;
      final double pb = b.completionPrice ?? double.infinity;
      return pa.compareTo(pb);
    });
    final String? cheapest = providers.length > 1
        ? model!.cheapest?.slug
        : null;
    return <Widget>[
      const ExpressiveSectionHeader('Provider'),
      ExpressiveGroup(
        children: <Widget>[
          for (final provider in providers)
            ExpressiveRow(
              key: ValueKey<String>('coworker_provider_${provider.slug}'),
              icon: Icons.dns_outlined,
              tone: provider.slug == state.providerSlug
                  ? null
                  : Theme.of(context).m3.surfaceContainerHighest,
              title: provider.name,
              // The name keeps two lines next to the Cheapest badge and the
              // check: at 1.3 text scale one line cut it to "RunAnywhe…".
              titleMaxLines: 2,
              subtitle: _providerLine(provider),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (provider.slug == cheapest) ...<Widget>[
                    const ExpressiveBadge('Cheapest'),
                    const SizedBox(width: 8),
                  ],
                  if (provider.slug == state.providerSlug) _check(scheme),
                ],
              ),
              onTap: _saving ? null : () => _pickProvider(provider.slug),
            ),
        ],
      ),
    ];
  }

  String? _providerLine(CoworkerProvider provider) {
    final List<String> parts = <String>[
      ?provider.priceLine,
      if (provider.contextLength != null)
        '${_formatContext(provider.contextLength!)} context',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  List<Widget> _reasoningSection(
    BuildContext context,
    CoworkerModelState state,
  ) {
    final List<String> levels = ChatModeService.reasoningLevelsForModel(
      modelId: state.modelId,
      providerSlug: state.providerSlug,
    );
    if (levels.length < 2) return const <Widget>[];
    final int selected = levels.indexOf(state.reasoningEffort);
    return <Widget>[
      const ExpressiveSectionHeader('Reasoning'),
      ConnectedGroup(
        key: const ValueKey<String>('coworker_reasoning'),
        labels: <String>[
          for (final level in levels) ChatModeService.reasoningLabel(level),
        ],
        selected: selected < 0 ? 0 : selected,
        margin: EdgeInsets.zero,
        onSelected: (index) {
          if (_saving) return;
          unawaited(_pickEffort(levels[index]));
        },
      ),
    ];
  }

  List<Widget> _defaultSection(BuildContext context, CoworkerModelState state) {
    final ModeConfig config = state.defaultConfig;
    final String defaultLine =
        '${state.defaultLabel} · ${modelLabel(config.modelId, models: _models)}'
        ' · ${providerLabel(config.providerSlug, modelId: config.modelId, models: _models)}'
        ' · ${ChatModeService.reasoningLabel(config.reasoningEffort)}';
    return <Widget>[
      const ExpressiveSectionHeader('App default'),
      ExpressiveGroup(
        children: <Widget>[
          if (!state.followsDefault)
            ExpressiveRow(
              key: const ValueKey<String>('coworker_model_use_default'),
              icon: Icons.refresh,
              title: 'Use the app default',
              subtitle: defaultLine,
              onTap: _saving ? null : _useDefault,
            ),
          ExpressiveRow(
            key: const ValueKey<String>('coworker_model_defaults'),
            icon: Icons.settings_outlined,
            tone: Theme.of(context).m3.surfaceContainerHighest,
            title: 'Change the app default',
            subtitle: state.followsDefault
                ? defaultLine
                : 'Settings → Model Selection',
            trailing: AppIcon(
              Icons.chevron_right,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onTap: _openDefaults,
          ),
        ],
      ),
      const SizedBox(height: 12),
      ExpressiveInfoCard(
        text: state.followsDefault
            ? '${_capitalised(_name)} follows the app default, the same '
                  'Fast / Thinking choice a new chat uses. Pick a model, '
                  'provider or reasoning level above to give it its own. '
                  'Saved on this device.'
            : 'Every message to $_name runs on this model, from the next '
                  'one on. Picking Fast or Thinking in the chat goes back to '
                  'the app default. Saved on this device.',
      ),
    ];
  }

  /// "Could not load the model list", with Retry. The rows under it still
  /// show the stored choice.
  Widget _catalogueRetryRow(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ExpressiveRow(
      key: const ValueKey<String>('coworker_model_catalogue_retry'),
      icon: Icons.error_outline,
      tone: Theme.of(context).m3.surfaceContainerHighest,
      title: l.coworkerModelListFailed,
      titleMaxLines: 2,
      trailing: _retrying
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              l.retry,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: scheme.primary),
            ),
      onTap: _retrying ? null : () => unawaited(_retryCatalogue()),
    );
  }

  Widget _check(ColorScheme scheme) =>
      AppIcon(Icons.check_circle_rounded, size: 22, color: scheme.primary);

  static String _capitalised(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  static String _formatContext(int tokens) {
    if (tokens >= 1000000) {
      final double m = tokens / 1000000;
      return '${m.toStringAsFixed(m == m.roundToDouble() ? 0 : 1)}M';
    }
    if (tokens >= 1000) return '${(tokens / 1000).round()}K';
    return '$tokens';
  }
}
