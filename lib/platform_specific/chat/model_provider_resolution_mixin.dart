import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

/// Shared model → provider-slug resolution for the desktop and mobile chat UIs.
///
/// The host State keeps its own `_selectedModelId` / `_selectedProviderSlug`
/// fields and wires them up through [selectedModelId] / [selectedProviderSlug];
/// this mixin owns the (previously duplicated) lookup/fallback logic.
mixin ModelProviderResolutionMixin<T extends StatefulWidget> on State<T> {
  /// The currently selected model id (host-provided).
  String get selectedModelId;

  /// The resolved provider slug for the current model (host-provided storage).
  String? get selectedProviderSlug;
  set selectedProviderSlug(String? value);

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

    String? slug =
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
