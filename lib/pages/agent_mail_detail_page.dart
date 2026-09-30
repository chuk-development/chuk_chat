// lib/pages/agent_mail_detail_page.dart
//
// One mail of the agent mailbox (docs/AGENT_MAIL.md §6): sender, trust
// badge, date, the agent's note, the text and the attachments, with archive,
// delete, trust sender and block sender. A draft the agent wrote can be
// edited and sent, or discarded. The app never renders mail HTML: it shows
// `text_body`, as selectable plain text.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agent_mail_widgets.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

/// What happened to the mail while its page was open. The list uses it to
/// drop the row or to ask the server again.
enum AgentMailOutcome {
  /// Still in its folder, but something about it changed (the sender was
  /// trusted or blocked).
  changed,

  /// No longer in the folder it was opened from: archived, moved, deleted,
  /// sent or discarded.
  removed,
}

class AgentMailDetailPage extends StatefulWidget {
  const AgentMailDetailPage({
    super.key,
    required this.summary,
    this.service,
    this.fileSaver = const DownloadsAgentFileSaver(),
  });

  /// The row the page was opened from. The header draws from it while the
  /// full mail loads.
  final MailSummary summary;

  /// Null uses [AgentMailService.instance].
  final AgentMailService? service;
  final AgentFileSaver fileSaver;

  @override
  State<AgentMailDetailPage> createState() => _AgentMailDetailPageState();
}

class _AgentMailDetailPageState extends State<AgentMailDetailPage> {
  AgentMailService get _service => widget.service ?? AgentMailService.instance;

  MailMessage? _message;
  Object? _error;
  bool _loading = true;

  /// An action is on its way to the server; the others wait.
  bool _busy = false;
  AgentMailOutcome? _outcome;

  /// The sender was trusted or blocked on this page.
  bool _trustedNow = false;
  bool _blockedNow = false;

  final Set<String> _saving = <String>{};

  final TextEditingController _subject = TextEditingController();
  final TextEditingController _text = TextEditingController();

  MailSummary get _summary => _message?.summary ?? widget.summary;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _subject.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MailMessage message = await _service.message(widget.summary.id);
      if (!mounted) return;
      setState(() {
        _message = message;
        _loading = false;
        _subject.text = message.summary.subject;
        _text.text = message.textBody;
      });
      if (!message.summary.read && !message.summary.outgoing) {
        unawaited(_markRead());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _markRead() async {
    try {
      await _service.update(widget.summary.id, read: true);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('agent mail: read mark failed (${error.runtimeType})');
      }
      if (!mounted) return;
      AppNotifications.error(
        context,
        agentMailErrorText(AppLocalizations.of(context)!, error),
      );
    }
  }

