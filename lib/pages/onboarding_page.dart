// lib/pages/onboarding_page.dart
// First-launch onboarding carousel.

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _page = 0;
  static const int _kPageCount = 5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await AppThemeService.instance.setOnboardingCompleted(true);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  void _next() {
    if (_page >= _kPageCount - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _back() {
    if (_page == 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final bool isLast = _page == _kPageCount - 1;
    final bool isFirst = _page == 0;

    final slides = <_SlideContent>[
      _SlideContent(
        icon: Icons.chat_bubble_outline,
        title: l.onboardingSlide1Title,
        body: l.onboardingSlide1Body,
        highlight: false,
      ),
      _SlideContent(
        icon: Icons.psychology_alt,
        title: l.onboardingSlide2Title,
        body: l.onboardingSlide2Body,
        highlight: _hasNoModelSelected(),
      ),
      _SlideContent(
        icon: Icons.tune,
        title: l.onboardingSlide3Title,
        body: l.onboardingSlide3Body,
        highlight: false,
      ),
      _SlideContent(
        icon: Icons.send,
        title: l.onboardingSlide4Title,
        body: l.onboardingSlide4Body,
        highlight: false,
      ),
      _SlideContent(
        icon: Icons.check_circle_outline,
        title: l.onboardingSlide5Title,
        body: l.onboardingSlide5Body,
        highlight: false,
      ),
    ];

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _finish,
                    style: TextButton.styleFrom(
                      foregroundColor: m3.onSurfaceVariant,
                    ),
                    child: Text(l.onboardingSkip),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _kPageCount,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _SlideView(slide: slides[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
              child: _Dots(count: _kPageCount, active: _page),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: isFirst
                        ? const SizedBox.shrink()
                        : TextButton(
                            onPressed: _back,
                            style: TextButton.styleFrom(
                              foregroundColor: m3.onSurfaceVariant,
                            ),
                            child: Text(l.onboardingBack),
                          ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: Text(
                      isLast ? l.onboardingDone : l.onboardingNext,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _hasNoModelSelected() =>
      ModelSelectionDropdown.selectedModelNotifier.value.trim().isEmpty;
}

class _SlideContent {
  final IconData icon;
  final String title;
  final String body;
  final bool highlight;

  const _SlideContent({
    required this.icon,
    required this.title,
    required this.body,
    required this.highlight,
  });
}

class _SlideView extends StatelessWidget {
  final _SlideContent slide;

  const _SlideView({required this.slide});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final Color iconBg = slide.highlight
        ? cs.primaryContainer
        : m3.surfaceContainerHigh;
    final Color iconFg = slide.highlight ? cs.onPrimaryContainer : cs.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              color: iconBg,
              shape: BoxShape.circle,
            ),
            child: Icon(slide.icon, size: 64, color: iconFg),
          ),
          const SizedBox(height: 36),
          Text(
            slide.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(
              slide.body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: m3.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          if (slide.highlight) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 14, color: cs.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    AppLocalizations.of(context)!.onboardingNoModelHint,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int active;

  const _Dots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final bool isActive = i == active;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: isActive ? cs.primary : m3.outlineVariant,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}
