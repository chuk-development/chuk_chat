// lib/widgets/composer/busy_mode_setting.dart
//
// The "While busy: Queue / Steer" setting (deepseek-harness idea 67): what
// Enter does while a reply runs. Ctrl/Cmd+Enter does the other.
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/composer/follow_up_queue.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class ComposerBusyModeSetting extends StatefulWidget {
  const ComposerBusyModeSetting({super.key});

  @override
  State<ComposerBusyModeSetting> createState() =>
      _ComposerBusyModeSettingState();
}

class _ComposerBusyModeSettingState extends State<ComposerBusyModeSetting> {
  @override
  void initState() {
    super.initState();
    unawaited(ComposerBusySetting.load());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    return Column(
      key: const ValueKey<String>('composer-busy-mode-setting'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ExpressiveSectionHeader(l.composerBusyModeTitle),
        ValueListenableBuilder<BusySendMode>(
          valueListenable: ComposerBusySetting.mode,
          builder: (BuildContext context, BusySendMode mode, _) =>
              ConnectedGroup(
                labels: <String>[
                  l.composerBusyModeQueue,
                  l.composerBusyModeSteer,
                ],
                selected: mode == BusySendMode.steer ? 1 : 0,
                margin: EdgeInsets.zero,
                onSelected: (int i) => unawaited(
                  ComposerBusySetting.set(
                    i == 1 ? BusySendMode.steer : BusySendMode.queue,
                  ),
                ),
              ),
        ),
        const SizedBox(height: 8),
        ExpressiveInfoCard(text: l.composerBusyModeHelp),
      ],
    );
  }
}
