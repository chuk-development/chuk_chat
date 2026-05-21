import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/sandbox_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<String?> _accessToken() async {
    return SupabaseService.auth.currentSession?.accessToken;
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

  String _shortId(String id) =>
      id.length <= 12 ? id : '${id.substring(0, 6)}…${id.substring(id.length - 6)}';

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
    final scheme = Theme.of(context).colorScheme;
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
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'About sandboxes',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Each chat runs in its own Linux container for code '
                      'execution (Python, shell, ffmpeg, git, …). Containers '
                      'idle-out after 30 minutes. Files are saved as a '
                      'snapshot and restored on the next chat visit, '
                      'sliding-expiring after 3 days of inactivity. Up to 2 '
                      'sandboxes per account can be running concurrently — '
                      'destroy one here to free a slot.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              )
            else if (_sandboxes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    'No active sandboxes.',
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              )
            else
              ..._sandboxes.map((s) => _SandboxRow(
                    info: s,
                    isDestroying: _destroying.contains(s.sessionId),
                    onDestroy: () => _destroy(s),
                    shortId: _shortId(s.sessionId),
                    formatTime: _formatTime,
                  )),
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
    final scheme = Theme.of(context).colorScheme;
    final running = info.status.toLowerCase() == 'running';
    final statusColor = running ? Colors.green : Colors.orange;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shortId,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${info.status} · created ${formatTime(info.createdAt)} · '
                    'active ${formatTime(info.lastActivity)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (isDestroying)
              const SizedBox(
                width: 32,
                height: 32,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Destroy sandbox',
                icon: Icon(Icons.delete_outline, color: scheme.error),
                onPressed: onDestroy,
              ),
          ],
        ),
      ),
    );
  }
}

