import 'package:flutter/material.dart';

import 'package:chuk_chat/services/session_tracking_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class SessionManagementPage extends StatefulWidget {
  const SessionManagementPage({super.key});

  @override
  State<SessionManagementPage> createState() => _SessionManagementPageState();
}

class _SessionManagementPageState extends State<SessionManagementPage> {
  List<SessionRecord>? _sessions;
  String? _currentSessionId;
  bool _isLoading = true;
  bool _isRevoking = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final sessions = await SessionTrackingService.listActiveSessions();
      final currentId = await SessionTrackingService.getCurrentSessionId();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _currentSessionId = currentId;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load sessions: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _revokeSession(SessionRecord session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out device?'),
        content: Text(
          'Sign out "${session.deviceName}" (${session.platform})? '
          'That device will need to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isRevoking = true);

    final ok = await SessionTrackingService.revokeSession(session.id);
    if (!mounted) return;

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session revoked')),
      );
      await _loadSessions();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to revoke session')),
      );
    }

    setState(() => _isRevoking = false);
  }

  Future<void> _revokeAllOthers() async {
    final otherCount = (_sessions ?? [])
        .where((s) => s.id != _currentSessionId)
        .length;

    if (otherCount == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out all other devices?'),
        content: Text(
          'This will sign out $otherCount other '
          '${otherCount == 1 ? 'device' : 'devices'}. '
          'They will need to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out all'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isRevoking = true);

    final ok = await SessionTrackingService.revokeAllOtherSessions();
    if (!mounted) return;

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All other sessions revoked')),
      );
      await _loadSessions();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to revoke sessions')),
      );
    }

    setState(() => _isRevoking = false);
  }

  IconData _iconForPlatform(String platform) {
    switch (platform) {
      case 'android':
      case 'ios':
        return Icons.phone_android;
      case 'web':
        return Icons.language;
      case 'linux':
      case 'macos':
      case 'windows':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }

  String _formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(dateTime.toUtc());

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.resolvedIconColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    Widget body;

    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_errorMessage != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_errorMessage!, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadSessions,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else {
      final sessions = _sessions ?? [];
      final otherCount = sessions.where((s) => s.id != _currentSessionId).length;

      body = RefreshIndicator(
        onRefresh: _loadSessions,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (otherCount > 0) ...[
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  icon: _isRevoking
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.logout),
                  label: Text(
                    'Sign out all other devices ($otherCount)',
                  ),
                  onPressed: _isRevoking ? null : _revokeAllOthers,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'Active sessions',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Devices where your account is currently signed in.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: iconFg.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            ...sessions.map((session) {
              final isCurrent = session.id == _currentSessionId;
              return _SessionTile(
                session: session,
                isCurrent: isCurrent,
                relativeTime: _formatRelativeTime(session.lastSeenAt),
                icon: _iconForPlatform(session.platform),
                onRevoke: isCurrent || _isRevoking
                    ? null
                    : () => _revokeSession(session),
              );
            }),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  'No active sessions found.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: iconFg.withValues(alpha: 0.5),
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Connected Devices', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: body,
    );
  }
}

class _SessionTile extends StatelessWidget {
  final SessionRecord session;
  final bool isCurrent;
  final String relativeTime;
  final IconData icon;
  final VoidCallback? onRevoke;

  const _SessionTile({
    required this.session,
    required this.isCurrent,
    required this.relativeTime,
    required this.icon,
    this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    final Color bg = theme.scaffoldBackgroundColor.lighten(0.05);
    final Color border = iconFg.withValues(alpha: 0.25);

    return Card(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isCurrent
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : border,
          width: 1,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 32, color: iconFg.withValues(alpha: 0.7)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        session.deviceName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'This device',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${session.platform}'
                    '${session.appVersion != null ? ' \u00b7 v${session.appVersion}' : ''}'
                    ' \u00b7 $relativeTime',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            if (!isCurrent)
              IconButton(
                icon: const Icon(Icons.logout, size: 20),
                color: Colors.redAccent,
                tooltip: 'Sign out this device',
                onPressed: onRevoke,
              ),
          ],
        ),
      ),
    );
  }
}