  /// Runs one server action with the page locked. Returns false when it
  /// failed; the failure is on screen by then.
  Future<bool> _run(Future<void> Function() action) async {
    if (_busy) return false;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } catch (error) {
      AppNotifications.showOn(
        messenger,
        agentMailErrorText(l, error),
        kind: AppNotificationKind.error,
        duration: const Duration(seconds: 4),
      );
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _leave(String message) {
    AppNotifications.show(context, message, kind: AppNotificationKind.success);
    Navigator.of(context).pop(AgentMailOutcome.removed);
  }

  Future<void> _move(MailFolder folder) async {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final bool ok = await _run(
      () => _service.update(widget.summary.id, folder: folder),
    );
    if (!ok || !mounted) return;
    _leave(switch (folder) {
      MailFolder.archive => l.agentMailArchived,
      MailFolder.sent => l.agentMailMovedToSent,
      _ => l.agentMailMovedToInbox,
    });
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirm,
  }) async {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _delete() async {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final bool draft = _summary.isDraft;
    final bool confirmed = await _confirm(
      title: draft ? l.agentMailDiscardTitle : l.agentMailDeleteTitle,
      body: draft ? l.agentMailDiscardBody : l.agentMailDeleteBody,
      confirm: draft ? l.agentMailDiscard : l.agentMailDelete,
    );
    if (!confirmed || !mounted) return;
    final bool ok = await _run(() => _service.delete(widget.summary.id));
    if (!ok || !mounted) return;
    _leave(draft ? l.agentMailDiscarded : l.agentMailDeleted);
  }

  Future<void> _trust() async {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final bool ok = await _run(() => _service.trust(_summary.fromAddress));
    if (!ok || !mounted) return;
    setState(() {
      _trustedNow = true;
      _blockedNow = false;
      _outcome = AgentMailOutcome.changed;
    });
    AppNotifications.show(
      context,
      l.agentMailSenderTrusted,
      kind: AppNotificationKind.success,
    );
  }

  Future<void> _block() async {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final bool confirmed = await _confirm(
      title: l.agentMailBlockTitle(_summary.fromAddress),
      body: l.agentMailBlockBody,
      confirm: l.agentMailBlock,
    );
    if (!confirmed || !mounted) return;
    final bool ok = await _run(() => _service.block(_summary.fromAddress));
    if (!ok || !mounted) return;
    setState(() {
      _blockedNow = true;
      _trustedNow = false;
      _outcome = AgentMailOutcome.changed;
    });
    AppNotifications.show(
      context,
      l.agentMailSenderBlocked,
      kind: AppNotificationKind.success,
    );
  }

  Future<void> _sendDraft() async {
    final MailMessage? message = _message;
    if (message == null) return;
    final AppLocalizations l = AppLocalizations.of(context)!;
    // Only what the user changed goes back; the rest stays the agent's.
    final String subject = _subject.text;
    final String text = _text.text;
    MailSendResult? result;
    final bool ok = await _run(() async {
      result = await _service.sendDraft(
        message.id,
        subject: subject != message.summary.subject ? subject : null,
        text: text != message.textBody ? text : null,
      );
    });
    if (!ok || !mounted) return;
    if (result?.sent ?? true) {
      _leave(l.agentMailSent);
    } else {
      AppNotifications.show(context, l.agentMailKeptAsDraft);
    }
  }

  Future<void> _save(MailAttachment attachment) async {
    if (_saving.contains(attachment.id)) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l = AppLocalizations.of(context)!;
    setState(() => _saving.add(attachment.id));
    try {
      final Uint8List bytes = await _service.attachment(
        widget.summary.id,
        attachment.id,
      );
      final String where = await widget.fileSaver.save(
        AgentsRelayFile(
          name: attachment.filename,
          mimeType: attachment.contentType ?? 'application/octet-stream',
          declaredSize: attachment.size,
          bytes: bytes,
        ),
      );
      AppNotifications.showOn(
        messenger,
        l.agentMailSaved(where),
        kind: AppNotificationKind.success,
      );
    } catch (error) {
      AppNotifications.showOn(
        messenger,
        error is AgentMailException
            ? agentMailErrorText(l, error)
            : l.agentMailDownloadFailed,
        kind: AppNotificationKind.error,
        duration: const Duration(seconds: 4),
      );
    } finally {
      if (mounted) setState(() => _saving.remove(attachment.id));
    }
  }

  MailTrust get _shownTrust {
    if (_trustedNow) return MailTrust.trusted;
    if (_blockedNow) return MailTrust.unknown;
    return _summary.senderTrust;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    return PopScope<AgentMailOutcome>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, AgentMailOutcome? result) {
        if (didPop) return;
        Navigator.of(context).pop(_outcome);
      },
      child: Scaffold(
        // The page runs underneath the floating header.
        extendBodyBehindAppBar: true,
        appBar: FloatingAppBar(
          title: Text(_summary.isDraft ? l.agentMailDraft : l.agentMailMessage),
        ),
        body: SettingsListView(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: _body(context, l),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l) {
    final ThemeData theme = Theme.of(context);
    final MailSummary mail = _summary;
    final MailMessage? message = _message;
    final bool draft = mail.isDraft;
    return <Widget>[
      if (!draft) ...<Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SelectableText(
            mailSubjectLabel(l, mail),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (draft) ...<Widget>[
        ExpressiveInfoCard(text: l.agentMailDraftInfo),
        const SizedBox(height: 12),
      ],
      _header(context, l, mail, message),
      if (!mail.outgoing &&
          _shownTrust == MailTrust.unknown &&
          !_blockedNow) ...<Widget>[
        const SizedBox(height: 12),
        ExpressiveInfoCard(
          icon: Icons.warning_amber_rounded,
          text: l.agentMailUnknownSenderInfo,
        ),
      ],
      if (mail.agentNote != null || mail.importance != null) ...<Widget>[
        ExpressiveSectionHeader(
          l.agentMailAgentNote,
          trailing: mail.importance == null
              ? null
              : MailImportanceTag(mail.importance!),
        ),
        if (mail.agentNote != null)
          ExpressiveGroup(
            children: <Widget>[
              ExpressiveCard(
                child: SelectableText(
                  mail.agentNote!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
      ],
      if (_loading) ...<Widget>[
        const SizedBox(height: 32),
        const Center(child: ExpressiveLoader(size: 40)),
      ] else if (_error != null) ...<Widget>[
        const SizedBox(height: 16),
        ExpressiveInfoCard(
          icon: Icons.error_outline,
          text:
              '${l.agentMailLoadMessageFailed}. '
              '${agentMailErrorText(l, _error!)}',
        ),
        const SizedBox(height: 12),
        ExpressiveGroup(
          children: <Widget>[
            ExpressiveRow(
              icon: Icons.refresh,
              title: l.retry,
              onTap: () => unawaited(_load()),
            ),
          ],
        ),
      ] else if (message != null) ...<Widget>[
        if (draft)
          ..._draftEditor(context, l)
        else
          ..._textSection(context, l, message),
        if (message.attachments.isNotEmpty) ...<Widget>[
          ExpressiveSectionHeader(l.agentMailAttachments),
          ExpressiveGroup(
            children: <Widget>[
              for (final MailAttachment a in message.attachments)
                _AttachmentTile(
                  attachment: a,
                  saving: _saving.contains(a.id),
                  onSave: () => unawaited(_save(a)),
                ),
            ],
          ),
        ],
        if (!draft) ..._actions(l, mail),
      ],
    ];
  }

  Widget _header(
    BuildContext context,
    AppLocalizations l,
    MailSummary mail,
    MailMessage? message,
  ) {
    final List<Widget> rows = <Widget>[
      if (!mail.outgoing)
        _FieldTile(
          label: l.agentMailFrom,
          value: mailSenderName(l, mail),
          detail: mailSenderAddress(l, mail),
          // "You" is already the name line; a tag would say it twice.
          trailing: mail.senderTrust == MailTrust.owner
              ? null
              : MailTrustBadge(_shownTrust),
        ),
      _FieldTile(
        label: l.agentMailToLabel,
        value: mail.toAddresses.isEmpty ? '—' : mail.toAddresses.join(', '),
      ),
      if (message != null && message.ccAddresses.isNotEmpty)
        _FieldTile(label: l.agentMailCc, value: message.ccAddresses.join(', ')),
      if (mail.createdAt != null)
        _FieldTile(
          label: l.agentMailDate,
          value: formatMailDateTime(context, mail.createdAt),
        ),
      if (!mail.outgoing && message != null && !message.auth.isEmpty)
        _FieldTile(
          label: l.agentMailSenderCheck,
          value: <String>[
            if (message.auth.spf != null) 'SPF ${message.auth.spf}',
            if (message.auth.dkim != null) 'DKIM ${message.auth.dkim}',
            if (message.auth.dmarc != null) 'DMARC ${message.auth.dmarc}',
          ].join(' · '),
        ),
    ];
    return ExpressiveGroup(children: rows);
  }

  List<Widget> _textSection(
    BuildContext context,
    AppLocalizations l,
    MailMessage message,
  ) {
    final ThemeData theme = Theme.of(context);
    final String body = message.textBody.trimRight();
    return <Widget>[
      ExpressiveSectionHeader(l.agentMailText),
      ExpressiveGroup(
        children: <Widget>[
          ExpressiveCard(
            child: body.isEmpty
                ? Text(
                    l.agentMailNoText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                  )
                : SelectableText(
                    body,
                    key: const ValueKey<String>('agent-mail-text'),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _draftEditor(BuildContext context, AppLocalizations l) {
    return <Widget>[
      ExpressiveSectionHeader(l.agentMailDraft),
      _DraftField(
        fieldKey: const ValueKey<String>('agent-mail-draft-subject'),
        label: l.agentMailSubject,
        controller: _subject,
        enabled: !_busy,
        minLines: 1,
        maxLines: 3,
        maxLength: 300,
        singleLine: true,
      ),
      const SizedBox(height: 8),
      _DraftField(
        fieldKey: const ValueKey<String>('agent-mail-draft-text'),
        label: l.agentMailBody,
        controller: _text,
        enabled: !_busy,
        minLines: 6,
        maxLines: null,
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          ExpressiveButton(
            key: const ValueKey<String>('agent-mail-draft-send'),
            icon: Icons.send,
            label: l.agentMailSend,
            onTap: () => unawaited(_sendDraft()),
          ),
          ExpressiveButton(
            key: const ValueKey<String>('agent-mail-draft-discard'),
            icon: Icons.delete_outline,
            label: l.agentMailDiscard,
            tonal: true,
            onTap: () => unawaited(_delete()),
          ),
        ],
      ),
    ];
  }

  List<Widget> _actions(AppLocalizations l, MailSummary mail) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool canJudge =
        !mail.outgoing &&
        mail.senderTrust != MailTrust.owner &&
        mail.fromAddress.isNotEmpty;
    final bool archived = mail.folder == MailFolder.archive;
    VoidCallback? unlessBusy(Future<void> Function() action) =>
        _busy ? null : () => unawaited(action());
    return <Widget>[
      ExpressiveSectionHeader(l.agentMailActions),
      ExpressiveGroup(
        children: <Widget>[
          if (archived)
            // Back to where it came from: a sent mail to Sent, not the inbox.
            ExpressiveRow(
              icon: Icons.move_to_inbox_outlined,
              title: mail.homeFolder == MailFolder.sent
                  ? l.agentMailMoveToSent
                  : l.agentMailMoveToInbox,
              onTap: unlessBusy(() => _move(mail.homeFolder)),
            )
          else
            ExpressiveRow(
              icon: Icons.archive_outlined,
              title: l.agentMailArchive,
              onTap: unlessBusy(() => _move(MailFolder.archive)),
            ),
          if (canJudge && !_trustedNow && mail.senderTrust != MailTrust.trusted)
            ExpressiveRow(
              icon: Icons.how_to_reg_outlined,
              title: l.agentMailTrustSender,
              subtitle: l.agentMailTrustSenderSubtitle,
              onTap: unlessBusy(_trust),
            ),
          if (canJudge && !_blockedNow)
            ExpressiveRow(
              icon: Icons.person_off_outlined,
              title: l.agentMailBlockSender,
              subtitle: l.agentMailBlockSenderSubtitle,
              onTap: unlessBusy(_block),
            ),
          ExpressiveRow(
            icon: Icons.delete_outline,
            title: l.agentMailDelete,
            tone: cs.errorContainer,
            onTap: unlessBusy(_delete),
          ),
        ],
      ),
    ];
  }
}

/// One field of the draft: the app's filled field, its label inside it over
/// the text, and the text starting at the field's own padding. The whole
/// field takes the tap, not only the line under the label.
class _DraftField extends StatefulWidget {
  const _DraftField({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.enabled,
    required this.minLines,
    required this.maxLines,
    this.maxLength,
    this.singleLine = false,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final bool enabled;
  final int minLines;
  final int? maxLines;
  final int? maxLength;

  /// A subject: it wraps to show itself, but Enter never adds a line.
  final bool singleLine;

  @override
  State<_DraftField> createState() => _DraftFieldState();
}

class _DraftFieldState extends State<_DraftField> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.enabled ? _focus.requestFocus : null,
      child: ExpressiveField(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.m3.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              key: widget.fieldKey,
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              keyboardType: widget.singleLine
                  ? TextInputType.text
                  : TextInputType.multiline,
              textInputAction: widget.singleLine
                  ? TextInputAction.next
                  : TextInputAction.newline,
              inputFormatters: <TextInputFormatter>[
                if (widget.singleLine)
                  FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
                if (widget.maxLength != null)
                  LengthLimitingTextInputFormatter(widget.maxLength),
              ],
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                height: 1.4,
              ),
              // Collapsed: no fill, border or padding of its own, so the text
              // lines up with the label and the field is the only surface.
              decoration: const InputDecoration.collapsed(hintText: null),
            ),
          ],
        ),
      ),
    );
  }
}

/// A label over its value, the value free to wrap: an address is never cut.
class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.label,
    required this.value,
    this.detail,
    this.trailing,
  });

  final String label;
  final String value;
  final String? detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ExpressiveTile(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.m3.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (detail != null)
                  SelectableText(
                    detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// One attachment: its name in full (the extension matters), its size, and a
/// save target when the server kept the file.
class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.attachment,
    required this.saving,
    required this.onSave,
  });

  final MailAttachment attachment;
  final bool saving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = AppLocalizations.of(context)!;
    final String detail = attachment.available
        ? <String>[
            formatMailBytes(attachment.size),
            ?attachment.contentType,
          ].where((String s) => s.isNotEmpty).join(' · ')
        : attachment.tooLarge
        ? l.agentMailAttachmentTooLarge
        : l.agentMailAttachmentUnavailable;
    return ExpressiveTile(
      child: Row(
        children: <Widget>[
          const ExpressiveIconTile(icon: Icons.attach_file),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  attachment.filename,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (attachment.available) ...<Widget>[
            const SizedBox(width: 8),
            saving
                ? const SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    ),
                  )
                : ExpressiveIconButton(
                    key: ValueKey<String>(
                      'agent-mail-attachment-save-${attachment.id}',
                    ),
                    hugeIcon: HugeIcons.download01,
                    tooltip: l.agentMailDownload,
                    onTap: onSave,
                  ),
          ],
        ],
      ),
    );
  }
}
