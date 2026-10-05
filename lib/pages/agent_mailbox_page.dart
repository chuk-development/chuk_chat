// lib/pages/agent_mailbox_page.dart
//
// Settings > Agents > Mailbox (docs/AGENT_MAIL.md §8): the agent's own
// address with a copy action, the privacy note, the folder switch and the
// mail list. The server is the source of truth for the subscription: a 402
// from the mailbox call shows an info card and no list. Opening the page
// also readies the mail key: a mailbox that `needs_key` gets one here.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/agent_mail_contacts_page.dart';
import 'package:chuk_chat/pages/agent_mail_detail_page.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/pill_geometry.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agent_mail_widgets.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// One segment of the folder switch and the list query behind it.
@immutable
class AgentMailFilter {
  const AgentMailFilter(this.folder, [this.trust]);

  final MailFolder folder;
  final MailTrustFilter? trust;
}

/// Inbox | Unknown | Drafts | Sent. The inbox holds only mail from known
/// senders; unknown senders get their own segment, so what the agent could
/// not read in a normal run never mixes with what it could. Four segments
/// fit a phone; the archive is a row of its own that opens [kAgentMailArchive].
const List<AgentMailFilter> kAgentMailFilters = <AgentMailFilter>[
  AgentMailFilter(MailFolder.inbox, MailTrustFilter.known),
  AgentMailFilter(MailFolder.inbox, MailTrustFilter.unknown),
  AgentMailFilter(MailFolder.drafts),
  AgentMailFilter(MailFolder.sent),
];

/// The archive, opened from its row under the address.
const AgentMailFilter kAgentMailArchive = AgentMailFilter(MailFolder.archive);

/// Rows fetched per page.
const int kAgentMailPageSize = 50;

class AgentMailboxPage extends StatefulWidget {
  const AgentMailboxPage({
    super.key,
    this.service,
    this.fileSaver = const DownloadsAgentFileSaver(),
    this.now,
    this.only,
  });

  /// Null uses [AgentMailService.instance].
  final AgentMailService? service;

  /// Set: the page is one folder's list and nothing else (the archive). No
  /// address, no switch.
  final AgentMailFilter? only;

  /// Where an attachment lands when the user saves it (the mail page).
  final AgentFileSaver fileSaver;

  /// The clock for the dates in the list. Tests pin it.
  final DateTime Function()? now;

  @override
  State<AgentMailboxPage> createState() => _AgentMailboxPageState();
}

class _AgentMailboxPageState extends State<AgentMailboxPage> {
  AgentMailService get _service => widget.service ?? AgentMailService.instance;

  bool _loadingMailbox = true;
  Mailbox? _mailbox;
  Object? _mailboxError;

  int _filter = 0;
  bool _loadingList = false;
  List<MailSummary> _messages = const <MailSummary>[];
  String? _nextBefore;
  Object? _listError;

  /// Bumped on every list load, so a slow answer for a segment the user has
  /// already left cannot overwrite the one on screen.
  int _listGeneration = 0;

  /// The list generation whose "Load older mail" is on its way. A load of a
  /// generation the user has left does not count, so leaving a segment in
  /// the middle of paging can never block paging in the next one.
  int? _moreGeneration;
  bool get _loadingMore => _moreGeneration == _listGeneration;

  bool get _single => widget.only != null;
  AgentMailFilter get _current => widget.only ?? kAgentMailFilters[_filter];

