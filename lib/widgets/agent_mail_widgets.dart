/// Small pieces the three agent mail pages share (docs/AGENT_MAIL.md §8):
/// the trust badge, the tag pill, dates, sizes and the error line.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agent_mail_crypto.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// The text a user sees for a failed mail call. Never the raw body.
String agentMailErrorText(AppLocalizations l, Object error) {
  if (error is AgentMailSealException) return l.agentMailErrUnseal;
  if (error is! AgentMailException) return l.agentMailErrNetwork;
  if (error.noSubscription) return l.agentMailErrNoSubscription;
  return switch (error.code) {
    'mailbox_frozen' => l.agentMailErrFrozen,
    'send_suspended' => l.agentMailErrSuspended,
    'too_many_recipients' => l.agentMailErrTooManyRecipients,
    'rate_limited' => l.agentMailErrRateLimited,
    'quota_exhausted' => l.agentMailErrQuota,
    'attachments_too_large' => l.agentMailErrAttachmentsTooLarge,
    'recipient_suppressed' => l.agentMailErrRecipientSuppressed,
    'needs_key' => l.agentMailErrNoKey,
    'invalid_public_key' || 'invalid_private_key' => l.agentMailErrKeyRefused,
    'agent_mail_unavailable' => l.agentMailUnavailable,
    AgentMailException.notSignedIn => l.agentMailErrSignedOut,
    AgentMailException.network => l.agentMailErrNetwork,
    AgentMailException.noKey => l.agentMailErrNoKey,
    AgentMailException.keyLocked => l.agentMailErrKeyLocked,
    AgentMailException.keyUnreadable => l.agentMailErrKeyUnreadable,
    _ => switch (error.statusCode) {
      401 => l.agentMailErrSignedOut,
      404 => l.agentMailErrNotFound,
      _ => l.agentMailErrGeneric(error.code),
    },
  };
}

/// Today: the time. This year: day and month. Older: the short date.
String formatMailDate(BuildContext context, DateTime? when, {DateTime? now}) {
  if (when == null) return '';
  final MaterialLocalizations ml = MaterialLocalizations.of(context);
  final DateTime today = now ?? DateTime.now();
  if (when.year == today.year &&
      when.month == today.month &&
      when.day == today.day) {
    return ml.formatTimeOfDay(
      TimeOfDay.fromDateTime(when),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }
  if (when.year == today.year) return ml.formatShortMonthDay(when);
  return ml.formatShortDate(when);
}

/// The full date and time, for the mail page.
String formatMailDateTime(BuildContext context, DateTime? when) {
  if (when == null) return '';
  final MaterialLocalizations ml = MaterialLocalizations.of(context);
  final String time = ml.formatTimeOfDay(
    TimeOfDay.fromDateTime(when),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return '${ml.formatMediumDate(when)}, $time';
}

/// `1.4 MB`, `820 KB`, `12 B`.
String formatMailBytes(int? bytes) {
  if (bytes == null || bytes < 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Who a row is about: the sender of a received mail, the recipients of a
/// sent one or a draft.
String mailPartyLabel(AppLocalizations l, MailSummary mail) {
  if (mail.outgoing) {
    return l.agentMailTo(
      mail.toAddresses.isEmpty ? '—' : mail.toAddresses.join(', '),
    );
  }
  return mailSenderName(l, mail);
}

/// The sender's name line: "You" for the owner's own mail, else the display
/// name, else the address, else a dash (a summary that did not open).
String mailSenderName(AppLocalizations l, MailSummary mail) {
  if (mail.senderTrust == MailTrust.owner) return l.agentMailTrustOwner;
  final String name = mail.fromName ?? mail.fromAddress;
  return name.isEmpty ? '—' : name;
}

/// The address under the name line, or null when the name line already is
/// the address.
String? mailSenderAddress(AppLocalizations l, MailSummary mail) {
  final String name = mailSenderName(l, mail);
  return name == mail.fromAddress || mail.fromAddress.isEmpty
      ? null
      : mail.fromAddress;
}

String mailSubjectLabel(AppLocalizations l, MailSummary mail) =>
    mail.subject.trim().isEmpty ? l.agentMailNoSubject : mail.subject.trim();

/// A short state word in a small pill: trust, bulk, draft, importance.
class MailTag extends StatelessWidget {
  const MailTag(
    this.label, {
    super.key,
    this.background,
    this.foreground,
    this.icon,
  });

  final String label;
  final Color? background;
  final Color? foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color bg = background ?? theme.m3.surfaceContainerHighest;
    final Color fg = foreground ?? theme.m3.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            AppIcon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The sender's trust (§2) as a tag: you, trusted, or unknown. The agent's
/// own mail ([MailTrust.self]) has no tag.
class MailTrustBadge extends StatelessWidget {
  const MailTrustBadge(this.trust, {super.key});

  final MailTrust trust;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return switch (trust) {
      MailTrust.owner => MailTag(
        l.agentMailTrustOwner,
        background: cs.primaryContainer,
        foreground: cs.onPrimaryContainer,
      ),
      MailTrust.trusted => MailTag(
        l.agentMailTrustTrusted,
        background: cs.secondaryContainer,
        foreground: cs.onSecondaryContainer,
      ),
      MailTrust.unknown => MailTag(
        l.agentMailTrustUnknown,
        background: cs.tertiaryContainer,
        foreground: cs.onTertiaryContainer,
      ),
      // The agent's own mail: the page shows its recipients, not a sender.
      MailTrust.self => const SizedBox.shrink(),
    };
  }
}

/// The importance the restricted run gave a mail.
class MailImportanceTag extends StatelessWidget {
  const MailImportanceTag(this.importance, {super.key});

  final MailImportance importance;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return switch (importance) {
      MailImportance.high => MailTag(
        l.agentMailImportanceHigh,
        background: cs.errorContainer,
        foreground: cs.onErrorContainer,
      ),
      MailImportance.normal => MailTag(l.agentMailImportanceNormal),
      MailImportance.low => MailTag(l.agentMailImportanceLow),
    };
  }
}
