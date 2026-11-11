// lib/widgets/composer/secret_send_guard.dart
//
// Before a send: when the composer text holds what looks like an API key
// (lib/utils/secret_mask.dart, [containsSecret]), ask first. "Send anyway"
// sends; "Edit" keeps the text in the composer and sends nothing.
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/utils/secret_mask.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// True when [text] may go out: it holds no key, or the user chose
/// "Send anyway". Dismissing the dialog counts as "Edit".
Future<bool> confirmSecretSend(BuildContext context, String text) async {
  if (text.trim().isEmpty || !containsSecret(text)) return true;
  final bool? send = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => const SecretSendDialog(),
  );
  return send ?? false;
}

class SecretSendDialog extends StatelessWidget {
  const SecretSendDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey<String>('composer-secret-dialog'),
      icon: AppIcon(Icons.key, size: 24, color: scheme.error),
      title: Text(l.composerSecretTitle, textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(l.composerSecretBody),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('composer-secret-edit'),
          // Edit is the safe default: Enter and Esc both land here.
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.composerSecretEdit),
        ),
        TextButton(
          key: const ValueKey<String>('composer-secret-send'),
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: Text(l.composerSecretSend),
        ),
      ],
    );
  }
}