  @override
  void initState() {
    super.initState();
    if (_single) {
      _loadingMailbox = false;
      unawaited(_loadList());
    } else {
      unawaited(_loadAll());
    }
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() {
      _loadingMailbox = true;
      _mailboxError = null;
    });
    try {
      final Mailbox mailbox = await _service.openMailbox();
      if (mailbox.needsKey) {
        // The key went up, yet the server still has none: nothing to read.
        throw const AgentMailException(0, AgentMailException.noKey);
      }
      if (!mounted) return;
      setState(() {
        _mailbox = mailbox;
        _loadingMailbox = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _mailbox = null;
        _mailboxError = error;
        _loadingMailbox = false;
      });
      return;
    }
    await _loadList();
  }

  Future<void> _loadList() async {
    if (!mounted) return;
    final int generation = ++_listGeneration;
    final AgentMailFilter filter = _current;
    setState(() {
      _loadingList = true;
      _listError = null;
    });
    try {
      final MailPage page = await _service.messages(
        folder: filter.folder,
        trust: filter.trust,
        limit: kAgentMailPageSize,
      );
      if (!mounted || generation != _listGeneration) return;
      setState(() {
        _messages = page.messages;
        _nextBefore = page.nextBefore;
        _loadingList = false;
      });
    } catch (error) {
      if (!mounted || generation != _listGeneration) return;
      setState(() {
        _messages = const <MailSummary>[];
        _nextBefore = null;
        _listError = error;
        _loadingList = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final String? before = _nextBefore;
    if (before == null || _loadingMore) return;
    final int generation = _listGeneration;
    final AgentMailFilter filter = _current;
    setState(() => _moreGeneration = generation);
    try {
      final MailPage page = await _service.messages(
        folder: filter.folder,
        trust: filter.trust,
        limit: kAgentMailPageSize,
        before: before,
      );
      if (!mounted) return;
      setState(() {
        _endMore(generation);
        // A page for a segment the user has left is dropped.
        if (generation != _listGeneration) return;
        _messages = <MailSummary>[..._messages, ...page.messages];
        _nextBefore = page.nextBefore;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _endMore(generation));
      if (generation != _listGeneration) return;
      AppNotifications.error(
        context,
        agentMailErrorText(AppLocalizations.of(context)!, error),
      );
    }
  }

  /// Clears the paging mark, but only its own: a newer segment's load stays.
  void _endMore(int generation) {
    if (_moreGeneration == generation) _moreGeneration = null;
  }

  void _select(int index) {
    if (index == _filter) return;
    setState(() {
      _filter = index;
      _messages = const <MailSummary>[];
      _nextBefore = null;
    });
    unawaited(_loadList());
  }

  Future<void> _refresh() async {
    if (_single) {
      await _loadList();
    } else if (_mailbox == null) {
      await _loadAll();
    } else {
      await Future.wait(<Future<void>>[_refreshMailbox(), _loadList()]);
    }
  }

  /// The mailbox row again (frozen, suspended), without dropping the list.
  Future<void> _refreshMailbox() async {
    try {
      final Mailbox mailbox = await _service.mailbox();
      if (mounted) setState(() => _mailbox = mailbox);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('agent mail: mailbox refresh failed (${error.runtimeType})');
      }
      if (!mounted) return;
      AppNotifications.error(
        context,
        agentMailErrorText(AppLocalizations.of(context)!, error),
      );
    }
  }

  Future<void> _copyAddress(String address) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String copied = AppLocalizations.of(context)!.agentMailAddressCopied;
    await Clipboard.setData(ClipboardData(text: address));
    AppNotifications.showOn(messenger, copied);
  }

  Future<void> _open(MailSummary mail) async {
    // The mail page marks it read; the row follows at once.
    if (!mail.read) {
      setState(() {
        _messages = <MailSummary>[
          for (final MailSummary m in _messages)
            m.id == mail.id ? m.copyWith(read: true) : m,
        ];
      });
    }
    final AgentMailOutcome? outcome = await Navigator.of(context).push(
      MaterialPageRoute<AgentMailOutcome>(
        builder: (_) => AgentMailDetailPage(
          summary: mail,
          service: _service,
          fileSaver: widget.fileSaver,
        ),
      ),
    );
    if (!mounted || outcome == null) return;
    if (outcome == AgentMailOutcome.removed) {
      setState(() {
        _messages = <MailSummary>[
          for (final MailSummary m in _messages)
            if (m.id != mail.id) m,
        ];
      });
    }
    // Trusting a sender moves its mail from Unknown to Inbox, so the list
    // is asked again for every change.
    unawaited(_loadList());
  }

  void _openContacts() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentMailContactsPage(service: _service),
      ),
    );
  }

  Future<void> _openArchive() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentMailboxPage(
          service: _service,
          fileSaver: widget.fileSaver,
          now: widget.now,
          only: kAgentMailArchive,
        ),
      ),
    );
    // A mail moved back to the inbox from there shows up here.
    if (!mounted) return;
    unawaited(_loadList());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    return Scaffold(
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        title: Text(_single ? l.agentMailFolderArchive : l.agentMail),
      ),
      body: Builder(
        builder: (BuildContext context) {
          final double top = floatingHeaderInset(context).top;
          return RefreshIndicator(
            edgeOffset: top,
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                16,
                top + 8,
                16,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              children: _body(context, l),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l) {
    if (_single) return _list(context, l);
    if (_loadingMailbox) {
      return const <Widget>[
        SizedBox(height: 48),
        Center(child: ExpressiveLoader(size: 44)),
      ];
    }
    final Object? error = _mailboxError;
    if (error != null) return _mailboxProblem(l, error);
    final Mailbox mailbox = _mailbox!;
    return <Widget>[
      _AddressTile(
        address: mailbox.address,
        onCopy: () => _copyAddress(mailbox.address),
      ),
      // §1: what the storage does and does not protect.
      const SizedBox(height: 12),
      ExpressiveInfoCard(
        key: const ValueKey<String>('agent-mail-privacy'),
        text: l.agentMailPrivacy,
      ),
      if (mailbox.frozen) ...<Widget>[
        const SizedBox(height: 12),
        ExpressiveInfoCard(
          icon: Icons.warning_amber_rounded,
          text: l.agentMailFrozen,
        ),
      ],
      if (mailbox.sendSuspended) ...<Widget>[
        const SizedBox(height: 12),
        ExpressiveInfoCard(
          icon: Icons.warning_amber_rounded,
          text: l.agentMailSendSuspended,
        ),
      ],
      const SizedBox(height: 12),
      ExpressiveGroup(
        children: <Widget>[
          ExpressiveRow(
            icon: Icons.people_outline,
            title: l.agentMailContacts,
            subtitle: l.agentMailContactsSubtitle,
            trailing: const AppIcon(Icons.chevron_right),
            onTap: _openContacts,
          ),
          ExpressiveRow(
            icon: Icons.archive_outlined,
            title: l.agentMailFolderArchive,
            subtitle: l.agentMailArchiveSubtitle,
            trailing: const AppIcon(Icons.chevron_right),
            onTap: () => unawaited(_openArchive()),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _FolderSwitch(
        labels: <String>[
          l.agentMailFolderInbox,
          l.agentMailFolderUnknown,
          l.agentMailFolderDrafts,
          l.agentMailFolderSent,
        ],
        selected: _filter,
        onSelected: _select,
      ),
      const SizedBox(height: 12),
      ..._list(context, l),
    ];
  }

  List<Widget> _mailboxProblem(AppLocalizations l, Object error) {
    if (error is AgentMailException && error.noSubscription) {
      return <Widget>[
        ExpressiveInfoCard(
          icon: Icons.mail_outline,
          text: l.agentMailNoSubscription,
        ),
        const SizedBox(height: 12),
        ExpressiveGroup(
          children: <Widget>[
            ExpressiveRow(
              icon: Icons.attach_money,
              title: l.agentMailSeePlans,
              trailing: const AppIcon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PricingPage()),
              ),
            ),
          ],
        ),
      ];
    }
    if (error is AgentMailException && error.unavailable) {
      return <Widget>[
        ExpressiveInfoCard(
          icon: Icons.info_outline,
          text: l.agentMailUnavailable,
        ),
        const SizedBox(height: 12),
        _retryGroup(l, _loadAll),
      ];
    }
    return <Widget>[
      ExpressiveInfoCard(
        icon: Icons.error_outline,
        text: '${l.agentMailLoadFailed}. ${agentMailErrorText(l, error)}',
      ),
      const SizedBox(height: 12),
      _retryGroup(l, _loadAll),
    ];
  }

  Widget _retryGroup(AppLocalizations l, Future<void> Function() retry) =>
      ExpressiveGroup(
        children: <Widget>[
          ExpressiveRow(
            icon: Icons.refresh,
            title: l.retry,
            onTap: () => unawaited(retry()),
          ),
        ],
      );

  List<Widget> _list(BuildContext context, AppLocalizations l) {
    final AgentMailFilter filter = _current;
    final List<Widget> out = <Widget>[
      if (filter.trust == MailTrustFilter.unknown) ...<Widget>[
        ExpressiveInfoCard(text: l.agentMailUnknownInfo),
        const SizedBox(height: 12),
      ],
      if (filter.folder == MailFolder.drafts) ...<Widget>[
        ExpressiveInfoCard(text: l.agentMailDraftsInfo),
        const SizedBox(height: 12),
      ],
    ];
    if (_loadingList && _messages.isEmpty) {
      return <Widget>[
        ...out,
        const SizedBox(height: 24),
        const Center(child: ExpressiveLoader(size: 40)),
      ];
    }
    final Object? error = _listError;
    if (error != null) {
      return <Widget>[
        ...out,
        ExpressiveInfoCard(
          icon: Icons.error_outline,
          text: agentMailErrorText(l, error),
        ),
        const SizedBox(height: 12),
        _retryGroup(l, _loadList),
      ];
    }
    if (_messages.isEmpty) {
      return <Widget>[
        ...out,
        ExpressiveGroup(
          children: <Widget>[
            ExpressiveRow(
              icon: _emptyIcon(filter),
              title: _emptyTitle(l, filter),
              subtitle: l.agentMailEmptyHint,
            ),
          ],
        ),
      ];
    }
    final DateTime now = widget.now?.call() ?? DateTime.now();
    return <Widget>[
      ...out,
      ExpressiveGroup(
        children: <Widget>[
          for (final MailSummary mail in _messages)
            AgentMailRow(
              key: ValueKey<String>('agent-mail-row-${mail.id}'),
              mail: mail,
              now: now,
              onTap: () => _open(mail),
            ),
          if (_nextBefore != null)
            ExpressiveRow(
              icon: Icons.expand_more,
              title: l.agentMailLoadMore,
              trailing: _loadingMore
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : null,
              onTap: _loadingMore ? null : () => unawaited(_loadMore()),
            ),
        ],
      ),
    ];
  }

  static IconData _emptyIcon(AgentMailFilter filter) => switch (filter.folder) {
    MailFolder.drafts => Icons.edit_outlined,
    MailFolder.sent => Icons.send,
    MailFolder.archive => Icons.archive_outlined,
    _ => Icons.inbox_outlined,
  };

  static String _emptyTitle(AppLocalizations l, AgentMailFilter filter) =>
      switch (filter.folder) {
        MailFolder.drafts => l.agentMailEmptyDrafts,
        MailFolder.sent => l.agentMailEmptySent,
        MailFolder.archive => l.agentMailEmptyArchive,
        _ =>
          filter.trust == MailTrustFilter.unknown
              ? l.agentMailEmptyUnknown
              : l.agentMailEmptyInbox,
      };
}

/// The agent's address on a line of its own, so it is never cut: at a narrow
/// width and a large text size it scales down instead.
class _AddressTile extends StatelessWidget {
  const _AddressTile({required this.address, required this.onCopy});

  final String address;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = AppLocalizations.of(context)!;
    return ExpressiveGroup(
      children: <Widget>[
        ExpressiveTile(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const ExpressiveIconTile(icon: Icons.mail_outline),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      l.agentMailAddressHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.m3.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExpressiveIconButton(
                    hugeIcon: HugeIcons.copy01,
                    tooltip: l.agentMailCopyAddress,
                    onTap: onCopy,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  address,
                  key: const ValueKey<String>('agent-mail-address'),
                  maxLines: 1,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The folder switch. It never scrolls and never clips: when the labels do
/// not fit their segments at the reader's text size, the labels alone are
/// set smaller, down to [_kMinLabelScale], and only past that are they cut.
class _FolderSwitch extends StatelessWidget {
  const _FolderSwitch({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  /// The smallest the labels are set: 14 px x 0.75, still over 10 px.
  static const double _kMinLabelScale = 0.75;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    // The factor the reader's scaler gives the segment's 14 px label.
    final double reader = media.textScaler.scale(14) / 14;
    final TextStyle style = DefaultTextStyle.of(context).style
        .merge(const TextStyle(fontSize: 14, fontWeight: FontWeight.w700));
    double widest = 0;
    for (final String label in labels) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
        textScaler: TextScaler.noScaling,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The segments share the width evenly inside the shell's ring; the
        // capsule pads its label by 12 a side.
        final double segment =
            (constraints.maxWidth -
                (labels.length + 1) * PillGeometry.filterInset) /
            labels.length;
        final double room = segment - 24 - 2;
        final double fit = widest <= 0 ? reader : room / widest;
        final double factor = math.max(_kMinLabelScale, math.min(reader, fit));
        final Widget group = ConnectedGroup(
          labels: labels,
          selected: selected,
          onSelected: onSelected,
          margin: EdgeInsets.zero,
        );
        if (factor >= reader) return group;
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(factor)),
          child: group,
        );
      },
    );
  }
}

/// One mail in the list: sender, date, subject, the agent's note or the
/// snippet, and the tags that say what kind of mail it is.
class AgentMailRow extends StatelessWidget {
  const AgentMailRow({
    super.key,
    required this.mail,
    required this.onTap,
    required this.now,
  });

  final MailSummary mail;
  final VoidCallback onTap;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final AppLocalizations l = AppLocalizations.of(context)!;
    final bool unread = !mail.read && !mail.outgoing;
    final String? note = mail.agentNote;
    final String? preview = mail.unreadable ? null : note ?? mail.snippet;
    final List<Widget> tags = <Widget>[
      // The owner's own mail says "You" in the name line already.
      if (!mail.outgoing && mail.senderTrust != MailTrust.owner)
        MailTrustBadge(mail.senderTrust),
      if (mail.isDraft) MailTag(l.agentMailDraftBadge),
      if (mail.undeliverable)
        MailTag(
          l.agentMailNotDelivered,
          background: cs.errorContainer,
          foreground: cs.onErrorContainer,
        ),
      if (mail.isBulk) MailTag(l.agentMailBulk),
      if (mail.importance == MailImportance.high)
        MailImportanceTag(mail.importance!),
      if (mail.hasAttachments)
        MailTag(l.agentMailAttachments, icon: Icons.attach_file),
    ];
    return Semantics(
      container: true,
      identifier: 'agent-mail-row',
      child: ExpressiveTile(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Container(
                key: unread
                    ? const ValueKey<String>('agent-mail-unread')
                    : null,
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: unread ? cs.primary : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          mailPartyLabel(l, mail),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: unread
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatMailDate(context, mail.createdAt, now: now),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: unread
                              ? cs.primary
                              : theme.m3.onSurfaceVariant,
                          fontWeight: unread ? FontWeight.w700 : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    mailSubjectLabel(l, mail),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                  if (mail.unreadable) ...<Widget>[
                    const SizedBox(height: 2),
                    Row(
                      key: const ValueKey<String>('agent-mail-unreadable'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: AppIcon(
                            Icons.error_outline,
                            size: 14,
                            color: cs.error,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            l.agentMailUnreadable,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (preview != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (note != null) ...<Widget>[
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: AppIcon(
                              Icons.auto_awesome,
                              size: 14,
                              color: cs.primary,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.m3.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (tags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 4, children: tags),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
