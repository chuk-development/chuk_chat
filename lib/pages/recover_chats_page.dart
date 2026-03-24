import 'package:flutter/material.dart';

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
    final info = PasswordResetService.getLockedChatInfo();
    setState(() {
      _lockedInfo = info;
      for (final version in info.keys) {
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
    final password = _passwordControllers[version]?.text.trim() ?? '';
    if (password.isEmpty) {
      setState(() => _messages[version] = 'Please enter your old password.');
      return;
    }

    setState(() {
      _isRecovering[version] = true;
      _messages[version] = null;
      _progressMessage = 'Deriving encryption key...';
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
        _messages[version] = 'Successfully recovered $count chat${count == 1 ? '' : 's'}.';
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
        _messages[version] = 'Recovery failed. Please try again.';
        _progressMessage = null;
      });
    } finally {
      if (mounted) {
        setState(() => _isRecovering[version] = false);
      }
    }
  }

  Future<void> _deleteVersion(int version) async {
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
      _progressMessage = 'Deleting...';
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
        _messages[version] = 'Deleted $deleted chat${deleted == 1 ? '' : 's'}.';
        _progressMessage = null;
      });
      _loadLockedInfo();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages[version] = 'Deletion failed. Please try again.';
        _progressMessage = null;
      });
    } finally {
      if (mounted) {
        setState(() => _isRecovering[version] = false);
      }
    }
  }

  Future<bool?> _showDeleteConfirmation(int count) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete locked chats?'),
        content: Text(
          'This will permanently delete $count chat${count == 1 ? '' : 's'} '
          'that are encrypted with your old password.\n\n'
          'These chats cannot be recovered after deletion. '
          'You will lose all messages, images, and attachments.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showTypeDeleteConfirmation(int count) {
    final controller = TextEditingController();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Are you sure?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You are about to delete $count chats. Type DELETE to confirm.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Type DELETE'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim() == 'DELETE') {
                Navigator.of(ctx).pop(true);
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Confirm delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconFg = theme.iconTheme.color ?? Colors.white;

    return Scaffold(
      appBar: AppBar(title: const Text('Recover Encrypted Chats')),
      body: _lockedInfo.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_open, size: 48, color: iconFg.withValues(alpha: 0.3)),
                  const SizedBox(height: 16),
                  Text(
                    'No locked chats',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'All your chats are accessible.',
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
                  'Some chats are encrypted with a previous password. '
                  'Enter your old password to recover them, or delete them permanently.',
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
    final isSuccess = message != null && message.startsWith('Successfully');
    final isDeleted = message != null && message.startsWith('Deleted');

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
                    '$count locked chat${count == 1 ? '' : 's'}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Encrypted with password version $version',
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
                labelText: 'Old password',
                hintText: 'Enter the password you used before',
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
                  color: (isSuccess || isDeleted)
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
                    label: const Text('Recover'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: isWorking ? null : () => _deleteVersion(version),
                  icon: const Icon(Icons.delete_forever, size: 18),
                  label: const Text('Delete'),
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
