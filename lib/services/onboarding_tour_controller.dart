// lib/services/onboarding_tour_controller.dart
//
// Interactive guided tour. The tour does NOT auto-navigate. Instead it pulses
// a pointer ring over the real UI target (model dropdown, menu button,
// settings entry, chat input) and shows a small instructional banner. The
// user taps the highlighted element themselves; route changes detected by
// the attached [_TourNavigatorObserver] drive the state machine forward.
//
// The overlay lives in the ROOT navigator's overlay so it stays visible
// across pushed routes (model picker, settings page) and pops back to the
// chat root.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Step in the interactive tour state machine.
enum _Step {
  welcome, // 1
  pointerModel, // 2  pulsing ring on model dropdown
  pointerProviderPill, // 3  pulsing ring on first provider pill on model page
  pointerMenu, // 4  pulsing ring on menu button (auto-advances on drawer open)
  pointerSettings, // 5  pulsing ring on settings tile inside open drawer
  settingsPage, // 6  banner on SettingsPage
  pointerSettingsPricing, // 7  pulsing ring on Pricing tile
  pointerSettingsAiIdentity, // 8  pulsing ring on AI Identity tile
  finale, // 9
}

/// Navigator observer the controller installs on the root navigator. It
/// forwards push/pop events back to the controller so route changes the
/// USER caused (tapping the highlighted dropdown, popping back) drive the
/// tour state machine.
class TourNavigatorObserver extends NavigatorObserver {
  TourNavigatorObserver();

  void Function(Route<dynamic> route, Route<dynamic>? previousRoute)? _onPush;
  void Function(Route<dynamic> route, Route<dynamic>? previousRoute)? _onPop;

  void attach({
    required void Function(Route<dynamic>, Route<dynamic>?) onPush,
    required void Function(Route<dynamic>, Route<dynamic>?) onPop,
  }) {
    _onPush = onPush;
    _onPop = onPop;
  }

  void detach() {
    _onPush = null;
    _onPop = null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _onPush?.call(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _onPop?.call(route, previousRoute);
  }
}

/// Singleton controller for the interactive onboarding tour.
class OnboardingTourController {
  OnboardingTourController._();

  /// Shared instance.
  static final OnboardingTourController instance =
      OnboardingTourController._();

  /// Shared navigator observer. Install once on [MaterialApp]
  /// `navigatorObservers`. The controller wires/unwires its handlers as the
  /// tour starts and stops.
  static final TourNavigatorObserver navigatorObserver =
      TourNavigatorObserver();

  OverlayEntry? _overlayEntry;
  NavigatorState? _navigator;
  _Step _step = _Step.welcome;
  bool _active = false;
  Timer? _mountWatchTimer;

  /// Whether the tour is currently being shown.
  bool get isActive => _active;

  /// Start the tour. Safe to call multiple times — no-op while active.
  ///
  /// [shellConfig] is accepted for backwards compatibility with the previous
  /// auto-navigating controller; the new interactive tour does not navigate
  /// on the user's behalf so the config is not stored.
  Future<void> start(
    BuildContext context, {
    required AppShellConfig shellConfig,
  }) async {
    if (_active) return;
    // shellConfig is intentionally unused now — kept in the signature so the
    // settings-page replay tile and first-launch gate don't need to change.
    final _ = shellConfig;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!navigator.mounted) return;
    _navigator = navigator;
    _active = true;
    _step = _Step.welcome;
    navigatorObserver.attach(
      onPush: _handleRoutePushed,
      onPop: _handleRoutePopped,
    );
    _showOverlay();
  }

  /// Force tear-down (e.g. on sign-out). Does NOT mark onboarding completed.
  void cancel() {
    _teardown(markCompleted: false);
  }

  void _finish({required bool markCompleted}) {
    _teardown(markCompleted: markCompleted);
  }

