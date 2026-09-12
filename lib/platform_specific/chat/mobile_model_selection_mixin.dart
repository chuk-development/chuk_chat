// lib/platform_specific/chat/mobile_model_selection_mixin.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cowork/model_selector_page.dart';
import 'package:cowork/platform_specific/chat/composer_metrics.dart';
import 'package:cowork/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:cowork/services/chat_mode_service.dart';
import 'package:cowork/services/chat_model_selection_service.dart';
import 'package:cowork/services/model_cache_service.dart';
import 'package:cowork/services/model_capabilities_service.dart';
import 'package:cowork/services/model_prefetch_service.dart';
import 'package:cowork/services/supabase_service.dart';
import 'package:cowork/services/tour_key_registry.dart';
import 'package:cowork/services/user_preferences_service.dart';
import 'package:cowork/widgets/chat_mode_selector.dart';
import 'package:cowork/widgets/model_selection_dropdown.dart';

/// Which model, which mode and which reasoning level the mobile chat sends
/// with — and the composer control that shows and changes all three.
///
/// The mode config is the single source of truth for what a send uses; this
/// mixin owns the live projection of it ([chatMode], [reasoningEffort]) plus
/// the display names the mode menu needs, and keeps them in step with the
/// shared selected-model plumbing of [ModelProviderResolutionMixin].
///
/// Members are public so the host State and its build method can reach them.
mixin MobileModelSelectionMixin<T extends StatefulWidget>
    on State<T>, ModelProviderResolutionMixin<T> {
  // --- host-provided -------------------------------------------------------

  /// Host storage for the selected model id. [ModelProviderResolutionMixin]
  /// declares the getter; this mixin also writes it.
  set selectedModelId(String value);

  /// The host's snack bar, for the "choose a provider" refusals below.
  void showChatSnackBar(String message);

  // --- state ---------------------------------------------------------------

  ChatMode chatMode = ChatModeService.fallbackMode;

  /// The active mode's reasoning level (`none` … `xhigh`, `none` = off).
  /// Loaded from the mode's config; each mode remembers its own.
  String reasoningEffort = ChatModeService.defaultConfig(
    ChatModeService.fallbackMode,
  ).reasoningEffort;

  /// Human-readable name of the selected model, for the mode sheet.
  String? selectedModelName;

  /// The name of the model Custom last ran, or null until Custom has been used.
  String? customModelName;

  /// The models this reader has picked, for the composer's second menu.
  List<ChatModelChoice> pickedModels = const <ChatModelChoice>[];

  // --- hydration -----------------------------------------------------------

  void onChatModelChanged() {
    if (mounted) {
      unawaited(hydrateChatModel().catchError((Object _) => false));
    }
  }

  Future<bool> hydrateChatModel() async {
    final chatId = modelSelectionChatId;
    if (chatId == null) return false;
    final choice = await ChatModelSelectionService.instance.load(chatId);
    if (!mounted || modelSelectionChatId != chatId || choice == null) {
      return false;
    }
    setState(() {
      selectedModelId = choice.modelId;
      selectedProviderSlug = choice.providerSlug;
    });
    unawaited(refreshSelectedModelName(choice.modelId));
    return true;
  }

  /// Bring back the mode the reader last used, and with it that mode's own
  /// model, provider and reasoning level. The mode config is the single
  /// source of truth for what a send uses; this projects it into the live
  /// fields and keeps the shared selected-model plumbing in step.
  Future<void> restoreChatMode() async {
    final chatId = modelSelectionChatId;
    // The account-wide capabilities catalogue may still be loading. Restore
    // the explicit chat pair first so it never waits behind that network work.
    final hasChatChoice = await hydrateChatModel();
    final mode = await ChatModeService.load();
    final config = await ChatModeService.loadConfig(mode);
    if (!mounted || modelSelectionChatId != chatId) return;
    if (hasChatChoice) {
      if (mounted && modelSelectionChatId == chatId) {
        setState(() {
          chatMode = mode;
          reasoningEffort = config.reasoningEffort;
        });
      }
      return;
    }
    if (!mounted || modelSelectionChatId != chatId) return;
    if (chatId != null) {
      // A legacy chat inherits defaults locally. Merely opening a chat must
      // never publish a global selected-model/provider mutation.
      setState(() {
        chatMode = mode;
        reasoningEffort = config.reasoningEffort;
        selectedModelId = config.modelId;
        selectedProviderSlug = config.providerSlug;
      });
      unawaited(refreshSelectedModelName(config.modelId));
      return;
    }
    await applyModeConfig(mode, config);
  }

  /// Project [config] for [mode] into the live fields and the shared
  /// selected-model plumbing, then refresh the derived UI. Safe to call more
  /// than once — it is idempotent.
  Future<void> applyModeConfig(ChatMode mode, ModeConfig config) async {
    if (!mounted) return;
    setState(() {
      chatMode = mode;
      reasoningEffort = config.reasoningEffort;
      selectedModelId = config.modelId;
      selectedProviderSlug = config.providerSlug;
    });
    ModelSelectionDropdown.selectedModelNotifier.value = config.modelId;
    await UserPreferencesService.saveSelectedModel(config.modelId);
    // The per-model provider pin is owned by the model screen. Read it here
    // rather than overwrite it, and fall back to the mode's stored provider
    // only when nothing is pinned. Awaited so it cannot race the unawaited
    // read the model-selection listener starts from the notifier above.
    if (!mounted) return;
    await loadProviderSlugForModel(config.modelId, forceFromPrefs: true);
    if (mounted && (selectedProviderSlug ?? '').isEmpty) {
      setState(() {
        selectedProviderSlug = config.providerSlug;
      });
    }
    if (!mounted) return;
    await refreshSelectedModelName(config.modelId);
    await refreshCustomModelName();
    await refreshPickedModels();
  }

  // --- display names -------------------------------------------------------

  /// Resolve the selected model's human name for the mode sheet.
  ///
  /// Pass the id explicitly when reacting to a change, so a slow lookup for
  /// a model the reader has already moved on from cannot overwrite the
  /// name of the current one.
  Future<void> refreshSelectedModelName([String? modelId]) async {
    final target = modelId ?? selectedModelId;
    final name = await ModelCacheService.displayNameFor(target);
    if (!mounted || target != selectedModelId || name == selectedModelName) {
      return;
    }
    setState(() {
      selectedModelName = name;
    });
  }

  /// Resolve the name of the model Custom last ran, so the third point in the
  /// mode menu can name it even while Fast or Thinking is active. Stays null
  /// until Custom has a stored config (has been used at least once), so a fresh
  /// install shows the neutral "Choose model" instead of the seed default.
  Future<void> refreshCustomModelName() async {
    final bool used = await ChatModeService.hasStoredConfig(ChatMode.custom);
    if (!used) {
      if (mounted && customModelName != null) {
        setState(() => customModelName = null);
      }
      return;
    }
    final config = await ChatModeService.loadConfig(ChatMode.custom);
    final name =
        await ModelCacheService.displayNameFor(config.modelId) ??
        prettyModelId(config.modelId);
    if (!mounted || name == customModelName) return;
    setState(() => customModelName = name);
  }

  /// The models this reader has picked, for the composer's second menu.
  ///
  /// Source of truth is `user_model_providers` in Supabase: a model lands
  /// there as soon as a provider is pinned for it on the model screen, so
  /// "picked" needs no second table. The mode default and the model in use
  /// are always included — a menu that cannot show what is running would
  /// be worse than useless.
  Future<void> refreshPickedModels() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    // Offline first: the device snapshot paints the menu straight away,
    // even with no network and before the first sync of a cold start.
    final local = await ModelCacheService.loadProviderPreferences(user.id);
    await applyPickedModels(local);

    // Then the truth. `loadAllProviderPreferences` writes the snapshot back
    // on success, so a model unpinned on another device disappears here on
    // the next look instead of lingering until something else rewrote the
    // cache — which is how it lingered before.
    try {
      final remote = await UserPreferencesService.loadAllProviderPreferences();
      if (!mapEquals(remote, local)) await applyPickedModels(remote);
    } catch (_) {
      // No network: the snapshot already on screen is the best answer.
    }
  }

  /// Turn provider preferences into the menu's model list.
  Future<void> applyPickedModels(Map<String, String> prefs) async {
    final ids = <String>{
      // Each mode's own default model, so both stay reachable in the menu.
      ChatModeService.defaultConfig(ChatMode.fast).modelId,
      ChatModeService.defaultConfig(ChatMode.thinking).modelId,
      if (selectedModelId.isNotEmpty) selectedModelId,
      // Only models that still have a provider pinned. An empty slug means
      // the pin was taken away, and the model is no longer picked.
      for (final entry in prefs.entries)
        if (entry.value.trim().isNotEmpty) entry.key,
    };

    var catalogue = await ModelCacheService.loadAvailableModels();
    bool namesMissing(List<Map<String, dynamic>> list) {
      final known = {
        for (final model in list)
          if (model['id'] is String) model['id'] as String,
      };
      return ids.any((id) => !known.contains(id));
    }

    // A name the catalogue does not carry would be shown as the raw
    // OpenRouter slug. Fetch the list once instead of printing the id.
    if (catalogue.isEmpty || namesMissing(catalogue)) {
      await ModelPrefetchService.prefetch();
      catalogue = await ModelCacheService.loadAvailableModels();
    }

    final names = <String, String>{
      for (final model in catalogue)
        if (model['id'] is String && model['name'] is String)
          model['id'] as String: model['name'] as String,
    };

    final picked = <ChatModelChoice>[
      for (final id in ids)
        ChatModelChoice(id: id, name: names[id] ?? prettyModelId(id)),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (!mounted) return;
    setState(() {
      pickedModels = picked;
    });
  }

  // --- picking -------------------------------------------------------------

  /// The full model screen: add models, pin providers.
  Future<void> openModelScreen() async {
    final chatId = modelSelectionChatId;
    if (chatId != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<ChatModelSelection>(
          builder: (_) => ModelSelectorPage(chatId: chatId),
        ),
      );
      if (mounted) await hydrateChatModel();
      return;
    }
    // Only a genuinely new pick should flip the composer into Custom. Merely
    // browsing the screen — pinning a provider, retuning Fast/Thinking — must
    // leave the active mode untouched, so compare against the model in use.
    final String before = selectedModelId;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ModelSelectorPage()));
    if (!mounted) return;
    final selected = await UserPreferencesService.loadSelectedModel();
    if (mounted &&
        selected != null &&
        selected.isNotEmpty &&
        selected != before) {
      await applyModelSelection(selected);
    }
    await refreshPickedModels();
  }

  /// Switch mode, swapping in that mode's own model, provider and reasoning
  /// level. The next send uses them.
  Future<void> setChatMode(ChatMode mode) async {
    final chatId = modelSelectionChatId;
    if (chatId != null) {
      final config = await ChatModeService.loadConfig(mode);
      final provider = ModelSelectionDropdown.resolveProviderSlugForSend(
        config.modelId,
        config.providerSlug,
      );
      if (provider == null || provider.isEmpty) {
        if (mounted) showChatSnackBar('Choose a provider for this model');
        return;
      }
      await ChatModelSelectionService.instance.save(
        chatId,
        ChatModelSelection(modelId: config.modelId, providerSlug: provider),
      );
      if (!mounted || modelSelectionChatId != chatId) return;
      setState(() {
        chatMode = mode;
        reasoningEffort = config.reasoningEffort;
      });
      await hydrateChatModel();
      return;
    }
    await ChatModeService.save(mode);
    final config = await ChatModeService.loadConfig(mode);
    await applyModeConfig(mode, config);
  }

  /// Set the reasoning level for the active mode. The store clamps it to what
  /// the mode's stored provider allows and hands back the result, which is
  /// the single source of truth — adopt it rather than a locally clamped copy.
  Future<void> setReasoningEffort(String level) async {
    final config = await ChatModeService.setReasoningForMode(chatMode, level);
    if (!mounted) return;
    setState(() {
      reasoningEffort = config.reasoningEffort;
    });
  }

  /// The reasoning effort to actually send, clamped to what [modelId]'s real
  /// server-provided ladder allows. The stored [reasoningEffort] is already
  /// clamped whenever the model or level changes, but the catalog cache can
  /// hydrate after a send is queued (cold start) or the send may target a
  /// different model than the composer's (resend/continue), so clamp again at
  /// the send site — a level the model does not support must never leave here.
  String clampedReasoningEffort(String modelId, String? providerSlug) =>
      ChatModeService.sanitizeReasoningForModel(
        reasoningEffort,
        modelId: modelId,
        providerSlug: providerSlug ?? '',
      );

  /// Apply a model the reader picked directly. Picking a specific model IS the
  /// Custom mode — an arbitrary model at its own reasoning level. Fast and
  /// Thinking keep the models set on the model screen and are never
  /// overwritten from here, so the pick records against Custom and switches to
  /// it. Reload the pinned provider so model and provider cannot drift apart on
  /// the next send.
  Future<void> applyModelSelection(String modelId) async {
    final chatId = modelSelectionChatId;
    if (chatId != null) {
      var provider = await UserPreferencesService.loadSelectedProvider(modelId);
      provider ??= ModelSelectionDropdown.providerSlugForModel(modelId);
      if (provider == kAutoCheapestProviderSlug) {
        provider = ModelSelectionDropdown.resolveProviderSlugForSend(
          modelId,
          provider!,
        );
      }
      if (provider == null || provider.isEmpty) {
        final providers = ModelSelectionDropdown.availableProvidersForModel(
          modelId,
        );
        if (providers.isNotEmpty) provider = providers.first.slug;
      }
      if (provider == null || provider.isEmpty) {
        if (mounted) showChatSnackBar('Choose a provider for this model');
        return;
      }
      await ChatModelSelectionService.instance.save(
        chatId,
        ChatModelSelection(modelId: modelId, providerSlug: provider),
      );
      if (!mounted || modelSelectionChatId != chatId) return;
      setState(() => chatMode = ChatMode.custom);
      await hydrateChatModel();
      return;
    }
    setState(() {
      selectedModelId = modelId;
      chatMode = ChatMode.custom;
    });
    await ChatModeService.save(ChatMode.custom);
    ModelSelectionDropdown.selectedModelNotifier.value = modelId;
    await UserPreferencesService.saveSelectedModel(modelId);
    if (!mounted) return;
    await loadProviderSlugForModel(modelId, forceFromPrefs: true);
    final config = await ChatModeService.setModelForMode(
      ChatMode.custom,
      modelId: modelId,
      providerSlug: selectedProviderSlug ?? '',
    );
    if (mounted && config.reasoningEffort != reasoningEffort) {
      setState(() {
        reasoningEffort = config.reasoningEffort;
      });
    }
    await refreshSelectedModelName(modelId);
    await refreshCustomModelName();
    await refreshPickedModels();
  }

  // --- view ----------------------------------------------------------------

  Widget buildModelControl({
    required bool isCompactMode,
    required Color iconFg,
  }) {
    // Rebuild when capability data hydrates: the reasoning levels below are
    // read synchronously, so a cold start would otherwise keep the graded
    // ladder for a binary/non-reasoning model until an unrelated rebuild.
    return ValueListenableBuilder<int>(
      valueListenable: ModelCapabilitiesService.revision,
      builder: (context, _, _) => KeyedSubtree(
        key: TourKeyRegistry.instance.keyFor(TourSlots.modelDropdown),
        child: ChatModeSelector(
          mode: chatMode,
          showLabel: false,
          // The same height as every other target of the composer row (see
          // [ComposerMetrics.targetSize]); a label that is two pixels shorter
          // than the buttons beside it reads as a mistake.
          height: ComposerMetrics.targetSize,
          selectedModelId: selectedModelId,
          modelLabel:
              selectedModelName ??
              (selectedModelId.isEmpty ? null : selectedModelId),
          customModelLabel: customModelName,
          pickedModels: pickedModels,
          reasoningEffort: ChatModeService.sanitizeReasoningForModel(
            reasoningEffort,
            modelId: selectedModelId,
            providerSlug: selectedProviderSlug ?? '',
          ),
          // The picker options come straight from the server's per-model
          // `supported_efforts` (derived list only as a cold-start fallback),
          // so a level the model does not support can never be offered.
          reasoningLevels: ChatModeService.reasoningLevelsForModel(
            modelId: selectedModelId,
            // Before the provider resolves, use the mode's own default provider
            // so the derived fallback never briefly offers a wrong ladder.
            providerSlug: (selectedProviderSlug?.isNotEmpty ?? false)
                ? selectedProviderSlug!
                : ChatModeService.defaultConfig(chatMode).providerSlug,
          ),
          onReasoningEffortChanged: setReasoningEffort,
          onModeChanged: setChatMode,
          onModelSelected: applyModelSelection,
          onOpenModelScreen: openModelScreen,
        ),
      ),
    );
  }
}
