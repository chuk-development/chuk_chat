import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/cowork/cowork_executor_bridge.dart';

/// The CoWork surface — shown when the app is in [AppMode.cowork].
///
/// With [kFeatureCoworkDemo] on, this drives the **local demo**: it starts a
/// `127.0.0.1` loopback server and shows the URL to open as the phone page.
/// The page injects tasks into this laptop's real agent loop, which can run
/// laptop-native tools (`run_command`, `read_file`, …) on this machine.
///
/// With the flag off, it stays the M0 "coming soon" placeholder.
class CoWorkSurface extends StatefulWidget {
  const CoWorkSurface({super.key});

  @override
  State<CoWorkSurface> createState() => _CoWorkSurfaceState();
}

class _CoWorkSurfaceState extends State<CoWorkSurface> {
  Uri? _url;
  String? _error;
  Timer? _statusTimer;
  int _connections = 0;

  @override
  void initState() {
    super.initState();
    if (kFeatureCoworkDemo) {
      _startDemo();
    }
  }

  Future<void> _startDemo() async {
    try {
      final uri = await CoworkExecutorBridge.instance.start();
      if (!mounted) return;
      setState(() => _url = uri);
      // Poll connected-tab count so the user sees the phone connect live.
      _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final n = CoworkExecutorBridge.instance.server.connectionCount;
        if (n != _connections) setState(() => _connections = n);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    // Deliberately do NOT stop the bridge: the loopback server keeps running
    // so a connected phone survives switching back to Chat mode and returning.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kFeatureCoworkDemo) {
      return _ComingSoon();
    }
    return _DemoPanel(url: _url, error: _error, connections: _connections);
  }
}

class _DemoPanel extends StatelessWidget {
  const _DemoPanel({
    required this.url,
    required this.error,
    required this.connections,
  });

  final Uri? url;
  final String? error;
  final int connections;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.hub_outlined, size: 34, color: scheme.primary),
              ),
              const SizedBox(height: 20),
              Text(
                'CoWork demo — this laptop is the agent',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Open the address below in a browser (on this machine, or a '
                'phone on the same network if you change 127.0.0.1 to this '
                "laptop's IP). Type a task there. It runs here, on this "
                'machine, through the real agent loop.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              if (error != null)
                _ErrorBox(error: error!)
              else if (url == null)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(),
                )
              else
                _UrlBox(url: url!, connections: connections),
            ],
          ),
        ),
      ),
    );
  }
}

class _UrlBox extends StatelessWidget {
  const _UrlBox({required this.url, required this.connections});

  final Uri url;
  final int connections;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = url.toString();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SelectableText(
                  text,
                  style: TextStyle(
                    fontSize: 16,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connections > 0 ? Colors.green : scheme.outline,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              connections > 0
                  ? '$connections phone page(s) connected'
                  : 'Waiting for a phone page to connect…',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'Could not start the CoWork demo server:\n$error',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
      ),
    );
  }
}

class _ComingSoon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.hub_outlined, size: 34, color: scheme.primary),
              ),
              const SizedBox(height: 20),
              Text(
                l.coworkComingSoon,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l.coworkComingSoonBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
