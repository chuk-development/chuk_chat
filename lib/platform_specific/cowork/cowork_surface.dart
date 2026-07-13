import 'package:flutter/material.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';

/// The CoWork surface — shown when the app is in [AppMode.cowork].
///
/// This is the M0 scaffold. Later milestones replace the placeholder body with
/// the paired-laptop control UI (device picker, task dispatch, live progress
/// stream, approval prompts). See docs/COWORK_BUILD_PLAN.md (MVP M0–M4).
class CoWorkSurface extends StatelessWidget {
  const CoWorkSurface({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.hub_outlined,
                  size: 34,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                l.coworkComingSoon,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l.coworkComingSoonBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
