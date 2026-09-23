import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

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

  /// The active chat mode (host-provided).
  ChatMode get chatMode;

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
    if (modelId.isEmpty) {
      if (selectedProviderSlug != null) {
        setState(() {
          selectedProviderSlug = null;
        });
      }
      return;
    }

    final String? modeSlug = await modeProviderSlugFor(modelId);
    if (!mounted) return;
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

    final String? loadedSlug = await UserPreferencesService.loadSelectedProvider(
      modelId,
    );
    if (!mounted) return;
    if (selectedProviderSlug != loadedSlug) {
      setState(() {
        selectedProviderSlug = loadedSlug;
      });
    }
  }

  /// Resolve the provider slug to actually send with, falling back through the
  /// cache, prefs, and the static in-memory providers list, and resolving the
  /// "auto cheapest" sentinel at send time. Returns null if nothing resolves.
  Future<String?> ensureProviderSlugForCurrentModel() async {
    if (selectedModelId.isEmpty) return null;

    // Re-read the mode's provider at send time: the cached slug can be stale
    // when the provider was changed in settings while this chat stayed open.
    String? slug = await modeProviderSlugFor(selectedModelId);
    if (!mounted) return null;
    if (slug != null && selectedProviderSlug != slug) {
      setState(() {
        selectedProviderSlug = slug;
      });
    }
    slug ??=
        (selectedProviderSlug != null && selectedProviderSlug!.isNotEmpty)
        ? selectedProviderSlug
        : null;

    if (slug == null) {
      await loadProviderSlugForModel(selectedModelId);
      slug = selectedProviderSlug;
    }

    // Third fallback: the dropdown/prefs lookups can both fail after a
    // network glitch (cache cleared / Supabase request timing out). Use the
    // static in-memory providers list known for the model — it survives
    // transient network issues because it was hydrated at startup.
    if (slug == null || slug.isEmpty) {
      final providers = ModelSelectionDropdown.availableProvidersForModel(
        selectedModelId,
      );
      if (providers.isNotEmpty) {
        final fallback = providers.first.slug;
        if (kDebugMode) {
          debugPrint(
            'Provider fallback: using $fallback for $selectedModelId (cache miss)',
          );
        }
        if (mounted && selectedProviderSlug != fallback) {
          setState(() {
            selectedProviderSlug = fallback;
          });
        }
        slug = fallback;
      }
    }

    if (slug == null || slug.isEmpty) return null;

    // Resolve "auto" sentinel at send time so the cheapest current provider
    // is used without overwriting the user's preference.
    if (slug == kAutoCheapestProviderSlug) {
      final resolved = ModelSelectionDropdown.resolveProviderSlugForSend(
        selectedModelId,
        slug,
      );
      return (resolved != null && resolved.isNotEmpty) ? resolved : null;
    }
    return slug;
  }
}
