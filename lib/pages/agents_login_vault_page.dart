// lib/pages/agents_login_vault_page.dart
//
// Agent settings > Logins: the host's login vault (docs/WIRE_CONTRACT.md,
// "Login vault for the browser"). The page lists the public entries the
// host sends (origin, username, label, 2FA, last used); a password is never
// shown and never kept. The sheet sends `login_vault_set`; its password and
// 2FA fields are cleared the moment the frame is built.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_login_vault.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

/// The host's error text, or the app's words for the two local failures.
String loginVaultErrorText(AppLocalizations l, String error) => switch (error) {
  kLoginVaultNotConnected => l.loginVaultNotConnected,
  kLoginVaultNoReply => l.loginVaultNoReply,
  _ => error,
};

class AgentsLoginVaultPage extends StatefulWidget {
  const AgentsLoginVaultPage({super.key, AgentsLoginVault? vault})
    : _injected = vault;

  final AgentsLoginVault? _injected;

  @override
  State<AgentsLoginVaultPage> createState() => _AgentsLoginVaultPageState();
}

class _AgentsLoginVaultPageState extends State<AgentsLoginVaultPage> {
  AgentsLoginVault get _vault => widget._injected ?? AgentsLoginVault.instance;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final AgentsLoginVaultReply reply = await _vault.refresh();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = reply.error;
    });
  }

  Future<void> _openSheet([AgentsLoginEntry? entry]) async {
    await showLoginVaultSheet(context, vault: _vault, entry: entry);
  }

  Future<void> _delete(AgentsLoginEntry entry) async {
    final AppLocalizations l = _l10n(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l.loginVaultDeleteTitle(entry.origin)),
        content: Text(l.loginVaultDeleteBody),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('login-vault-delete-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.loginVaultCancel),
          ),
          FilledButton(
            key: const ValueKey<String>('login-vault-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.loginVaultDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final AgentsLoginVaultReply reply = await _vault.delete(entry.id);
    if (!mounted) return;
    final String? error = reply.error;
    if (error != null) pillToast(context, loginVaultErrorText(l, error));
  }

  Future<void> _openMenu(BuildContext anchor, AgentsLoginEntry entry) async {
    final ColorScheme scheme = Theme.of(anchor).colorScheme;
    final AppLocalizations l = _l10n(context);
    final String? choice = await showAnchoredMenu<String>(
      anchor,
      color: scheme.surfaceContainerHigh,
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: const ValueKey<String>('login-vault-menu-edit'),
          value: 'edit',
          padding: EdgeInsets.zero,
          child: MenuActionRow(
            icon: Icons.edit_outlined,
            label: l.loginVaultEdit,
          ),
        ),
        PopupMenuItem<String>(
          key: const ValueKey<String>('login-vault-menu-delete'),
          value: 'delete',
          padding: EdgeInsets.zero,
          child: MenuActionRow(
            icon: Icons.delete_outline,
            label: l.loginVaultDelete,
            tone: scheme.error,
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (choice == 'edit') await _openSheet(entry);
    if (choice == 'delete') await _delete(entry);
  }

  String _subtitle(BuildContext context, AgentsLoginEntry entry) {
    final AppLocalizations l = _l10n(context);
    final DateTime? used = entry.lastUsedAt;
    final String usedText = used == null
        ? l.loginVaultNeverUsed
        : l.loginVaultLastUsed(
            MaterialLocalizations.of(context).formatShortDate(used),
          );
    final String? label = entry.label;
    return <String>[
      entry.username,
      ?label,
      usedText,
    ].where((String s) => s.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = _l10n(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(title: Text(l.loginVaultTitle)),
      body: ListenableBuilder(
        listenable: _vault,
        builder: (BuildContext context, _) {
          final List<AgentsLoginEntry> entries = _vault.entries;
          final String? error = _error;
          return SettingsListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: <Widget>[
              Text(
                l.loginVaultIntro,
                key: const ValueKey<String>('login-vault-intro'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              ExpressiveSectionHeader(l.loginVaultSection),
              if (_loading && !_vault.loaded)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ExpressiveGroup(
                children: <Widget>[
                  if (entries.isEmpty && !_loading)
                    ExpressiveRow(
                      key: const ValueKey<String>('login-vault-empty'),
                      icon: Icons.login,
                      title: l.loginVaultEmpty,
                      subtitle: l.loginVaultEmptyHelp,
                    ),
                  for (final AgentsLoginEntry entry in entries)
                    ExpressiveRow(
                      key: ValueKey<String>('login-vault-entry-${entry.id}'),
                      icon: Icons.login,
                      title: entry.origin,
                      titleMaxLines: 2,
                      subtitle: _subtitle(context, entry),
                      onTap: () => unawaited(_openSheet(entry)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (entry.hasTotp)
                            ExpressiveBadge(
                              l.loginVaultBadge2fa,
                              key: ValueKey<String>(
                                'login-vault-2fa-${entry.id}',
                              ),
                            ),
                          Builder(
                            builder: (BuildContext anchor) =>
                                ExpressiveIconButton(
                                  key: ValueKey<String>(
                                    'login-vault-menu-${entry.id}',
                                  ),
                                  hugeIcon: HugeIcons.moreVertical,
                                  size: 40,
                                  color: Colors.transparent,
                                  onColor: theme.colorScheme.onSurfaceVariant,
                                  tooltip: l.loginVaultOptions(entry.origin),
                                  onTap: () =>
                                      unawaited(_openMenu(anchor, entry)),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ExpressiveRow(
                    key: const ValueKey<String>('login-vault-add'),
                    icon: Icons.add,
                    title: l.loginVaultAdd,
                    subtitle: l.loginVaultAddHelp,
                    onTap: () => unawaited(_openSheet()),
                  ),
                ],
              ),
              if (error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  loginVaultErrorText(l, error),
                  key: const ValueKey<String>('login-vault-page-error'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              ExpressiveInfoCard(text: l.loginVaultInfo),
            ],
          );
        },
      ),
    );
  }
}

/// Opens the add / change sheet. Completes with the entry the host saved,
/// or null when the sheet was closed.
Future<AgentsLoginEntry?> showLoginVaultSheet(
  BuildContext context, {
  required AgentsLoginVault vault,
  AgentsLoginEntry? entry,
}) {
  final AppLocalizations l = _l10n(context);
  return expressiveSheet<AgentsLoginEntry>(
    context,
    title: entry == null ? l.loginVaultAdd : l.loginVaultEditTitle,
    child: LoginVaultForm(vault: vault, entry: entry),
  );
}

/// The form inside the sheet. Public so a test can pump it without a sheet.
class LoginVaultForm extends StatefulWidget {
  const LoginVaultForm({super.key, required this.vault, this.entry});

  final AgentsLoginVault vault;

  /// The login being changed: origin and username are fixed then.
  final AgentsLoginEntry? entry;

  @override
  State<LoginVaultForm> createState() => _LoginVaultFormState();
}

class _LoginVaultFormState extends State<LoginVaultForm> {
  late final TextEditingController _site = TextEditingController(
    text: widget.entry?.origin ?? '',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.entry?.username ?? '',
  );
  TextEditingController _password = TextEditingController();
  TextEditingController _totp = TextEditingController();

  /// The undo history of each secret field. A cleared secret must not come
  /// back with an undo (Ctrl+Z, the undo key of a keyboard).
  final UndoHistoryController _passwordUndo = UndoHistoryController();
  final UndoHistoryController _totpUndo = UndoHistoryController();
  late final TextEditingController _label = TextEditingController(
    text: widget.entry?.label ?? '',
  );

  bool _showPassword = false;
  bool _removeTotp = false;
  bool _saving = false;
  String? _fieldKey;
  String? _fieldError;
  String? _hostError;

  bool get _editing => widget.entry != null;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _site,
      _username,
      _password,
      _totp,
      _label,
    ]) {
      c.clear();
      c.dispose();
    }
    _passwordUndo.dispose();
    _totpUndo.dispose();
    super.dispose();
  }

  /// Empties both secret fields AND their undo history.
  ///
  /// `clear()` alone pushes an empty value on the field's undo stack: the
  /// typed secret stays one undo away. The stack belongs to the field's
  /// [TextEditingController] (Flutter drops it when the controller changes),
  /// so each secret field gets a fresh controller; the old one is disposed
  /// after the frame that stops using it. The [UndoHistoryController]s are
  /// reset too, so no undo button offers a step back.
  void _clearSecrets() {
    _password = _fresh(_password);
    _passwordUndo.value = UndoHistoryValue.empty;
    _clearTotp();
  }

  void _clearTotp() {
    _totp = _fresh(_totp);
    _totpUndo.value = UndoHistoryValue.empty;
  }

  static TextEditingController _fresh(TextEditingController old) {
    old.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    return TextEditingController();
  }

  void _fail(String key, String message) => setState(() {
    _fieldKey = key;
    _fieldError = message;
  });

  Future<void> _save() async {
    if (_saving) return;
    final AppLocalizations l = _l10n(context);
    setState(() {
      _fieldKey = null;
      _fieldError = null;
      _hostError = null;
    });
    final String? origin = loginOriginOf(_site.text);
    if (origin == null) return _fail('site', l.loginVaultSiteInvalid);
    if (_username.text.trim().isEmpty) {
      return _fail('username', l.loginVaultErrUsername);
    }
    if (_password.text.isEmpty) {
      return _fail('password', l.loginVaultErrPassword);
    }
    final String label = _label.text.trim();
    // The secrets leave the fields here: they go into the frame and are
    // gone from the app whatever the host answers.
    final Future<AgentsLoginVaultReply> sent = widget.vault.save(
      origin: origin,
      username: _username.text.trim(),
      password: _password.text,
      totpSecret: _removeTotp ? null : _totp.text,
      removeTotp: _editing && _removeTotp,
      // An edit sends the label as it stands (empty clears it); a new
      // login leaves an empty one out.
      label: _editing || label.isNotEmpty ? label : null,
    );
    _clearSecrets();
    setState(() => _saving = true);
    final AgentsLoginVaultReply reply = await sent;
    if (!mounted) return;
    final String? error = reply.error;
    if (error == null) {
      Navigator.of(context).pop(reply.saved);
      return;
    }
    setState(() {
      _saving = false;
      _hostError = loginVaultErrorText(l, error);
    });
  }

  void _clearErrors() {
    if (_fieldKey == null && _hostError == null) return;
    setState(() {
      _fieldKey = null;
      _fieldError = null;
      _hostError = null;
    });
  }

  Widget _help(String key, String? help) {
    final ThemeData theme = Theme.of(context);
    final bool failed = _fieldKey == key;
    final String? text = failed ? _fieldError : help;
    if (text == null) return const SizedBox(height: 10);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Text(
        text,
        key: ValueKey<String>('login-vault-help-$key'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: failed
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _secretField({
    required String key,
    required TextEditingController controller,
    required UndoHistoryController undo,
    required String label,
    Widget? suffix,
    bool obscure = true,
  }) => ExpressiveField(
    child: TextField(
      key: ValueKey<String>('login-vault-field-$key'),
      controller: controller,
      undoController: undo,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      // No copy, no cut: a password must not reach the clipboard history.
      enableInteractiveSelection: false,
      autofillHints: null,
      keyboardType: TextInputType.visiblePassword,
      decoration: InputDecoration(
        border: InputBorder.none,
        labelText: label,
        suffixIcon: suffix,
      ),
      onChanged: (_) => _clearErrors(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = _l10n(context);
    final String? origin = loginOriginOf(_site.text);
    final AgentsLoginEntry? entry = widget.entry;
    final bool hasTotp = entry?.hasTotp ?? false;
    final String? hostError = _hostError;
    return Flexible(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExpressiveField(
              child: TextField(
                key: const ValueKey<String>('login-vault-field-site'),
                controller: _site,
                enabled: !_editing,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  labelText: l.loginVaultSite,
                  hintText: 'https://github.com',
                ),
                onChanged: (_) {
                  _clearErrors();
                  setState(() {});
                },
              ),
            ),
            _help(
              'site',
              origin == null || _editing ? null : l.loginVaultSiteKeeps(origin),
            ),
            ExpressiveField(
              child: TextField(
                key: const ValueKey<String>('login-vault-field-username'),
                controller: _username,
                enabled: !_editing,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  labelText: l.loginVaultUsername,
                ),
                onChanged: (_) => _clearErrors(),
              ),
            ),
            _help('username', null),
            _secretField(
              key: 'password',
              controller: _password,
              undo: _passwordUndo,
              label: l.loginVaultPassword,
              obscure: !_showPassword,
              suffix: ExpressiveIconButton(
                key: const ValueKey<String>('login-vault-toggle-password'),
                hugeIcon: _showPassword ? HugeIcons.viewOff : HugeIcons.view,
                size: 40,
                color: Colors.transparent,
                onColor: theme.colorScheme.onSurfaceVariant,
                tooltip: _showPassword
                    ? l.loginVaultHidePassword
                    : l.loginVaultShowPassword,
                onTap: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
            _help('password', _editing ? l.loginVaultPasswordEditHelp : null),
            if (!_removeTotp) ...<Widget>[
              _secretField(
                key: 'totp',
                controller: _totp,
                undo: _totpUndo,
                label: l.loginVaultTotp,
              ),
              _help(
                'totp',
                hasTotp ? l.loginVaultTotpKeep : l.loginVaultTotpHelp,
              ),
            ],
            if (hasTotp)
              ExpressiveSwitchRow(
                key: const ValueKey<String>('login-vault-remove-totp'),
                title: l.loginVaultTotpRemove,
                value: _removeTotp,
                onChanged: _saving
                    ? null
                    : (bool v) => setState(() {
                        _removeTotp = v;
                        if (v) _clearTotp();
                      }),
              ),
            ExpressiveField(
              child: TextField(
                key: const ValueKey<String>('login-vault-field-label'),
                controller: _label,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  labelText: l.loginVaultLabel,
                ),
                onChanged: (_) => _clearErrors(),
              ),
            ),
            const SizedBox(height: 12),
            ExpressiveInfoCard(
              key: const ValueKey<String>('login-vault-model-never'),
              text: l.loginVaultModelNever,
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: Opacity(
                opacity: _saving ? 0.6 : 1,
                child: ExpressiveButton(
                  key: const ValueKey<String>('login-vault-save'),
                  label: l.loginVaultSave,
                  icon: Icons.check,
                  onTap: () => unawaited(_save()),
                ),
              ),
            ),
            if (_saving)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (hostError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  hostError,
                  key: const ValueKey<String>('login-vault-error'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
