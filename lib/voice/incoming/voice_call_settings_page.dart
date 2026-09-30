// lib/voice/incoming/voice_call_settings_page.dart
//
// Settings → Voice calls (FEATURE_VOICE_CALL): what a call with the agent
// needs from Android, each with a tap that asks for it. The settings page
// shows one row that opens this page, and only when [voiceIncomingEnabled].

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/voice/incoming/voice_call_permissions.dart';
import 'package:chuk_chat/voice/incoming/voice_call_permissions_section.dart';

class VoiceCallSettingsPage extends StatelessWidget {
  const VoiceCallSettingsPage({super.key, this.load, this.ask});

  /// Test seams, handed to [VoiceCallPermissionsSection].
  final Future<Map<VoiceCallGrant, bool>> Function()? load;
  final Future<void> Function(VoiceCallGrant grant)? ask;

  @override
  Widget build(BuildContext context) {
    return ExpressiveScreen(
      title: 'Voice calls',
      builder: (BuildContext context) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + 8,
                16,
                MediaQuery.paddingOf(context).bottom + 24,
              ),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Text(
                    'Your agent can call you, and you can call it from a '
                    'chat. For that, Android must allow these.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
                VoiceCallPermissionsSection(load: load, ask: ask),
              ],
            ),
          ),
        );
      },
    );
  }
}
