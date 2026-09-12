import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/app_notification.dart';

import 'package:chuk_chat/assistant/assistant_bridge.dart';
import 'package:chuk_chat/assistant/assistant_config.dart';
import 'package:chuk_chat/assistant/assistant_overlay.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// One job: make Chuk Chat the assistant of this phone.
///
/// A short how-to, the one button that claims the role, and the freedoms that
/// are still missing. Nothing else — every switch that is not needed to get
/// the assistant working belongs somewhere else.
///
/// Android only. The native side (`dev.chuk.chat.assist`) is the only thing
/// that can claim the assistant role, read the visible screen, or act on it.
class AssistantSettingsPage extends StatefulWidget {
  const AssistantSettingsPage({super.key});

  @override
  State<AssistantSettingsPage> createState() => _AssistantSettingsPageState();
}

/// One freedom the assistant needs, and what it buys.
class _Grant {
  const _Grant({
    required this.key,
    required this.icon,
    required this.title,
    required this.buys,
    required this.open,
    this.required = false,
  });

  final String key;
  final IconData icon;
  final String title;

  /// What stops working without it. Shown instead of a description of the
  /// permission itself — the user decides on the feature, not on the flag.
  final String buys;
  final Future<void> Function() open;

  /// Without this one there is no assistant at all.
  final bool required;
}

class _AssistantSettingsPageState extends State<AssistantSettingsPage>
    with WidgetsBindingObserver {
  Map<String, bool> _statuses = const <String, bool>{};
  bool _loading = true;

  late final List<_Grant> _grants = <_Grant>[
    _Grant(
      key: 'assistant',
      icon: Icons.assistant_outlined,
      title: 'Assistenten-Rolle',
      buys: 'Die Geste öffnet Chuk Chat statt einer anderen App.',
      required: true,
      open: _claimAssistantRole,
    ),
    _Grant(
      key: 'accessibility',
      icon: Icons.accessibility_new_outlined,
      title: 'Bildschirm lesen',
      buys: '„Was steht hier", Bildschirmfotos, Tippen in anderen Apps.',
      open: AssistantBridge.openAccessibilitySettings,
    ),
    _Grant(
      key: 'notificationAccess',
      icon: Icons.notifications_active_outlined,
      title: 'Benachrichtigungen',
      buys: '„Was habe ich verpasst" und Steuerung der Wiedergabe.',
      open: AssistantBridge.openNotificationAccessSettings,
    ),
    _Grant(
      key: 'contacts',
      icon: Icons.contacts_outlined,
      title: 'Kontakte',
      buys: '„Ruf X an" und SMS-Entwürfe.',
      open: () async {
        await AssistantBridge.requestContactsPermission();
      },
    ),
    _Grant(
      key: 'location',
      icon: Icons.location_on_outlined,
      title: 'Standort',
      buys: 'Orte in der Nähe und Navigation.',
      open: () async {
        await AssistantBridge.requestLocationPermission();
      },
    ),
  ];

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
    // Every one of these is granted in a system screen, so the app comes back
    // from the background with a new answer.
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    var statuses = const <String, bool>{};
    if (AssistantPlatform.isSupported) {
      try {
        statuses = await AssistantBridge.getPermissionStatuses();
      } catch (_) {
        // Native side missing — leave every row as "not granted".
      }
    }
    if (!mounted) return;
    setState(() {
      _statuses = statuses;
      _loading = false;
    });
  }

  Future<void> _claimAssistantRole() async {
    var claimed = false;
    try {
      claimed = await AssistantBridge.requestAssistantRole();
      if (!claimed) await AssistantBridge.openAssistantSettings();
    } catch (_) {
      claimed = false;
    }
    if (!mounted) return;
    if (!claimed) {AppNotifications.show(context, 'Wähle in der geöffneten Liste Chuk Chat aus.');
    }
  }

  Future<void> _open(_Grant grant) async {
    try {
      await grant.open();
    } catch (_) {
      // Nothing to open without the native side.
    }
    await _refresh();
  }

  bool _granted(_Grant grant) => _statuses[grant.key] == true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (!AssistantPlatform.isSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Assistent setzen')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Der Assistent läuft nur auf Android. Dort ersetzt Chuk Chat '
              'den Sprachassistenten des Geräts.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ),
        ),
      );
    }

    final isDefault = _granted(_grants.first);
    final missing = _grants.where((grant) => !_granted(grant)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assistent setzen'),
        actions: [
          IconButton(
            tooltip: 'Status aktualisieren',
            onPressed: _loading ? null : () => unawaited(_refresh()),
            icon: const AppIcon(Icons.refresh),
          ),
        ],
      ),
      body: SettingsListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _HowTo(isDefault: isDefault),
          if (missing.isEmpty)
            const _AllSet()
          else ...[
            ExpressiveSectionHeader(
              missing.length == 1 ? 'Fehlt noch' : 'Fehlen noch',
            ),
            ExpressiveGroup(
              children: [
                for (final grant in missing)
                  ExpressiveRow(
                    icon: grant.icon,
                    title: grant.title,
                    subtitle: grant.required
                        ? '${grant.buys} Ohne das läuft nichts.'
                        : grant.buys,
                    trailing: AppIcon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
                    onTap: () => unawaited(_open(grant)),
                  ),
              ],
            ),
          ],
          if (isDefault) ...[
            const ExpressiveSectionHeader('Ausprobieren'),
            ExpressiveGroup(
              children: [
                ExpressiveRow(
                  icon: Icons.mic_none_rounded,
                  title: 'Assistent jetzt öffnen',
                  subtitle: 'Dieselbe Fläche, die die Geste öffnet.',
                  onTap: () =>
                      Navigator.of(context).push(buildAssistantOverlayRoute()),
                ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Text(
              'Bedienungshilfen und Benachrichtigungszugriff sperrt Android '
              'für Apps, die nicht aus einem Store kommen. Wenn dort '
              '„Eingeschränkte Einstellung" steht: Einstellungen → Apps → '
              'Chuk Chat → ⋮ → Eingeschränkte Einstellungen zulassen.',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HowTo extends StatelessWidget {
  const _HowTo({required this.isDefault});

  final bool isDefault;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: isDefault ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.primary.withValues(alpha: isDefault ? 0.45 : 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                isDefault
                    ? Icons.check_circle_rounded
                    : Icons.graphic_eq_rounded,
                color: scheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isDefault ? 'Chuk Chat ist der Assistent' : 'So geht es',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (isDefault)
            Text(
              'Halte die Geste unten am Bildschirmrand gedrückt und sprich '
              'los. Die Fläche legt sich über die App, die gerade offen ist.',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            )
          else ...[
            const _Step(
              number: 1,
              text: 'Unten auf „Assistenten-Rolle" tippen.',
            ),
            const _Step(
              number: 2,
              text: 'In der Liste, die Android öffnet, Chuk Chat wählen.',
            ),
            const _Step(
              number: 3,
              text: 'Zurück hierher — der Status aktualisiert sich selbst.',
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.22),
            ),
            child: Text(
              '$number',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AllSet extends StatelessWidget {
  const _AllSet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        children: [
          AppIcon(Icons.done_all_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Alle Freigaben sind erteilt.',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