  void _teardown({required bool markCompleted}) {
    _stopMountWatch();
    _disposeOverlay();
    navigatorObserver.detach();
    _active = false;
    _navigator = null;
    _step = _Step.welcome;
    if (markCompleted) {
      AppThemeService.instance.setOnboardingCompleted(true).catchError((error) {
        if (kDebugMode) {
          debugPrint('[OnboardingTour] Persist completion failed: $error');
        }
      });
    }
  }

  // ── Route detection ─────────────────────────────────────────────────────
  //
  // Push sites for SettingsPage and ModelSelectorPage tag their RouteSettings
  // with `tour:settings` / `tour:model_selector`. We identify them by name
  // only — no reflection or closure introspection.
  //
  // The chat-header model dropdown is a [PopupMenuButton] — tapping it pushes
  // a [PopupRoute], not [ModelSelectorPage]. We treat any new route appearing
  // while we're pointing at the model dropdown as the "user tapped" signal.

  static const String _tourSettingsRoute = 'tour:settings';
  static const String _tourModelSelectorRoute = 'tour:model_selector';

  void _handleRoutePushed(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_active) return;
    final name = route.settings.name;

    if (_step == _Step.pointerMenu || _step == _Step.pointerSettings) {
      if (name == _tourSettingsRoute) {
        _goTo(_Step.settingsPage);
        return;
      }
    }

