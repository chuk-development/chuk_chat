// lib/widgets/email_draft_card.dart
//
// The card an `<email>` block renders as (message_bubble/rich_blocks.dart):
// a small "Mail" head, the subject in bold, From / To / Cc / Bcc rows with
// muted labels and hairline dividers, the body, and a footer with the
// draft's status on the left and "Copy" plus a filled "Send" on the right.
//
// "Send" opens the reader's mail app with the draft filled in (the mailto
// launch the card always had); nothing is sent from chuk itself. "Copy"
// puts the whole draft on the clipboard. There is no draft store behind
// this card, so it does not pretend to save one.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// The fixed strings of the card. Kept here, next to the card, in the app's
/// five languages.
class _EmailStrings {
  const _EmailStrings(
    this.mail,
    this.from,
    this.to,
    this.draft,
    this.copy,
    this.send,
    this.copied,
    this.noSubject,
  );
  final String mail;
  final String from;
  final String to;
  final String draft;
  final String copy;
  final String send;
  final String copied;
  final String noSubject;
}

const Map<String, _EmailStrings> _kStrings = <String, _EmailStrings>{
  'en': _EmailStrings(
    'Mail',
    'From',
    'To',
    'Draft',
    'Copy',
    'Send',
    'Draft copied',
    'No subject',
  ),
  'de': _EmailStrings(
    'Mail',
    'Von',
    'An',
    'Entwurf',
    'Kopieren',
    'Senden',
    'Entwurf kopiert',
    'Kein Betreff',
  ),
  'es': _EmailStrings(
    'Correo',
    'De',
    'Para',
    'Borrador',
    'Copiar',
    'Enviar',
    'Borrador copiado',
    'Sin asunto',
  ),
  'fr': _EmailStrings(
    'Mail',
    'De',
    'À',
    'Brouillon',
    'Copier',
    'Envoyer',
    'Brouillon copié',
    'Sans objet',
  ),
  'pt': _EmailStrings(
    'E-mail',
    'De',
    'Para',
    'Rascunho',
    'Copiar',
    'Enviar',
    'Rascunho copiado',
    'Sem assunto',
  ),
};

class EmailDraftCard extends StatelessWidget {
  const EmailDraftCard({
    super.key,
    required this.to,
    required this.subject,
    required this.body,
    required this.onSend,
    this.from = '',
    this.cc = '',
    this.bcc = '',
    this.status = '',
  });

  final String to;
  final String subject;
  final String body;
  final String from;
  final String cc;
  final String bcc;

  /// The draft's state as the model wrote it ("Needs approval"); empty shows
  /// the word "Draft".
  final String status;

  /// Opens the mail app with the draft.
  final VoidCallback onSend;

  /// The whole draft as plain text, what "Copy" puts on the clipboard.
  String get plainText {
    final StringBuffer b = StringBuffer();
    if (to.isNotEmpty) b.writeln('To: $to');
    if (cc.isNotEmpty) b.writeln('Cc: $cc');
    if (bcc.isNotEmpty) b.writeln('Bcc: $bcc');
    if (subject.isNotEmpty) b.writeln('Subject: $subject');
    if (b.isNotEmpty) b.writeln();
    b.write(body);
    return b.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final _EmailStrings t =
        _kStrings[Localizations.maybeLocaleOf(context)?.languageCode] ??
        _kStrings['en']!;
    final Color muted = cs.onSurfaceVariant;
    final Color hairline = cs.outlineVariant.withValues(alpha: 0.6);

    final List<(String, String)> rows = <(String, String)>[
      if (from.isNotEmpty) (t.from, from),
      if (to.isNotEmpty) (t.to, to),
      if (cc.isNotEmpty) ('Cc', cc),
      if (bcc.isNotEmpty) ('Bcc', bcc),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              HugeIcon(HugeIcons.mail01, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                t.mail,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subject.isNotEmpty ? subject : t.noSubject,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          for (final (String label, String value) in rows) ...<Widget>[
            Divider(height: 1, thickness: 1, color: hairline),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 48,
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          Divider(height: 1, thickness: 1, color: hairline),
          if (body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: SelectableText(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface,
                  height: 1.45,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      status.isNotEmpty ? status : t.draft,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () async {
                  final ScaffoldMessengerState? messenger =
                      ScaffoldMessenger.maybeOf(context);
                  await Clipboard.setData(ClipboardData(text: plainText));
                  messenger?.showSnackBar(SnackBar(content: Text(t.copied)));
                },
                child: Text(t.copy),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: onSend,
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(t.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
