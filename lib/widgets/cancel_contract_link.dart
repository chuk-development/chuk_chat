// lib/widgets/cancel_contract_link.dart
//
// "Cancel contract here" (§ 312k BGB) and "Withdraw from contract" (withdrawal
// function, Art. 11a Directive 2011/83/EU). German law requires clearly
// visible buttons that work without a sign-in. The forms live on the website
// and post to `POST /v1/contract/cancel` on the API server, so the app only
// opens them. Shown in the subscription area and on the sign-in page.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// The cancellation form for [languageCode]. German gets the German page,
/// every other language the English one (the website has only these two).
String cancelContractUrl(String languageCode) => languageCode == 'de'
    ? 'https://chuk.chat/de/kuendigen/'
    : 'https://chuk.chat/en/cancel-contract/';

/// The withdrawal part of the same page.
String withdrawContractUrl(String languageCode) => languageCode == 'de'
    ? 'https://chuk.chat/de/kuendigen/#widerruf'
    : 'https://chuk.chat/en/cancel-contract/#withdraw';

String _languageCode(BuildContext context) =>
    AppLocalizations.of(context)?.locale.languageCode ??
    Localizations.localeOf(context).languageCode;

/// The consent links on the order page: German pages for German, else
/// English ([page] is `cancellation` or `terms`).
String legalPageUrl(String languageCode, String page) =>
    'https://chuk.chat/${languageCode == 'de' ? 'de' : 'en'}/$page/';

/// Opens [url]. When the browser does not open, the user gets the address
/// in a notice, so the legally required form stays reachable.
void _open(BuildContext context, String url) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = AppLocalizations.of(context)?.linkOpenFailed(url) ?? url;
  unawaited(() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && messenger != null && messenger.mounted) {
      AppNotifications.showOn(
        messenger,
        message,
        duration: const Duration(seconds: 8),
        kind: AppNotificationKind.error,
      );
    }
  }());
}

/// Settings rows for the subscription area: cancel, then withdraw.
class CancelContractRows extends StatelessWidget {
  const CancelContractRows({super.key});

  @override
  Widget build(BuildContext context) {
    return const ExpressiveGroup(
      children: [CancelContractRow(), WithdrawContractRow()],
    );
  }
}

/// Settings row "Cancel contract here".
class CancelContractRow extends StatelessWidget {
  const CancelContractRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (l == null) return const SizedBox.shrink();
    return ExpressiveRow(
      icon: Icons.cancel_outlined,
      title: l.cancelContractHere,
      subtitle: l.cancelContractHereSubtitle,
      titleMaxLines: 2,
      trailing: const AppIcon(Icons.open_in_new, size: 18),
      onTap: () => _open(context, cancelContractUrl(_languageCode(context))),
    );
  }
}

/// Settings row "Withdraw from contract".
class WithdrawContractRow extends StatelessWidget {
  const WithdrawContractRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (l == null) return const SizedBox.shrink();
    return ExpressiveRow(
      icon: Icons.arrow_back,
      title: l.withdrawContract,
      subtitle: l.withdrawContractSubtitle,
      titleMaxLines: 2,
      trailing: const AppIcon(Icons.open_in_new, size: 18),
      onTap: () => _open(context, withdrawContractUrl(_languageCode(context))),
    );
  }
}

/// Text buttons for screens without a settings list (the sign-in page).
class CancelContractLink extends StatelessWidget {
  const CancelContractLink({super.key, this.color});

  /// Text and icon colour. Defaults to the theme's primary colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (l == null) return const SizedBox.shrink();
    final style = color == null
        ? null
        : TextButton.styleFrom(foregroundColor: color);
    const label = TextStyle(fontWeight: FontWeight.w600);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          onPressed: () =>
              _open(context, cancelContractUrl(_languageCode(context))),
          style: style,
          icon: const AppIcon(Icons.cancel_outlined, size: 18),
          label: Text(l.cancelContractHere, style: label),
        ),
        TextButton.icon(
          onPressed: () =>
              _open(context, withdrawContractUrl(_languageCode(context))),
          style: style,
          icon: const AppIcon(Icons.arrow_back, size: 18),
          label: Text(l.withdrawContract, style: label),
        ),
      ],
    );
  }
}