    // Model picker: the in-header dropdown opens a popup. Treat ANY route
    // push (popup OR navigated page) while pointing at the dropdown as the
    // "user tapped" signal. Move directly to the provider-pill pointer —
    // we no longer show a separate page-level banner.
    if (_step == _Step.pointerModel) {
      _goTo(_Step.pointerProviderPill);
      return;
    }
  }

  void _handleRoutePopped(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_active) return;
    final name = route.settings.name;

    if (name == _tourModelSelectorRoute) {
      if (_step == _Step.pointerProviderPill ||
          _step == _Step.pointerModel) {
        _goTo(_Step.pointerMenu);
        return;
      }
    }

    if (name == _tourSettingsRoute) {
      if (_step == _Step.settingsPage ||
          _step == _Step.pointerSettings ||
          _step == _Step.pointerMenu ||
          _step == _Step.pointerSettingsPricing ||
          _step == _Step.pointerSettingsAiIdentity) {
        _goTo(_Step.finale);
        return;
      }
    }

    // The dropdown popup just closed. Advance from the provider-pill pointer
    // to the menu pointer (the user picked a model and is back on chat).
    if (_step == _Step.pointerProviderPill) {
      _goTo(_Step.pointerMenu);
      return;
    }
  }

  // ── State transitions ───────────────────────────────────────────────────

  void _goTo(_Step next) {
    if (!_active) return;
    _step = next;
    // Rebuild overlay against the new step.
    _refreshOverlay();

    // While pointing at the menu button, the drawer/sidebar opening is NOT a
    // route push, so the NavigatorObserver won't fire. Poll the registry: as
    // soon as the settings entry mounts (drawer animated open), advance.
    if (next == _Step.pointerMenu) {
      _startMountWatch(
        slot: TourSlots.settingsEntry,
        whileStep: _Step.pointerMenu,
        nextStep: _Step.pointerSettings,
      );
    } else {
      _stopMountWatch();
    }
  }

  void _startMountWatch({
    required String slot,
    required _Step whileStep,
    required _Step nextStep,
  }) {
    _stopMountWatch();
    _mountWatchTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_active || _step != whileStep) {
        _stopMountWatch();
        return;
      }
      if (TourKeyRegistry.instance.isMounted(slot)) {
        _stopMountWatch();
        _goTo(nextStep);
      }
    });
  }

  void _stopMountWatch() {
    _mountWatchTimer?.cancel();
    _mountWatchTimer = null;
  }

  void _onContinuePressed() {
    if (!_active) return;
    switch (_step) {
      case _Step.welcome:
        _goTo(_Step.pointerModel);
        break;
      case _Step.settingsPage:
        _goTo(_Step.pointerSettingsPricing);
        break;
      case _Step.pointerSettingsPricing:
        _goTo(_Step.pointerSettingsAiIdentity);
        break;
      case _Step.pointerSettingsAiIdentity:
        _goTo(_Step.finale);
        break;
      case _Step.finale:
        // Return the user to chat root before tearing down.
        final navigator = _navigator;
        if (navigator != null && navigator.mounted && navigator.canPop()) {
          navigator.popUntil((route) => route.isFirst);
        }
        _finish(markCompleted: true);
        break;
      // Pointer-only steps don't render Continue.
      case _Step.pointerModel:
      case _Step.pointerProviderPill:
      case _Step.pointerMenu:
      case _Step.pointerSettings:
        break;
    }
  }

  void _onSkipPressed() {
    final navigator = _navigator;
    if (navigator != null && navigator.mounted && navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
    _finish(markCompleted: true);
  }

  // ── Overlay management ──────────────────────────────────────────────────

  void _showOverlay() {
    final navigator = _navigator;
    if (navigator == null || !navigator.mounted) return;
    final overlay = navigator.overlay;
    if (overlay == null) return;

    final entry = OverlayEntry(builder: _buildOverlayContent);
    _overlayEntry = entry;
    overlay.insert(entry);
  }

  void _refreshOverlay() {
    _overlayEntry?.markNeedsBuild();
  }

  void _disposeOverlay() {
    final entry = _overlayEntry;
    _overlayEntry = null;
    if (entry == null) return;
    try {
      if (entry.mounted) entry.remove();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[OnboardingTour] Overlay remove failed: $error');
      }
    }
    entry.dispose();
  }

  Widget _buildOverlayContent(BuildContext context) {
    // Welcome and finale are modal cards.
    if (_step == _Step.welcome) {
      return _TourModalCard(
        showLogo: true,
        onPrimary: _onContinuePressed,
        onSkip: _onSkipPressed,
        bodyKind: _BodyKind.welcome,
      );
    }
    if (_step == _Step.finale) {
      return _TourModalCard(
        showLogo: false,
        onPrimary: _onContinuePressed,
        onSkip: null,
        bodyKind: _BodyKind.finale,
      );
    }
    // SettingsPage step renders a banner only (no pointer needed).
    if (_step == _Step.settingsPage) {
      return _TourBannerOverlay(
        slot: null,
        bodyKind: _BodyKind.settingsPage,
        showContinue: true,
        onContinue: _onContinuePressed,
        onSkip: _onSkipPressed,
      );
    }

    // Pointer steps. The settings sub-tour pointers (pricing + AI identity)
    // are informational and rely on Continue. The other pointers advance
    // when the user taps the highlighted target.
    final slot = _slotFor(_step);
    final bodyKind = _bodyKindFor(_step);
    final canShowContinue = _step == _Step.pointerSettingsPricing ||
        _step == _Step.pointerSettingsAiIdentity;
    return _TourBannerOverlay(
      slot: slot,
      bodyKind: bodyKind,
      showContinue: canShowContinue,
      onContinue: _onContinuePressed,
      onSkip: _onSkipPressed,
    );
  }

  String? _slotFor(_Step step) {
    switch (step) {
      case _Step.pointerModel:
        return TourSlots.modelDropdown;
      case _Step.pointerProviderPill:
        return TourSlots.modelProviderPill;
      case _Step.pointerMenu:
        return TourSlots.menuButton;
      case _Step.pointerSettings:
        return TourSlots.settingsEntry;
      case _Step.pointerSettingsPricing:
        return TourSlots.settingsPricingTile;
      case _Step.pointerSettingsAiIdentity:
        return TourSlots.settingsAiIdentityTile;
      default:
        return null;
    }
  }

  _BodyKind _bodyKindFor(_Step step) {
    switch (step) {
      case _Step.pointerModel:
        return _BodyKind.pointerModel;
      case _Step.pointerProviderPill:
        return _BodyKind.pointerProviderPill;
      case _Step.pointerMenu:
        return _BodyKind.pointerMenu;
      case _Step.pointerSettings:
        return _BodyKind.pointerSettings;
      case _Step.pointerSettingsPricing:
        return _BodyKind.pointerSettingsPricing;
      case _Step.pointerSettingsAiIdentity:
        return _BodyKind.pointerSettingsAiIdentity;
      default:
        return _BodyKind.welcome;
    }
  }
}

