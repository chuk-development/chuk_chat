// lib/platform_specific/chat/chat_model_selection_mixin.dart
//
// Shared chat-mode / model / reasoning-level plumbing for the desktop and
// mobile chat States.
//
// The composer's mode pill, the model menu and every send read the same four
// things: the active [ChatMode], that mode's model id, its provider slug and
// its reasoning level. Both States kept a byte-identical copy of the fields and
// of the eleven methods that project a stored [ModeConfig] into them. This
// mixin owns them once.
//
// The state lives here as public fields rather than in the host State, so the
// two files need no bridge accessors. [ModelProviderResolutionMixin] declares
// [selectedModelId] and [selectedProviderSlug] as abstract; the fields below
// satisfy it, which is why this mixin lists it as a superclass constraint.

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, mapEquals;
import 'package:flutter/material.dart';

import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/pages/coworker_model_page.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/agents/coworker_model.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

mixin ChatModelSelectionMixin<W extends StatefulWidget>
    on State<W>, ModelProviderResolutionMixin<W> {
  /// The model the next send uses. Empty until the mode config is restored.
  @override
  String selectedModelId = '';

  /// The provider pinned for [selectedModelId], or null while unresolved.
  @override
  String? selectedProviderSlug;

  /// The active chat mode. Every mode carries its own model, provider and
  /// reasoning level, so switching modes swaps all four at once.
  @override
  ChatMode chatMode = ChatModeService.fallbackMode;

  /// The active mode's reasoning level (`none` … `xhigh`, `none` = off).
  /// Loaded from the mode's config; each mode remembers its own.
  String reasoningEffort = ChatModeService.defaultConfig(
    ChatModeService.fallbackMode,
  ).reasoningEffort;

  /// Human name of the selected model, for the mode menu. Null until the
  /// model list has been cached — the menu then shows the raw id.
  String? selectedModelName;

  /// Models the reader picked on the model screen, shown one level deeper.
  List<ChatModelChoice> pickedModels = const <ChatModelChoice>[];

  /// Human name of the model Custom last ran, remembered across mode switches
  /// so the third point in the mode menu names it even under Fast or Thinking.
  /// Null until Custom has been used at least once.
  String? customModelName;

  // --- Hooks the host State may override ---------------------------------

  /// True on the Agents thread screen. It restores its chat mode on every
  /// mount, so a save of the model id this process already wrote is skipped
  /// there (see [UserPreferencesService.saveSelectedModel]). chuk_chat's
  /// screen saves every time, in the Agents build too.
  bool get skipRepeatedModelSave => false;

  /// The chat on screen. Both chat States already provide it.
  String? get activeChatId;

  /// True where the chat on screen is a coworker's thread: its model,
  /// provider and reasoning level are the coworker's own
  /// ([ChatModelSelectionService]), not the account-wide mode. Those are
  /// exactly the screens that skip repeated model saves (the Agents thread
  /// on phone and desktop).
  bool get perCoworkerModel => skipRepeatedModelSave;

  /// The coworker thread whose own model this composer shows and changes.
  /// The phone State overrides this with its own (equivalent) answer.
  @override
  String? get modelSelectionChatId => perCoworkerModel ? activeChatId : null;

  /// Present the full model screen (add models, pin providers).
  ///
  /// The default pushes the standalone page — in a coworker's thread, the
  /// coworker's own model page, which is the profile's "Model" too. Desktop
  /// overrides this to prefer the redesigned settings modal, so "More models"
  /// and the settings menu land in the same place.
  Future<void> presentModelScreen() {
    final String? chatId = modelSelectionChatId;
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => chatId == null
            ? const ModelSelectorPage()
            : CoworkerModelPage(chatId: chatId),
      ),
    );
  }

  // --- A coworker's own model --------------------------------------------

  /// The chat [syncChatScopedModel] last looked at.
  String? _syncedChatId;

  /// True while the composer shows a coworker's own model rather than the
  /// account-wide mode, so dropping that model knows to put the mode back.
  bool _ownModelApplied = false;

  @override
  void initState() {
    super.initState();
    ChatModelSelectionService.instance.addListener(_onCoworkerModelChanged);
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!perCoworkerModel && _syncedChatId == null) return;
    // The host State moves its chat id in its own didUpdateWidget, after this
    // one; look once the frame is done.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && modelSelectionChatId != _syncedChatId) {
        unawaited(syncChatScopedModel());
      }
    });
  }

  @override
  void dispose() {
    ChatModelSelectionService.instance.removeListener(_onCoworkerModelChanged);
    super.dispose();
  }

  void _onCoworkerModelChanged() {
    if (!mounted || modelSelectionChatId == null) return;
    unawaited(syncChatScopedModel().catchError((Object _) {}));
  }

  @override
  void onChatScopedModelMismatch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(syncChatScopedModel().catchError((Object _) {}));
    });
  }

  /// Puts the coworker's own model, provider and reasoning level into the
  /// composer, so the pill names what the next send runs on. With no own
  /// model the composer keeps — or gets back — the account-wide mode.
  ///
  /// The own model shows as Custom: that is what it is, one specific model,
  /// and the pill then names it. The account-wide mode is not written.
  Future<void> syncChatScopedModel() async {
    final String? chatId = modelSelectionChatId;
    _syncedChatId = chatId;
    if (chatId == null) return;
    final own = await ChatModelSelectionService.instance.load(chatId);
    if (!mounted || modelSelectionChatId != chatId) return;
    if (own == null) {
      if (!_ownModelApplied) return;
      _ownModelApplied = false;
      final mode = await ChatModeService.load();
      final config = await ChatModeService.loadConfig(mode);
      if (!mounted || modelSelectionChatId != chatId) return;
      await applyModeConfig(mode, config);
      return;
    }
    _ownModelApplied = true;
    final String effort = ChatModeService.sanitizeReasoningForModel(
      own.reasoningEffort ?? reasoningEffort,
      modelId: own.modelId,
      providerSlug: own.providerSlug,
    );
    if (chatMode == ChatMode.custom &&
        selectedModelId == own.modelId &&
        selectedProviderSlug == own.providerSlug &&
        reasoningEffort == effort) {
      return;
    }
    setState(() {
      chatMode = ChatMode.custom;
      selectedModelId = own.modelId;
      selectedProviderSlug = own.providerSlug;
      reasoningEffort = effort;
    });
    await refreshSelectedModelName(own.modelId);
  }

  /// The provider the coworker's model runs on now, for a write that keeps
  /// the model and changes something else.
  Future<String?> _currentProviderFor(String modelId) async {
    final String? shown = selectedProviderSlug;
    if (modelId == selectedModelId && shown != null && shown.isNotEmpty) {
      return ModelSelectionDropdown.resolveProviderSlugForSend(modelId, shown);
    }
    return CoworkerModel.providerFor(modelId);
  }

  /// A model picked in a coworker's composer becomes that coworker's own
  /// model, at the level it already runs at.
  Future<void> _pickCoworkerModel(String chatId, String modelId) async {
    final own = await ChatModelSelectionService.instance.load(chatId);
    String? provider = own?.modelId == modelId
        ? own!.providerSlug
        : await CoworkerModel.providerFor(modelId);
    if (provider == null) {
      // A cold catalogue: fetch it once and ask again.
      await ModelPrefetchService.prefetch();
      provider = await CoworkerModel.providerFor(modelId);
    }
    if (!mounted || provider == null || provider.isEmpty) return;
    await CoworkerModel.setOwn(
      chatId,
      modelId: modelId,
      providerSlug: provider,
      reasoningEffort: own?.reasoningEffort ?? reasoningEffort,
    );
    if (!mounted) return;
    await syncChatScopedModel();
    await refreshPickedModels();
  }

  // --- Shared logic -------------------------------------------------------

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

  /// The full model screen: add models, pin providers.
  Future<void> openModelScreen() async {
    if (modelSelectionChatId != null) {
      // The coworker's model page writes the coworker's own record; read it
      // back rather than the account-wide model.
      await presentModelScreen();
      if (!mounted) return;
      await syncChatScopedModel();
      await refreshPickedModels();
      return;
    }
    // Only a genuinely new pick should flip the composer into Custom. Merely
    // browsing the screen — pinning a provider, retuning Fast/Thinking — must
    // leave the active mode untouched, so compare against the model in use.
    final String before = selectedModelId;
    await presentModelScreen();
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
  ///
  /// In a coworker's thread, Fast and Thinking are the app defaults: picking
  /// one drops the coworker's own model, so it follows that default.
  Future<void> setChatMode(ChatMode mode) async {
    final String? chatId = modelSelectionChatId;
    if (chatId != null) {
      _ownModelApplied = false;
      await CoworkerModel.useDefault(chatId);
      if (!mounted) return;
    }
    await ChatModeService.save(mode);
    final config = await ChatModeService.loadConfig(mode);
    await applyModeConfig(mode, config);
  }

  /// Set the reasoning level for the active mode. The store clamps it to what
  /// the mode's stored provider allows and hands back the result, which is
  /// the single source of truth — adopt it rather than a locally clamped copy.
  ///
  /// In a coworker's thread the level is the coworker's own: it is stored
  /// with the coworker's model (which the coworker then has, if it followed
  /// the default until now), and the account-wide mode is not touched.
  Future<void> setReasoningEffort(String level) async {
    final String? chatId = modelSelectionChatId;
    if (chatId != null) {
      final own = await ChatModelSelectionService.instance.load(chatId);
      final String modelId = own?.modelId ?? selectedModelId;
      final String? provider =
          own?.providerSlug ?? await _currentProviderFor(modelId);
      if (!mounted) return;
      if (modelId.isNotEmpty && provider != null && provider.isNotEmpty) {
        final saved = await CoworkerModel.setOwn(
          chatId,
          modelId: modelId,
          providerSlug: provider,
          reasoningEffort: level,
        );
        if (!mounted) return;
        setState(() {
          reasoningEffort = saved.reasoningEffort ?? level;
        });
        await syncChatScopedModel();
        return;
      }
    }
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
  ///
  /// In a coworker's thread the pick is the coworker's own model instead; the
  /// account-wide Custom slot is left alone.
  Future<void> applyModelSelection(String modelId) async {
    final String? chatId = modelSelectionChatId;
    if (chatId != null) {
      await _pickCoworkerModel(chatId, modelId);
      return;
    }
    setState(() {
      selectedModelId = modelId;
      chatMode = ChatMode.custom;
    });
    await ChatModeService.save(ChatMode.custom);
    ModelSelectionDropdown.selectedModelNotifier.value = modelId;
    await UserPreferencesService.saveSelectedModel(
      modelId,
      skipIfUnchanged: skipRepeatedModelSave,
    );
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

  /// Bring back the mode the reader last used, and with it that mode's own
  /// model, provider and reasoning level. The mode config is the single
  /// source of truth for what a send uses; this projects it into the live
  /// fields and keeps the shared selected-model plumbing in step.
  Future<void> restoreChatMode() async {
    final mode = await ChatModeService.load();
    final config = await ChatModeService.loadConfig(mode);
    await applyModeConfig(mode, config);
    // A coworker's own model sits on top of the mode it just restored.
    _ownModelApplied = false;
    if (mounted) await syncChatScopedModel();
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
    await UserPreferencesService.saveSelectedModel(
      config.modelId,
      skipIfUnchanged: skipRepeatedModelSave,
    );
    // Fast and Thinking keep their own provider, which the lookup below
    // prefers; the per-model pin applies only in custom mode or when the mode
    // pins nothing. Awaited so it cannot race the unawaited read the
    // model-selection listener starts from the notifier above.
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

  /// Load the user's saved model preference.
  ///
  /// The active mode's config is the single source of truth for the model,
  /// provider and reasoning level. It always yields a model (baked defaults),
  /// so this simply projects it — no separate saved-vs-default branch to keep
  /// in step.
  Future<void> loadSavedModelPreference() async {
    try {
      await restoreChatMode();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading saved model preference: $e');
      }
    }
  }
}
