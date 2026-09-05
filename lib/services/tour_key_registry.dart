// lib/services/tour_key_registry.dart
//
// Singleton registry that hands out stable [GlobalKey]s for UI elements the
// interactive onboarding tour wants to point at (model dropdown, menu button,
// settings entry, chat input).
//
// Widgets attach the key via `KeyedSubtree(key: TourKeyRegistry.instance
// .keyFor('slot'), child: ...)` (or directly as `key:` when the widget has
// no existing key). The [OnboardingTourController] uses the key's
// `currentContext` to find a [RenderBox] and project a pulsing pointer +
// banner over the real widget.

import 'package:flutter/widgets.dart';

/// Known target slots used by the onboarding tour.
class TourSlots {
  static const String modelDropdown = 'model_dropdown';
  static const String modelProviderPill = 'model_provider_pill';
  static const String menuButton = 'menu_button';
  static const String settingsEntry = 'settings_entry';
  static const String chatInput = 'chat_input';
  static const String settingsPricingTile = 'settings_pricing_tile';
  static const String settingsAiIdentityTile = 'settings_ai_identity_tile';
  static const String settingsModelSelectionTile =
      'settings_model_selection_tile';

  const TourSlots._();
}

/// Singleton store of [GlobalKey]s by slot name. Always returns the SAME
/// key for the same slot so widgets that re-build keep a stable identity.
class TourKeyRegistry {
  TourKeyRegistry._();

  /// Shared instance.
  static final TourKeyRegistry instance = TourKeyRegistry._();

  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  /// Returns the [GlobalKey] for [slot], creating it lazily on first access.
  GlobalKey keyFor(String slot) =>
      _keys.putIfAbsent(slot, () => GlobalKey(debugLabel: 'tour:$slot'));

  /// Returns the current [BuildContext] mounted under [slot], or null if the
  /// widget isn't currently in the tree.
  BuildContext? contextFor(String slot) => _keys[slot]?.currentContext;

  /// True when [slot] is mounted in the widget tree right now.
  bool isMounted(String slot) {
    final ctx = _keys[slot]?.currentContext;
    if (ctx == null) return false;
    final ro = ctx.findRenderObject();
    return ro is RenderBox && ro.hasSize;
  }

  /// True when [slot] is mounted AND visible on screen — i.e. its top-left
  /// global position is within (or just outside) the viewport bounds.
  /// Distinguishes "mounted but translated offscreen" (drawer/sidebar that
  /// slides in) from "mounted and visible".
  bool isVisibleOnScreen(String slot, Size screenSize) {
    final ctx = _keys[slot]?.currentContext;
    if (ctx == null) return false;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return false;
    final pos = ro.localToGlobal(Offset.zero);
    // Tolerate a tiny epsilon — animations can momentarily land at -0.5px.
    return pos.dx > -1.0 &&
        pos.dy > -1.0 &&
        pos.dx < screenSize.width &&
        pos.dy < screenSize.height;
  }

  /// Drops every registered key. Intended for tests.
  @visibleForTesting
  void clear() => _keys.clear();
}
