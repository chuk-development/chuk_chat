/// The "Cloud computer" section of the Agents settings (CHAT-164).
///
/// The cloud computer is an optional add-on. Without it the section offers
/// one row, "Book a cloud computer" (only where the build may take payments).
/// With it: the state and last backup, the size with "Change size" (and a
/// change waiting for the period end), and "Cancel cloud computer".
///
/// It reads the state when it is built and again after each change. With the
/// feature off on the server (404) or on any error it draws nothing at all,
/// header included, so a self-hosting user sees no change.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_config.dart' show kFeaturePaymentsDirect;
import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/services/agents_plans.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_addon.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_billing_sheets.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class AgentsCloudBoxSettingsSection extends StatefulWidget {
  const AgentsCloudBoxSettingsSection({
    super.key,
    this.api,
    this.onOpenBilling,
    this.openCheckout,
    this.onChanged,
    this.paymentsEnabled = kFeaturePaymentsDirect,
  });

  /// Null = [HttpAgentsCloudBoxApi.instance].
  final AgentsCloudBoxBillingApi? api;

  /// The 402 path of a booking. Null = the pricing page, add-on pre-selected.
  final CloudBoxCheckoutOpener? openCheckout;

  /// After a booking, size change or cancellation. Null = read the user
  /// status again, so the zero-click setup starts.
  final CloudBoxChanged? onChanged;

  /// Booking and upgrades charge money; a build without direct payments
  /// (`FEATURE_PAYMENTS_DIRECT=false`) offers neither. Cancel always stays.
  final bool paymentsEnabled;

  /// Opens the billing portal. The row takes a tap only while the computer
  /// is paused for a payment problem.
  final VoidCallback? onOpenBilling;

  static const ValueKey<String> rowKey = ValueKey<String>('settings_cloud_box');
  static const ValueKey<String> bookKey = ValueKey<String>(
    'settings_cloud_box_book',
  );
  static const ValueKey<String> sizeKey = ValueKey<String>(
    'settings_cloud_box_size',
  );
  static const ValueKey<String> cancelKey = ValueKey<String>(
    'settings_cloud_box_cancel',
  );

  /// The size row's subtitle: the booked size with its specs, and a change
  /// that waits for the period end.
  static String sizeSubtitleFor(
    AppLocalizations l,
    AgentsCloudBoxStatus status,
    MaterialLocalizations material,
  ) {
    final List<AgentsCloudBoxSize> known = status.sizesAvailable.isNotEmpty
        ? status.sizesAvailable
        : kAgentsCloudBoxSizeDefaults;
    final AgentsCloudBoxSize? size =
        cloudBoxSizeById(known, status.size) ??
        cloudBoxSizeById(kAgentsCloudBoxSizeDefaults, status.size);
    final String now = size == null
        ? l.cloudBoxSizeLabel(status.size ?? '?')
        : '${l.cloudBoxSizeLabel(size.label)} · ${cloudBoxSpecsText(l, size)}';
    final String? pendingId = status.pendingSize;
    if (pendingId == null) return now;
    final String pendingLabel =
        (cloudBoxSizeById(known, pendingId) ??
                cloudBoxSizeById(kAgentsCloudBoxSizeDefaults, pendingId))
            ?.label ??
        pendingId.toUpperCase();
    final DateTime? at = status.pendingEffectiveAt?.toLocal();
    final String pending = at == null
        ? l.cloudBoxPendingChangeSoon(pendingLabel)
        : l.cloudBoxPendingChange(pendingLabel, material.formatShortDate(at));
    // Two lines at most: the size alone, then the waiting change.
    final String label = l.cloudBoxSizeLabel(size?.label ?? status.size ?? '?');
    return '$label\n$pending';
  }

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
  late Future<AgentsCloudBoxStatus?> _status = _load();

  AgentsCloudBoxBillingApi get _api =>
      widget.api ?? HttpAgentsCloudBoxApi.instance;

  Future<AgentsCloudBoxStatus?> _load() async {
    try {
      return await _api.fetch();
    } catch (_) {
      // 404 (feature off), signed out or offline: the section stays away.
      return null;
    }
  }

  /// After a change: tell the app, then read the state again.
  Future<void> _changed() async {
    await (widget.onChanged ?? refreshStatusAfterCloudBoxChange)();
    if (!mounted) return;
    setState(() => _status = _load());
  }

  Future<void> _book() => showCloudBoxBookSheet(
    context,
    api: _api,
    openCheckout: widget.openCheckout,
    onBooked: _changed,
  );

  Future<void> _resize(AgentsCloudBoxStatus status) => showCloudBoxResizeSheet(
    context,
    status: status,
    api: _api,
    onChanged: _changed,
  );

  Future<void> _cancel() =>
      confirmCloudBoxCancel(context, api: _api, onChanged: _changed);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AgentsCloudBoxStatus?>(
      future: _status,
      builder: (BuildContext context, AsyncSnapshot<AgentsCloudBoxStatus?> s) {
        final AgentsCloudBoxStatus? status = s.data;
        if (status == null) return const SizedBox.shrink();
        final bool booked = status.booked;
        if (!booked && !widget.paymentsEnabled) {
          return const SizedBox.shrink();
        }
        final AppLocalizations l =
            AppLocalizations.of(context) ??
            AppLocalizations(const Locale('en'));
        final MaterialLocalizations material = MaterialLocalizations.of(
          context,
        );
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final bool suspended = status.state == AgentsCloudBoxState.suspended;
        final List<Widget> rows = booked
            ? <Widget>[
                if (status.state != AgentsCloudBoxState.none)
                  ExpressiveRow(
                    key: AgentsCloudBoxSettingsSection.rowKey,
                    icon: suspended
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_outlined,
                    title: l.cloudBoxTitle,
                    subtitle: AgentsCloudBoxSettingsSection.subtitleFor(
                      l,
                      status,
                      material,
                    ),
                    onTap: suspended ? widget.onOpenBilling : null,
                  ),
                if (status.size != null)
                  ExpressiveRow(
                    key: AgentsCloudBoxSettingsSection.sizeKey,
                    icon: Icons.tune,
                    title: l.cloudBoxChangeSize,
                    subtitle: AgentsCloudBoxSettingsSection.sizeSubtitleFor(
                      l,
                      status,
                      material,
                    ),
                    // A downgrade costs nothing, but the sheet offers both
                    // ways; without direct payments it stays read-only.
                    onTap: widget.paymentsEnabled
                        ? () => unawaited(_resize(status))
                        : null,
                  ),
                if (status.size != null)
                  ExpressiveRow(
                    key: AgentsCloudBoxSettingsSection.cancelKey,
                    icon: Icons.cancel_outlined,
                    tone: scheme.errorContainer,
                    title: l.cloudBoxCancel,
                    subtitle: l.cloudBoxCancelSubtitle,
                    onTap: () => unawaited(_cancel()),
                  ),
              ]
            : <Widget>[
                ExpressiveRow(
                  key: AgentsCloudBoxSettingsSection.bookKey,
                  icon: Icons.cloud_outlined,
                  title: l.cloudBoxBook,
                  subtitle: l.cloudBoxBookSubtitle(
                    formatEuroAmount(
                      kAgentsCloudBoxSizeDefaults.first.priceEur,
                      l.locale.languageCode,
                    ),
                  ),
                  onTap: () => unawaited(_book()),
                ),
              ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExpressiveSectionHeader(l.cloudBoxTitle),
            ExpressiveGroup(children: rows),
          ],
        );
      },
    );
  }
}
