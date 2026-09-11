// lib/pages/secrets_settings_page.dart
//
// Settings > API Keys: the user's secret set (docs/WIRE_CONTRACT.md,
// "Secrets"). Names are listed; values are never shown, only "set". Add,
// change and delete go through SecretsService, which mirrors the change
// (encrypted) and forwards the whole set to the host.

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/services/secrets/secrets_service.dart';
import 'package:cowork/services/secrets/secrets_store.dart';
import 'package:cowork/widgets/expressive_settings.dart';

class SecretsSettingsPage extends StatefulWidget {
  const SecretsSettingsPage({super.key, SecretsService? service})
    : _injected = service;

  final SecretsService? _injected;

  @override
  State<SecretsSettingsPage> createState() => _SecretsSettingsPageState();
}

class _SecretsSettingsPageState extends State<SecretsSettingsPage> {
  SecretsService get _service => widget._injected ?? SecretsService.instance;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _service.load().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _add() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _SecretDialog(),
    );
    if (result == null) return;
    await _service.set(result.$1, result.$2);
  }

  Future<void> _change(String name) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _SecretDialog(fixedName: name),
    );
    if (result == null) return;
    await _service.set(result.$1, result.$2);
  }

  Future<void> _delete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
          'The agent will no longer have this key. It is removed from this '
          'device, from your encrypted cloud copy and from the host.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.remove(name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpressiveScreen(
      title: 'API Keys',
      builder: (BuildContext context) => _loading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<List<String>>(
              valueListenable: _service.names,
              builder: (context, names, _) {
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    MediaQuery.paddingOf(context).top + 8,
                    16,
                    MediaQuery.paddingOf(context).bottom + 32,
                  ),
                  children: [
                    const ExpressiveTitle(
                      'API Keys',
                      subtitle:
                          'Keys the agent can use in scripts but never read',
                    ),
                    const ExpressiveSectionHeader('Keys'),
                    ExpressiveGroup(
                      children: [
                        if (names.isEmpty)
                          const ExpressiveRow(
                            icon: Icons.key_off_outlined,
                            title: 'No keys yet',
                            subtitle:
                                'Add one here, or let the agent ask for it',
                          ),
                        for (final name in names)
                          ExpressiveRow(
                            icon: Icons.key_outlined,
                            title: name,
                            subtitle: 'Available as \$$name in scripts',
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const ExpressiveBadge('set', icon: Icons.check),
                                PopupMenuButton<String>(
                                  tooltip: 'Options for $name',
                                  onSelected: (choice) {
                                    if (choice == 'change') _change(name);
                                    if (choice == 'delete') _delete(name);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem<String>(
                                      value: 'change',
                                      child: Text('Change value'),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'delete',
                                      child: Text('Delete'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ExpressiveRow(
                          icon: Icons.add,
                          title: 'Add key',
                          subtitle: 'Name and value; the value stays hidden',
                          onTap: _add,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const ExpressiveInfoCard(
                      text:
                          'A key is an environment variable inside the agent\'s '
                          'commands and scripts (PEXELS_API_KEY, OPENAI_API_KEY). '
                          'The agent only ever learns that a key is set; every '
                          'output is masked as [REDACTED:NAME]. Values are '
                          'encrypted on this device and in your cloud copy, and '
                          'sealed to your host.',
                    ),
                    const SizedBox(height: 8),
                    ExpressiveInfoCard(
                      icon: Icons.warning_amber_outlined,
                      text:
                          'Values shorter than ${SecretsStore.redactMinLength} '
                          'characters are not masked in outputs. Use real keys.',
                    ),
                    if (theme.platform == TargetPlatform.linux ||
                        theme.platform == TargetPlatform.windows ||
                        theme.platform == TargetPlatform.macOS)
                      const SizedBox(height: 8),
                  ],
                );
              },
            ),
    );
  }
}

/// Name + value entry. With [fixedName] only the value is asked (change).
class _SecretDialog extends StatefulWidget {
  const _SecretDialog({this.fixedName});

  final String? fixedName;

  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.fixedName ?? '',
  );
  final TextEditingController _value = TextEditingController();
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim().toUpperCase();
    final value = _value.text;
    if (!SecretsStore.validName(name)) {
      setState(() => _nameError = 'Letters, digits and underscores only');
      return;
    }
    if (value.isEmpty) return;
    Navigator.pop(context, (name, value));
  }

  @override
  Widget build(BuildContext context) {
    final change = widget.fixedName != null;
    return AlertDialog(
      title: Text(change ? 'Change ${widget.fixedName}' : 'Add key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!change)
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'PEXELS_API_KEY',
                errorText: _nameError,
              ),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
            ),
          TextField(
            controller: _value,
            autofocus: change,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Value'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Text(
            'Shorter than ${SecretsStore.redactMinLength} characters is not '
            'masked in outputs.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
