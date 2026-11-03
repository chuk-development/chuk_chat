import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/provider_resolution_service.dart';

/// Shared model → provider-slug resolution for the desktop and mobile chat UIs.
///
/// The storage for [selectedModelId] / [selectedProviderSlug] lives in
/// `ChatModelSelectionMixin`, which both chat States mix in alongside this one;
/// this mixin owns the lookup and fallback logic.
mixin ModelProviderResolutionMixin<T extends StatefulWidget> on State<T> {
  /// The currently selected model id (host-provided).
  String get selectedModelId;

  /// The resolved provider slug for the current model (host-provided storage).
  String? get selectedProviderSlug;
  set selectedProviderSlug(String? value);

  /// The active chat mode. Hosts without modes resolve like custom mode:
  /// only the per-model pin applies.
  ChatMode get chatMode => ChatMode.custom;

  /// Optional chat override. Unscoped legacy hosts retain account defaults.
  String? get modelSelectionChatId => null;

  /// Called when a provider lookup finds that the chat has its own model and
  /// it is not the model on screen: something (a mode restore, the global
  /// model notifier) put another model into a chat that has its own. The
  /// default does nothing; `ChatModelSelectionMixin` puts the chat's own model
  /// back, so the composer never shows a model the send will not use.
  void onChatScopedModelMismatch() {}

  /// The provider the active Fast or Thinking mode pins for [modelId], or
  /// null when the mode is custom, runs another model, or pins nothing.
  ///
  /// A mode's own provider wins over the per-model pin: Fast and Thinking
  /// can run the same model through different providers, and the per-model
  /// pin would otherwise silently replace the one picked for the mode.
  Future<String?> modeProviderSlugFor(String modelId) async {
    final ChatMode mode = chatMode;
    if (mode == ChatMode.custom || modelId.isEmpty) return null;
    final ModeConfig config = await ChatModeService.loadConfig(mode);
    if (config.modelId != modelId || config.providerSlug.isEmpty) return null;
    return config.providerSlug;
  }

  bool get modelSupportsImageInput =>
      ChatUiHelpers.modelSupportsImageInput(selectedModelId);

  /// Resolve and cache the provider slug for [modelId]. Prefers the in-memory
  /// dropdown mapping, then the persisted user preference. Pass
  /// [forceFromPrefs] to skip the dropdown mapping (e.g. after the user
  /// explicitly re-picked a provider).
  Future<void> loadProviderSlugForModel(
    String modelId, {
    bool forceFromPrefs = false,
  }) async {
    final chatId = modelSelectionChatId;
    final ChatMode requestedMode = chatMode;
    // A later chat, mode or model switch makes this lookup obsolete; its
    // result must not overwrite the provider of the newer selection.
    bool isStale() =>
        !mounted ||
        modelSelectionChatId != chatId ||
        chatMode != requestedMode ||
        selectedModelId != modelId;
    if (chatId != null) {
      final choice = await ChatModelSelectionService.instance.load(chatId);
      if (isStale()) return;
      if (choice != null && choice.modelId == modelId) {
        if (selectedProviderSlug != choice.providerSlug) {
          setState(() => selectedProviderSlug = choice.providerSlug);
        }
        return;
      }
      if (choice != null) {
        // The send resolves the chat's own pair again, so a provider looked up
        // for this foreign model would only be a label that lies.
        onChatScopedModelMismatch();
        return;
      }
    }
    if (modelId.isEmpty) {
      if (selectedProviderSlug != null) {
        setState(() {
          selectedProviderSlug = null;
        });
      }
      return;
    }

    final String? modeSlug = await modeProviderSlugFor(modelId);
    if (isStale()) return;
    if (modeSlug != null) {
      if (selectedProviderSlug != modeSlug) {
        setState(() {
          selectedProviderSlug = modeSlug;
        });
      }
      return;
    }

    if (!forceFromPrefs) {
      final String? dropdownSlug = ModelSelectionDropdown.providerSlugForModel(
        modelId,
      );
      if (dropdownSlug != null && dropdownSlug.isNotEmpty) {
        if (selectedProviderSlug != dropdownSlug) {
          setState(() {
            selectedProviderSlug = dropdownSlug;
          });
        }
        return;
      }
    }

    final String? loadedSlug =
        await UserPreferencesService.loadSelectedProvider(modelId);
    if (isStale()) return;
    if (selectedProviderSlug != loadedSlug) {
      setState(() {
        selectedProviderSlug = loadedSlug;
      });
    }
  }

  /// Resolve the provider slug to actually send with, falling back through the
  /// cache, prefs, and the model catalogue, and resolving the "auto cheapest"
  /// marker at send time. Never returns the marker. Returns null only if no
  /// provider at all is known for the model.
  Future<String?> ensureProviderSlugForCurrentModel() async {
    final chatId = modelSelectionChatId;
    if (chatId != null) {
      final choice = await ChatModelSelectionService.instance.load(chatId);
      if (choice != null) {
        return ProviderResolutionService.resolveForSend(
          choice.modelId,
          choice.providerSlug,
        );
      }
      if (!mounted || modelSelectionChatId != chatId) return null;
    }
    final String modelId = selectedModelId;
    if (modelId.isEmpty) return null;

    // Re-read the mode's provider at send time: the cached slug can be stale
    // when the provider was changed in settings while this chat stayed open.
    String? slug = await modeProviderSlugFor(modelId);
    if (!mounted) return null;
    if (slug != null && selectedProviderSlug != slug) {
      setState(() {
        selectedProviderSlug = slug;
      });
    }
    slug ??= (selectedProviderSlug != null && selectedProviderSlug!.isNotEmpty)
        ? selectedProviderSlug
        : null;

    if (slug == null) {
      await loadProviderSlugForModel(modelId);
      if (!mounted) return null;
      slug = selectedProviderSlug;
    }

    // Auto, or nothing stored at all (prefs unreachable after a network
    // glitch): the cheapest provider from the model catalogue. The stored
    // choice is left as it is, so Auto stays Auto for the next send.
    final String? resolved = await ProviderResolutionService.resolveForSend(
      modelId,
      slug,
    );
    if (kDebugMode && (slug == null || slug.isEmpty) && resolved != null) {
      debugPrint('Provider fallback: cheapest for $modelId (nothing stored)');
    }
    return resolved;
  }
}
