/// The "Cloud computer" section of the Agents settings (CHAT-164): one row
/// with the state of the user's cloud computer and its last backup.
///
/// It reads the state once when it is built. With no cloud computer (state
/// `none`), with the feature off on the server (404) or on any error it draws
/// nothing at all, header included, so a self-hosting user sees no change.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class AgentsCloudBoxSettingsSection extends StatefulWidget {
  const AgentsCloudBoxSettingsSection({
    super.key,
    this.api,
    this.onOpenBilling,
  });

  /// Null = [HttpAgentsCloudBoxApi.instance].
  final AgentsCloudBoxApi? api;

  /// Opens the billing portal. The row takes a tap only while the computer
  /// is paused for a payment problem.
  final VoidCallback? onOpenBilling;

  static const ValueKey<String> rowKey = ValueKey<String>('settings_cloud_box');

  /// The row's subtitle: the state, and the last backup when there is one.
  static String subtitleFor(
    AppLocalizations l,
    AgentsCloudBoxStatus status,
    MaterialLocalizations material,
  ) {
    final String state = switch (status.state) {
      AgentsCloudBoxState.none => l.cloudBoxStateNone,
      AgentsCloudBoxState.settingUp => l.cloudBoxStateSettingUp,
      AgentsCloudBoxState.running => l.cloudBoxStateRunning,
      AgentsCloudBoxState.suspended => l.cloudBoxStateSuspended,
    };
    final DateTime? backup = status.lastBackupAt?.toLocal();
    final String backupText = backup == null
        ? l.cloudBoxNoBackup
        : l.cloudBoxLastBackup(
            '${material.formatShortDate(backup)} '
            '${material.formatTimeOfDay(TimeOfDay.fromDateTime(backup))}',
          );
    return '$state · $backupText';
  }

  @override
  State<AgentsCloudBoxSettingsSection> createState() =>
      _AgentsCloudBoxSettingsSectionState();
}

class _AgentsCloudBoxSettingsSectionState
    extends State<AgentsCloudBoxSettingsSection> {
  late final Future<AgentsCloudBoxStatus?> _status = _load();

  Future<AgentsCloudBoxStatus?> _load() async {
    try {
      return await (widget.api ?? HttpAgentsCloudBoxApi.instance).fetch();
    } catch (_) {
      // 404 (feature off), signed out or offline: the section stays away.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AgentsCloudBoxStatus?>(
      future: _status,
      builder: (BuildContext context, AsyncSnapshot<AgentsCloudBoxStatus?> s) {
        final AgentsCloudBoxStatus? status = s.data;
        if (status == null || status.state == AgentsCloudBoxState.none) {
          return const SizedBox.shrink();
        }
        final AppLocalizations l =
            AppLocalizations.of(context) ??
            AppLocalizations(const Locale('en'));
        final bool suspended = status.state == AgentsCloudBoxState.suspended;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExpressiveSectionHeader(l.cloudBoxTitle),
            ExpressiveGroup(
              children: <Widget>[
                ExpressiveRow(
                  key: AgentsCloudBoxSettingsSection.rowKey,
                  icon: suspended
                      ? Icons.cloud_off_outlined
                      : Icons.cloud_outlined,
                  title: l.cloudBoxTitle,
                  subtitle: AgentsCloudBoxSettingsSection.subtitleFor(
                    l,
                    status,
                    MaterialLocalizations.of(context),
                  ),
                  onTap: suspended ? widget.onOpenBilling : null,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
