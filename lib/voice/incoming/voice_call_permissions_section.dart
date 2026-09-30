// lib/voice/incoming/voice_call_permissions_section.dart
//
// The "Voice calls" section of the settings page: what a call needs from
// Android, whether it is in place, and a tap that asks for it. Built only
// when [voiceIncomingEnabled]; the settings page adds it with one line.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/voice/incoming/voice_call_permissions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

class VoiceCallPermissionsSection extends StatefulWidget {
  const VoiceCallPermissionsSection({super.key, this.load, this.ask});

  /// Test seams: the status source and the request. Default: Android.
  final Future<Map<VoiceCallGrant, bool>> Function()? load;
  final Future<void> Function(VoiceCallGrant grant)? ask;

  @override
  State<VoiceCallPermissionsSection> createState() =>
      _VoiceCallPermissionsSectionState();
}

class _GrantCopy {
  const _GrantCopy(this.icon, this.title, this.buys);

  final IconData icon;
  final String title;

  /// What stops working without it.
  final String buys;
}

const Map<VoiceCallGrant, _GrantCopy> _copy = <VoiceCallGrant, _GrantCopy>{
  VoiceCallGrant.microphone: _GrantCopy(
    Icons.mic_none_rounded,
    'Microphone',
    'Needed before the first call, or the agent cannot hear you once the '
        'app is in the background.',
  ),
  VoiceCallGrant.notifications: _GrantCopy(
    Icons.notifications_active_outlined,
    'Notifications',
    'The ring and the call controls in the notification shade.',
  ),
  VoiceCallGrant.fullScreenIntent: _GrantCopy(
    Icons.phone_in_talk_outlined,
    'Ring over the lock screen',
    'A call from your agent fills the screen, like a phone call.',
  ),
  VoiceCallGrant.background: _GrantCopy(
    Icons.battery_saver_outlined,
    'Run in the background',
    'Keeps the link to your computer open while the phone sleeps, so a '
        'call gets through.',
  ),
};

class _VoiceCallPermissionsSectionState
    extends State<VoiceCallPermissionsSection>
    with WidgetsBindingObserver {
  Map<VoiceCallGrant, bool> _granted = const <VoiceCallGrant, bool>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Two of these are granted on a system page: the app comes back with a
    // new answer.
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    Map<VoiceCallGrant, bool> next;
    try {
      next = await (widget.load ?? VoiceCallPermissions.statuses)();
    } catch (_) {
      next = const <VoiceCallGrant, bool>{};
    }
    if (!mounted) return;
    setState(() => _granted = next);
  }

  Future<void> _ask(VoiceCallGrant grant) async {
    await (widget.ask ?? VoiceCallPermissions.request)(grant);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const ExpressiveSectionHeader('Voice calls'),
        ExpressiveGroup(
          children: <Widget>[
            for (final VoiceCallGrant grant in VoiceCallGrant.values)
              _row(grant, _copy[grant]!, _granted[grant] == true, scheme),
          ],
        ),
      ],
    );
  }

  Widget _row(
    VoiceCallGrant grant,
    _GrantCopy copy,
    bool granted,
    ColorScheme scheme,
  ) {
    return ExpressiveRow(
      key: ValueKey<String>('voice-call-grant-${grant.name}'),
      icon: copy.icon,
      title: copy.title,
      subtitle: granted ? 'Allowed. ${copy.buys}' : copy.buys,
      trailing: granted
          ? AppIcon(Icons.check_circle_rounded, color: scheme.primary)
          : Text(
              'Allow',
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
      onTap: granted ? null : () => unawaited(_ask(grant)),
    );
  }
}
