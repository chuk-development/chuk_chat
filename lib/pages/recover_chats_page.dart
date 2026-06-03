import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/password_reset_service.dart';

/// Page for recovering or deleting chats encrypted with old passwords.
class RecoverChatsPage extends StatefulWidget {
  const RecoverChatsPage({super.key});

  @override
  State<RecoverChatsPage> createState() => _RecoverChatsPageState();
}

class _RecoverChatsPageState extends State<RecoverChatsPage> {
  Map<int, int> _lockedInfo = {};
  final Map<int, TextEditingController> _passwordControllers = {};
  final Map<int, bool> _obscurePasswords = {};
  final Map<int, bool> _isRecovering = {};
  final Map<int, String?> _messages = {};
  String? _progressMessage;

  @override
  void initState() {
    super.initState();
    _loadLockedInfo();
  }

  void _loadLockedInfo() {
    // Drive the version list from the registered previous keys, NOT from the
    // locked-chat count: a plaintext cache (kept on desktop) can hold readable
    // copies that zero out the locked count even though the server copies still
    // need recovery. Counts are merged in for display only (0 = unknown here).
    final counts = PasswordResetService.getLockedChatInfo();
    final versions = PasswordResetService.getRecoverableVersions();
    setState(() {
      _lockedInfo = {for (final v in versions) v: counts[v] ?? 0};
      for (final version in _lockedInfo.keys) {
        _passwordControllers.putIfAbsent(version, TextEditingController.new);
        _obscurePasswords.putIfAbsent(version, () => true);
        _isRecovering.putIfAbsent(version, () => false);
      }
    });
  }

  @override
  void dispose() {
    for (final ctrl in _passwordControllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _recoverVersion(int version) async {
    final l = AppLocalizations.of(context)!;
    final password = _passwordControllers[version]?.text.trim() ?? '';
    if (password.isEmpty) {
      setState(() => _messages[version] = l.pleaseEnterOldPassword);
      return;
    }

    setState(() {
      _isRecovering[version] = true;
      _messages[version] = null;
      _progressMessage = l.derivingKey;
    });

    try {
      final count = await PasswordResetService.recoverChatsWithOldPassword(
        oldPassword: password,
        targetVersion: version,
        onProgress: (msg) {
          if (mounted) setState(() => _progressMessage = msg);
        },
      );

      if (!mounted) return;
      setState(() {
        _messages[version] = l.recoveredChats(count);
        _progressMessage = null;
      });

      // Refresh the locked info
      _loadLockedInfo();
    } on RecoveryException catch (e) {
      if (!mounted) return;
      setState(() {
        _messages[version] = e.message;
        _progressMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages[version] = l.recoveryFailed;
        _progressMessage = null;
      });
    } finally {
      if (mounted) {
        setState(() => _isRecovering[version] = false);
      }
    }
  }

  Future<void> _deleteVersion(int version) async {
    final l = AppLocalizations.of(context)!;
    final count = _lockedInfo[version] ?? 0;
    final confirmed = await _showDeleteConfirmation(count);
    if (confirmed != true) return;

    // Second confirmation for many chats
    if (count > 10) {
      final doubleConfirmed = await _showTypeDeleteConfirmation(count);
      if (doubleConfirmed != true) return;
    }

    setState(() {
      _isRecovering[version] = true;
      _messages[version] = null;
      _progressMessage = l.deleting;
    });

    try {
      final deleted = await PasswordResetService.deleteLockedChats(
        keyVersion: version,
        onProgress: (msg) {
          if (mounted) setState(() => _progressMessage = msg);
        },
      );

      if (!mounted) return;
      setState(() {
        _messages[version] = l.deletedChats(deleted);
        _progressMessage = null;
      });
      _loadLockedInfo();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages[version] = l.deletionFailed;
        _progressMessage = null;
      });
    } finally {
      if (mounted) {
        setState(() => _isRecovering[version] = false);
      }
    }
  }

  Future<bool?> _showDeleteConfirmation(int count) {
    final l = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.deleteLockedChatsTitle),
        content: Text(l.deleteLockedChatsBody(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l.deletePermanently),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showTypeDeleteConfirmation(int count) async {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    try {
      return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.areYouSure),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.confirmDeleteChats(count)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(hintText: l.typeDelete),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim() == 'DELETE') {
                  Navigator.of(ctx).pop(true);
                }
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(l.confirmDelete),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconFg = theme.iconTheme.color ?? Colors.white;
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l.recoverEncryptedChats)),
      body: _lockedInfo.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_open, size: 48, color: iconFg.withValues(alpha: 0.3)),
                  const SizedBox(height: 16),
                  Text(
                    l.noLockedChats,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.allChatsAccessible,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: iconFg.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  l.recoverChatsInfo,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 16),
                for (final entry in _lockedInfo.entries)
                  _buildVersionCard(entry.key, entry.value, theme, iconFg),
              ],
            ),
    );
  }

  Widget _buildVersionCard(
    int version,
    int count,
    ThemeData theme,
    Color iconFg,
  ) {
    final isWorking = _isRecovering[version] ?? false;
    final message = _messages[version];
    final l = AppLocalizations.of(context)!;
    final isError = message == l.recoveryFailed ||
        message == l.deletionFailed ||
        message == l.pleaseEnterOldPassword;
    final isSuccess = message != null && !isError;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    count > 0
                        ? l.lockedChatCount(count)
                        : l.chatsFromPreviousPassword,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l.encryptedWithVersion(version),
              style: theme.textTheme.bodySmall?.copyWith(
                color: iconFg.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordControllers[version],
              obscureText: _obscurePasswords[version] ?? true,
              enabled: !isWorking,
              decoration: InputDecoration(
                labelText: l.oldPassword,
                hintText: l.enterOldPassword,
                suffixIcon: IconButton(
                  icon: Icon(
                    (_obscurePasswords[version] ?? true)
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscurePasswords[version] =
                          !(_obscurePasswords[version] ?? true);
                    });
                  },
                ),
              ),
              onSubmitted: (_) {
                if (!isWorking) _recoverVersion(version);
              },
            ),
            if (message != null) ...[
              const SizedBox(height: 12),
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSuccess
                      ? Colors.green
                      : Colors.redAccent,
                ),
              ),
            ],
            if (isWorking && _progressMessage != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _progressMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: iconFg.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: isWorking ? null : () => _recoverVersion(version),
                    icon: const Icon(Icons.lock_open, size: 18),
                    label: Text(l.recover),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: isWorking ? null : () => _deleteVersion(version),
                  icon: const Icon(Icons.delete_forever, size: 18),
                  label: Text(l.delete),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