/// Marker for which copy block the banner should show.
enum _BodyKind {
  welcome,
  settingsPage,
  finale,
  pointerModel,
  pointerProviderPill,
  pointerMenu,
  pointerSettings,
  pointerSettingsPricing,
  pointerSettingsAiIdentity,
}

// ── Overlay widgets ───────────────────────────────────────────────────────

/// Welcome / finale full-screen card with a scrim.
class _TourModalCard extends StatelessWidget {
  const _TourModalCard({
    required this.showLogo,
    required this.onPrimary,
    required this.onSkip,
    required this.bodyKind,
  });

  final bool showLogo;
  final VoidCallback onPrimary;
  final VoidCallback? onSkip;
  final _BodyKind bodyKind;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    String title;
    String body;
    String primary;
    switch (bodyKind) {
      case _BodyKind.welcome:
        title = l.tourWelcomeTitle;
        body = l.tourWelcomeBody;
        primary = l.tourGetStarted;
        break;
      case _BodyKind.finale:
        title = l.tourDoneTitle;
        body = l.tourDoneBody;
        primary = l.tourFinish;
        break;
      default:
        title = l.tourWelcomeTitle;
        body = l.tourWelcomeBody;
        primary = l.tourContinue;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Container(color: Colors.black.withValues(alpha: 0.55)),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  decoration: BoxDecoration(
                    color: m3.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: m3.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.30),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showLogo)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Container(
                            width: 72,
                            height: 72,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: m3.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: SvgPicture.asset(
                              'assets/logo.svg',
                              colorFilter: ColorFilter.mode(
                                cs.onSurface,
                                BlendMode.srcIn,
                              ),
                            ),
                          ),
                        ),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        body,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: m3.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: onPrimary,
                        style: FilledButton.styleFrom(
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        child: Text(
                          primary,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (onSkip != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: TextButton(
                            onPressed: onSkip,
                            style: TextButton.styleFrom(
                              foregroundColor: m3.onSurfaceVariant,
                            ),
                            child: Text(
                              l.tourSkip,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Overlay shown for pointer + page-banner steps. Reads the target slot's
/// [GlobalKey] every frame and floats a pulsing ring + nearby banner. The
/// ring/scrim never blocks taps on the target — only the banner buttons
/// receive input.
class _TourBannerOverlay extends StatefulWidget {
  const _TourBannerOverlay({
    required this.slot,
    required this.bodyKind,
    required this.showContinue,
    required this.onContinue,
    required this.onSkip,
  });

  /// Null when no pointer should be drawn (page-level banner steps).
  final String? slot;
  final _BodyKind bodyKind;
  final bool showContinue;
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  @override
  State<_TourBannerOverlay> createState() => _TourBannerOverlayState();
}

class _TourBannerOverlayState extends State<_TourBannerOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  Rect? _targetRect;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  void _onTick(Duration _) {
    final slot = widget.slot;
    if (slot == null) {
      if (_targetRect != null && mounted) {
        setState(() => _targetRect = null);
      }
      return;
    }
    final ctx = TourKeyRegistry.instance.contextFor(slot);
    final ro = ctx?.findRenderObject();
    if (ctx == null || ro is! RenderBox || !ro.hasSize) {
      if (_targetRect != null && mounted) {
        setState(() => _targetRect = null);
      }
      return;
    }
    final topLeft = ro.localToGlobal(Offset.zero);
    final rect = topLeft & ro.size;
    if (_targetRect == null || _targetRect != rect) {
      if (mounted) {
        setState(() => _targetRect = rect);
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    final String headline = _headlineFor(widget.bodyKind, l);
    final String body = _bodyFor(widget.bodyKind, l);

    // Banner positioning: if a target rect exists, anchor near it; otherwise
    // pin to the top of the screen.
    final rect = _targetRect;
    final screenH = mq.size.height;
    final screenW = mq.size.width;

    // Compute banner y position. Below the target if it's in the top half;
    // otherwise above. If no target, sit at the top.
    const double bannerVertGap = 14;
    const double bannerH = 120;
    double bannerTop;
    if (rect == null) {
      bannerTop = mq.padding.top + 14;
    } else {
      final targetMid = rect.center.dy;
      if (targetMid < screenH / 2) {
        // Below target
        bannerTop = rect.bottom + bannerVertGap;
      } else {
        // Above target
        bannerTop = rect.top - bannerVertGap - bannerH;
      }
      bannerTop = bannerTop.clamp(
        mq.padding.top + 8,
        screenH - bannerH - mq.padding.bottom - 8,
      );
    }

    final bannerWidth = (screenW - 24).clamp(0.0, 560.0);
    final bannerLeft = ((screenW - bannerWidth) / 2).clamp(0.0, screenW);

    return Stack(
      children: [
        // Pulsing pointer ring (does NOT block taps).
        if (rect != null)
          Positioned(
            left: rect.left - 8,
            top: rect.top - 8,
            width: rect.width + 16,
            height: rect.height + 16,
            child: const IgnorePointer(child: _PulsingRing()),
          ),

        // Banner (tap-receiving buttons).
        Positioned(
          left: bannerLeft,
          top: bannerTop,
          width: bannerWidth,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: m3.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: m3.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              headline,
                              style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              body,
                              style: TextStyle(
                                fontSize: 13,
                                color: m3.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: widget.onSkip,
                        style: TextButton.styleFrom(
                          foregroundColor: m3.onSurfaceVariant,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          l.tourSkip,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (widget.showContinue) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: widget.onContinue,
                        style: FilledButton.styleFrom(
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          l.tourContinue,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _headlineFor(_BodyKind k, AppLocalizations l) {
    switch (k) {
      case _BodyKind.pointerModel:
        return l.tourModelTitle;
      case _BodyKind.pointerProviderPill:
        return l.tourModelTitle;
      case _BodyKind.pointerMenu:
        return l.tourMenuTitle;
      case _BodyKind.pointerSettings:
        return l.tourSettingsTitle;
      case _BodyKind.settingsPage:
        return l.tourSettingsTitle;
      case _BodyKind.pointerSettingsPricing:
        return l.tourSettingsPricingTitle;
      case _BodyKind.pointerSettingsAiIdentity:
        return l.tourSettingsAiIdentityTitle;
      case _BodyKind.welcome:
        return l.tourWelcomeTitle;
      case _BodyKind.finale:
        return l.tourDoneTitle;
    }
  }

  String _bodyFor(_BodyKind k, AppLocalizations l) {
    switch (k) {
      case _BodyKind.pointerModel:
        return l.tourModelBody;
      case _BodyKind.pointerProviderPill:
        return l.tourProviderPillBody;
      case _BodyKind.pointerMenu:
        return l.tourMenuBody;
      case _BodyKind.pointerSettings:
        return l.tourSettingsTapHere;
      case _BodyKind.settingsPage:
        return l.tourSettingsPageBody;
      case _BodyKind.pointerSettingsPricing:
        return l.tourSettingsPricingBody;
      case _BodyKind.pointerSettingsAiIdentity:
        return l.tourSettingsAiIdentityBody;
      case _BodyKind.welcome:
        return l.tourWelcomeBody;
      case _BodyKind.finale:
        return l.tourDoneBody;
    }
  }
}

/// Animated pulsing ring rendered at the target position. Never receives
/// pointer events (parent wraps in [IgnorePointer]).
class _PulsingRing extends StatefulWidget {
  const _PulsingRing();

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_ctl.value);
        final glow = 0.30 + 0.45 * t;
        final borderW = 2.0 + 2.0 * t;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.primary, width: borderW),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withValues(alpha: glow),
                blurRadius: 16 + 12 * t,
                spreadRadius: 1 + 2 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

