// lib/pages/agent_mail_contacts_page.dart
//
// Mailbox > Contacts (docs/AGENT_MAIL.md §2, §8): the addresses and domains
// the mailbox trusts or blocks. A trusted sender starts normal runs and the
// agent may write to it without a draft; mail from a blocked one is dropped.
// The server keeps each label sealed; it is opened here, and a contact is
// removed by its id.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agent_mail_widgets.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

class AgentMailContactsPage extends StatefulWidget {
  const AgentMailContactsPage({super.key, this.service});

  /// Null uses [AgentMailService.instance].
  final AgentMailService? service;

  @override
  State<AgentMailContactsPage> createState() => _AgentMailContactsPageState();
}

class _AgentMailContactsPageState extends State<AgentMailContactsPage> {
  AgentMailService get _service => widget.service ?? AgentMailService.instance;

  bool _loading = true;
  Object? _error;
  List<MailContact> _contacts = const <MailContact>[];

  /// Contact ids with a change on its way, so a second tap waits.
  final Set<String> _pending = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<MailContact> contacts = await _service.contacts();
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _remove(MailContact contact) async {
    if (_pending.contains(contact.id)) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l = AppLocalizations.of(context)!;
    setState(() => _pending.add(contact.id));
    try {
      await _service.deleteContact(contact.id);
      if (!mounted) return;
      setState(() {
        _contacts = <MailContact>[
          for (final MailContact c in _contacts)
            if (c.id != contact.id) c,
        ];
      });
      AppNotifications.showOn(
        messenger,
        l.agentMailContactRemoved,
        kind: AppNotificationKind.success,
      );
    } catch (error) {
      AppNotifications.showOn(
        messenger,
        agentMailErrorText(l, error),
        kind: AppNotificationKind.error,
        duration: const Duration(seconds: 4),
      );
    } finally {
      if (mounted) setState(() => _pending.remove(contact.id));
    }
  }

  Future<void> _add() async {
    final (String, bool)? entry = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => const _AddContactDialog(),
    );
    if (entry == null || !mounted) return;
    final (String address, bool block) = entry;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l = AppLocalizations.of(context)!;
    try {
      if (block) {
        await _service.block(address);
      } else {
        await _service.trust(address);
      }
      AppNotifications.showOn(
        messenger,
        l.agentMailContactSaved,
        kind: AppNotificationKind.success,
      );
      if (!mounted) return;
      await _load();
    } catch (error) {
      AppNotifications.showOn(
        messenger,
        agentMailErrorText(l, error),
        kind: AppNotificationKind.error,
        duration: const Duration(seconds: 4),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(title: Text(l.agentMailContacts)),
      body: SettingsListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: <Widget>[
          Text(
            l.agentMailContactsIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.resolvedIconColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 12),
          ..._content(l),
        ],
      ),
    );
  }

  List<Widget> _content(AppLocalizations l) {
    if (_loading) {
      return const <Widget>[
        SizedBox(height: 32),
        Center(child: ExpressiveLoader(size: 40)),
      ];
    }
    final Object? error = _error;
    if (error != null) {
      return <Widget>[
        ExpressiveInfoCard(
          icon: Icons.error_outline,
          text: agentMailErrorText(l, error),
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
      ];
    }
    final List<MailContact> blocked = <MailContact>[
      for (final MailContact c in _contacts)
        if (c.blocked) c,
    ];
    final List<MailContact> trusted = <MailContact>[
      for (final MailContact c in _contacts)
        if (!c.blocked && (c.trustedInbound || c.allowedOutbound)) c,
    ];
    return <Widget>[
      ExpressiveSectionHeader(l.agentMailTrusted),
      ExpressiveGroup(
        children: <Widget>[
          if (trusted.isEmpty)
            ExpressiveRow(
              icon: Icons.how_to_reg_outlined,
              title: l.agentMailNoTrusted,
            ),
          for (final MailContact c in trusted)
            _ContactTile(
              key: ValueKey<String>('agent-mail-contact-${c.id}'),
              contact: c,
              icon: Icons.how_to_reg_outlined,
              busy: _pending.contains(c.id),
              onRemove: () => unawaited(_remove(c)),
            ),
        ],
      ),
      ExpressiveSectionHeader(l.agentMailBlocked),
      ExpressiveGroup(
        children: <Widget>[
          if (blocked.isEmpty)
            ExpressiveRow(
              icon: Icons.person_off_outlined,
              title: l.agentMailNoBlocked,
            ),
          for (final MailContact c in blocked)
            _ContactTile(
              key: ValueKey<String>('agent-mail-contact-${c.id}'),
              contact: c,
              icon: Icons.person_off_outlined,
              busy: _pending.contains(c.id),
              onRemove: () => unawaited(_remove(c)),
            ),
        ],
      ),
      const SizedBox(height: 16),
      ExpressiveGroup(
        children: <Widget>[
          ExpressiveRow(
            icon: Icons.add,
            title: l.agentMailAddContact,
            subtitle: l.agentMailAddContactSubtitle,
            onTap: () => unawaited(_add()),
          ),
        ],
      ),
    ];
  }
}

/// One contact: the address in full (it may wrap, it is never cut), what it
/// may do, and a remove target.
class _ContactTile extends StatelessWidget {
  const _ContactTile({
    super.key,
    required this.contact,
    required this.icon,
    required this.busy,
    required this.onRemove,
  });

  final MailContact contact;
  final IconData icon;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = AppLocalizations.of(context)!;
    final String detail = <String>[
      if (contact.isDomain) l.agentMailContactDomain,
      if (!contact.blocked && contact.trustedInbound) l.agentMailContactInbound,
      if (!contact.blocked && contact.allowedOutbound)
        l.agentMailContactOutbound,
    ].join(' · ');
    return ExpressiveTile(
      child: Row(
        children: <Widget>[
          ExpressiveIconTile(icon: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  contact.unreadable
                      ? l.agentMailContactUnreadable
                      : contact.address,
                  style: contact.unreadable
                      ? theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        )
                      : theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                ),
                if (detail.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.m3.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          busy
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
                    'agent-mail-contact-remove-${contact.id}',
                  ),
                  hugeIcon: HugeIcons.delete02,
                  tooltip: l.agentMailRemoveContact,
                  onTap: onRemove,
                ),
        ],
      ),
    );
  }
}

/// Address or `@domain`, then Trust or Block. Pops `(address, block)`.
class _AddContactDialog extends StatefulWidget {
  const _AddContactDialog();

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final TextEditingController _address = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _submit({required bool block}) {
    final String value = _address.text.trim().toLowerCase();
    if (!isValidMailContactAddress(value)) {
      setState(
        () => _error = AppLocalizations.of(context)!.agentMailAddressInvalid,
      );
      return;
    }
    Navigator.pop(context, (value, block));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.agentMailAddContact),
      content: TextField(
        key: const ValueKey<String>('agent-mail-contact-field'),
        controller: _address,
        autofocus: true,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l.agentMailAddressLabel,
          hintText: 'name@example.com',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(block: false),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => _submit(block: true),
          child: Text(l.agentMailBlock),
        ),
        FilledButton(
          onPressed: () => _submit(block: false),
          child: Text(l.agentMailTrust),
        ),
      ],
    );
  }
}
