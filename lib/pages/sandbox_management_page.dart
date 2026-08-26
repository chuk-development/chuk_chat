import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/pages/github_connection_page.dart';
import 'package:chuk_chat/services/github_connection_service.dart';
import 'package:chuk_chat/services/sandbox_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class SandboxManagementPage extends StatefulWidget {
  const SandboxManagementPage({super.key});

  @override
  State<SandboxManagementPage> createState() => _SandboxManagementPageState();
}

class _SandboxManagementPageState extends State<SandboxManagementPage> {
  bool _loading = true;
  String? _error;
  List<SandboxInfo> _sandboxes = const [];
  final Set<String> _destroying = <String>{};

  // Code hosting: the GitHub connection lives on this screen. We fetch its
  // status only to show the trailing badge — the full flow stays on
  // [GitHubConnectionPage].
  GitHubConnectionStatus _github = GitHubConnectionStatus.disconnected;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    unawaited(_loadGitHubStatus());
  }

  Future<String?> _accessToken() async {
    return SupabaseService.auth.currentSession?.accessToken;
  }

  Future<void> _loadGitHubStatus() async {
    try {
      final token = await _accessToken();
      if (token == null || token.isEmpty) {
        if (mounted) {
          setState(() => _github = GitHubConnectionStatus.disconnected);
        }
        return;
      }
      final status = await GitHubConnectionService.status(accessToken: token);
      if (!mounted) return;
      setState(() => _github = status);
    } catch (_) {
      // The badge falls back to "Connect" if the status cannot be read, so a
      // stale connected state from an earlier load never lingers on failure.
      if (mounted) {
        setState(() => _github = GitHubConnectionStatus.disconnected);
      }
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await _accessToken();
      if (token == null || token.isEmpty) {
        throw SandboxServiceException(401, 'Not signed in.');
      }
      final list = await SandboxService.list(accessToken: token);
      if (!mounted) return;
      setState(() {
        _sandboxes = list;
        _loading = false;
      });
    } on SandboxServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openGitHub() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const GitHubConnectionPage(),
      ),
    );
    // The connection may have changed while the page was open.
    await _loadGitHubStatus();
  }

  Future<void> _destroy(SandboxInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Destroy sandbox?'),
        content: Text(
          'This will stop the running container for session '
          '${_shortId(info.sessionId)}. Files in /home/sandbox are saved '
          'as a snapshot and restored next time the chat opens. The '
          'snapshot expires after 3 days of inactivity.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Destroy'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _destroying.add(info.sessionId));
    try {
      final token = await _accessToken();
      if (token == null || token.isEmpty) {
        throw SandboxServiceException(401, 'Not signed in.');
      }
      await SandboxService.destroy(
        accessToken: token,
        sessionId: info.sessionId,
      );
      // Also drop the client-side cache entry if any chatId was tagged.
      if (info.chatId != null && info.chatId!.isNotEmpty) {
        SandboxSessionCache.forgetChat(info.chatId!);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sandbox destroyed.')),
      );
      await _refresh();
    } on SandboxServiceException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _destroying.remove(info.sessionId));
    }
  }

  String _shortId(String id) => id.length <= 12
      ? id
      : '${id.substring(0, 6)}…${id.substring(id.length - 6)}';

  String _formatTime(DateTime dt) {
    if (dt.millisecondsSinceEpoch == 0) return '—';
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m3 = theme.m3;

    final bool githubConnected = _github.connected;
    final String? login = _github.githubLogin;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sandboxes'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _refresh();
          await _loadGitHubStatus();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const ExpressiveInfoCard(
              text:
                  'Each chat runs in its own Linux container for code '
                  'execution (Python, shell, ffmpeg, git, …). Containers '
                  'idle-out after 30 minutes. Files are saved as a '
                  'snapshot and restored on the next chat visit, '
                  'sliding-expiring after 3 days of inactivity. Up to 2 '
                  'sandboxes per account can be running concurrently — '
                  'destroy one here to free a slot.',
            ),
            // Fix C: GitHub connection lives here now (was a top-level
            // Settings entry). The token is only ever used by `git` / `gh`
            // inside the sandbox, so the entry point belongs next to the
            // sandbox itself.
            const ExpressiveSectionHeader('Code hosting'),
            ExpressiveGroup(
              children: [
                ExpressiveRow(
                  icon: Icons.code,
                  title: 'GitHub',
                  subtitle:
                      'Let the AI clone your repos, push, and open PRs '
                      'in the sandbox',
                  trailing: githubConnected
                      ? ExpressiveBadge(
                          login == null || login.isEmpty ? 'Connected' : '@$login',
                          tone: m3.successContainer,
                          icon: Icons.check,
                        )
                      : const ExpressiveBadge('Connect'),
                  onTap: _openGitHub,
                ),
              ],
            ),
            const ExpressiveSectionHeader('Running'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              ExpressiveInfoCard(
                text: _error!,
                icon: Icons.error_outline,
                tone: scheme.errorContainer,
              )
            else if (_sandboxes.isEmpty)
              const ExpressiveInfoCard(
                text: 'No active sandboxes. One starts the next time a chat '
                    'runs code.',
                icon: Icons.dns_outlined,
              )
            else
              ExpressiveGroup(
                children: [
                  for (final s in _sandboxes)
                    _SandboxRow(
                      info: s,
                      isDestroying: _destroying.contains(s.sessionId),
                      onDestroy: () => _destroy(s),
                      shortId: _shortId(s.sessionId),
                      formatTime: _formatTime,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _SandboxRow extends StatelessWidget {
  const _SandboxRow({
    required this.info,
    required this.isDestroying,
    required this.onDestroy,
    required this.shortId,
    required this.formatTime,
  });

  final SandboxInfo info;
  final bool isDestroying;
  final VoidCallback onDestroy;
  final String shortId;
  final String Function(DateTime) formatTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m3 = theme.m3;
    final running = info.status.toLowerCase() == 'running';

    return ExpressiveRow(
      icon: running ? Icons.dns : Icons.dns_outlined,
      tone: running ? m3.successContainer : m3.warningContainer,
      title: shortId,
      subtitle: '${info.status} · created ${formatTime(info.createdAt)}'
          ' · active ${formatTime(info.lastActivity)}',
      trailing: isDestroying
          ? const SizedBox(
              width: 32,
              height: 32,
              child: Padding(
                padding: EdgeInsets.all(6),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : IconButton(
              tooltip: 'Destroy sandbox',
              icon: Icon(Icons.delete_outline, color: scheme.error),
              onPressed: onDestroy,
            ),
    );
  }
}
