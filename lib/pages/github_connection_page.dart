// lib/pages/github_connection_page.dart
//
// Per-user GitHub OAuth Device Flow — lets the AI use `git` and `gh`
// inside the sandbox under the user's identity. Token never lives
// on this device; api-server stores it encrypted and injects it into
// the sandbox on demand.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/services/github_connection_service.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class GitHubConnectionPage extends StatefulWidget {
  const GitHubConnectionPage({super.key});

  @override
  State<GitHubConnectionPage> createState() => _GitHubConnectionPageState();
}

class _GitHubConnectionPageState extends State<GitHubConnectionPage> {
  bool _loading = true;
  String? _error;
  GitHubConnectionStatus _status = GitHubConnectionStatus.disconnected;

  // Active device-flow state.
  GitHubConnectInit? _flow;
  GitHubConnectPollState? _pollState;
  Future<void>? _pollFuture;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    // Polling future is fire-and-forget — we don't cancel it; the
    // pollUntilTerminal helper times out on its own.
    super.dispose();
  }

  Future<String?> _accessToken() async {
    final s = SupabaseService.auth.currentSession;
    return s?.accessToken;
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await _accessToken();
      if (token == null || token.isEmpty) {
        throw GitHubConnectionException(401, 'Not signed in.');
      }
      final s = await GitHubConnectionService.status(accessToken: token);
      if (!mounted) return;
      setState(() {
        _status = s;
        _loading = false;
      });
    } on GitHubConnectionException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load status: $e';
        _loading = false;
      });
    }
  }

  Future<void> _startConnect() async {
    setState(() {
      _error = null;
      _pollState = null;
      _flow = null;
    });
    try {
      final token = await _accessToken();
      if (token == null) {
        throw GitHubConnectionException(401, 'Not signed in.');
      }
      final init =
          await GitHubConnectionService.startConnect(accessToken: token);
      if (!mounted) return;
      setState(() {
        _flow = init;
        _pollState = GitHubConnectPollState.pending;
      });

      // Open GitHub's device page in the system browser so the user
      // just has to paste the code.
      final uri = Uri.tryParse(init.verificationUri);
      if (uri != null) {
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      }

      // Poll in the background.
      _pollFuture = _runPoll(token, init);
      unawaited(_pollFuture);
    } on GitHubConnectionException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not start connection: $e');
    }
  }

  Future<void> _runPoll(String token, GitHubConnectInit init) async {
    try {
      final result = await GitHubConnectionService.pollUntilTerminal(
        accessToken: token,
        state: init.state,
        intervalSeconds: init.interval,
        expiresIn: init.expiresIn,
        onTick: (s) {
          if (!mounted) return;
          setState(() => _pollState = s);
        },
      );
      if (!mounted) return;
      setState(() => _pollState = result.state);
      if (result.state == GitHubConnectPollState.success) {
        await _refreshStatus();
        if (!mounted) return;
        setState(() => _flow = null);
      }
    } on GitHubConnectionException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Poll failed: $e');
    }
  }

  Future<void> _disconnect() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect GitHub?'),
        content: const Text(
          'The AI will no longer be able to clone your private repos, push commits, '
          'or open pull requests on your behalf. The token will be revoked on GitHub.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await _accessToken();
      if (token == null) {
        throw GitHubConnectionException(401, 'Not signed in.');
      }
      await GitHubConnectionService.disconnect(accessToken: token);
      if (!mounted) return;
      setState(() {
        _status = GitHubConnectionStatus.disconnected;
        _flow = null;
        _pollState = null;
      });
    } on GitHubConnectionException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('GitHub')),
      body: RefreshIndicator(
        onRefresh: _refreshStatus,
        child: SettingsListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _intro(scheme),
            const SizedBox(height: 20),
            if (_loading) ...[
              const Center(child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              )),
            ] else if (_status.connected) ...[
              _connectedCard(scheme),
            ] else if (_flow != null) ...[
              _deviceCodeCard(scheme, _flow!),
            ] else ...[
              _disconnectedCard(scheme),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              _errorBanner(_error!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _intro(ColorScheme scheme) {
    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.code, color: scheme.primary),
              const SizedBox(width: 8),
              Text('AI can use your GitHub',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Connect your GitHub account so the AI can clone your private '
            'repositories, make commits, and open pull requests inside the '
            'code sandbox. Your token is encrypted on our server and only '
            'used when you ask the AI to do something with GitHub.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Scopes requested: repo, read:user, gist.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _disconnectedCard(ColorScheme scheme) {
    return ExpressiveCard(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Not connected',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              'Click below to start. You will receive an 8-character code '
              'to enter on github.com/login/device — your browser opens '
              'there automatically.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.link),
              label: const Text('Connect GitHub'),
              onPressed: _startConnect,
            ),
          ],
        ),
    );
  }

  Widget _connectedCard(ColorScheme scheme) {
    return ExpressiveCard(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Connected as @${_status.githubLogin ?? "unknown"}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if ((_status.scopes ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Scopes: ${_status.scopes}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if ((_status.connectedAt ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Connected: ${_status.connectedAt}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  onPressed: _refreshStatus,
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                  onPressed: _disconnect,
                ),
              ],
            ),
          ],
        ),
    );
  }

  Widget _deviceCodeCard(ColorScheme scheme, GitHubConnectInit flow) {
    final state = _pollState ?? GitHubConnectPollState.pending;
    Widget header;
    switch (state) {
      case GitHubConnectPollState.pending:
        header = Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Text('Waiting for GitHub …',
                style: Theme.of(context).textTheme.titleSmall),
          ],
        );
        break;
      case GitHubConnectPollState.success:
        header = Row(children: [
          Icon(Icons.check_circle, color: scheme.primary),
          const SizedBox(width: 8),
          Text('Connected!', style: Theme.of(context).textTheme.titleSmall),
        ]);
        break;
      case GitHubConnectPollState.expired:
        header = Text('Code expired — try again',
            style: Theme.of(context).textTheme.titleSmall);
        break;
      case GitHubConnectPollState.denied:
        header = Text('Authorization denied',
            style: Theme.of(context).textTheme.titleSmall);
        break;
    }
    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
            const SizedBox(height: 16),
            Text(
              '1. Open github.com/login/device (already opened in your browser).',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '2. Enter this code:',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    flow.userCode,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontFamily: 'monospace',
                          letterSpacing: 4,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: flow.userCode));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '3. Authorize chuk_chat. This page will refresh automatically.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open GitHub'),
                  onPressed: () {
                    final uri = Uri.tryParse(flow.verificationUri);
                    if (uri != null) {
                      unawaited(launchUrl(uri,
                          mode: LaunchMode.externalApplication));
                    }
                  },
                ),
                const Spacer(),
                if (state == GitHubConnectPollState.expired ||
                    state == GitHubConnectPollState.denied)
                  FilledButton(
                    onPressed: _startConnect,
                    child: const Text('Try again'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _errorBanner(String msg) {
    return ExpressiveInfoCard(
      text: msg,
      icon: Icons.error_outline,
      tone: Theme.of(context).colorScheme.errorContainer,
    );
  }
}
