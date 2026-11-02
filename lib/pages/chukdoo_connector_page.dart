// lib/pages/chukdoo_connector_page.dart
//
// The built-in Chukdoo connector: pair with the user's Chukdoo account by
// code, see that it is connected, disconnect it. Same layout as
// McpConnectorDetailPage (icon, name, description, one 52 px button, a
// spinner with Cancel while something runs). The logic lives in
// lib/services/chukdoo/chukdoo_connector.dart.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/mcp_connectors_page.dart'
    show McpConnectorIcon;
import 'package:chuk_chat/services/chukdoo/chukdoo_connector.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_tool_bridge.dart'
    show isOfferedChukdooTool;
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

/// The connector id; also names the bundled logo.
const String kChukdooConnectorId = 'chukdoo';

class ChukdooConnectorPage extends StatefulWidget {
  const ChukdooConnectorPage({super.key});

  @override
  State<ChukdooConnectorPage> createState() => _ChukdooConnectorPageState();
}

class _ChukdooConnectorPageState extends State<ChukdooConnectorPage> {
  ChukdooConnector get _connector => ChukdooConnector.instance;

  /// True while the pairing request is being opened or the disconnect runs.
  bool _busy = false;

  /// The running pairing, while its code is on screen.
  ChukdooPairing? _pairing;

  @override
  void initState() {
    super.initState();
    // A connect or disconnect on another device shows up here at once.
    unawaited(_connector.pull(force: true));
  }

  @override
  void dispose() {
    // Leaving the page ends the pairing: nobody is left to show the code.
    _pairing?.cancel();
    super.dispose();
  }

  AppLocalizations get _strings =>
      AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

  Future<void> _connect() async {
    setState(() => _busy = true);
    final ChukdooPairing pairing;
    try {
      pairing = await _connector.startPairing();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppNotifications.show(
        context,
        e is ChukdooPairingFailed ? e.message : _strings.chukdooPairStartFailed,
      );
      return;
    }
    if (!mounted) {
      pairing.cancel();
      pairing.done.ignore();
      return;
    }
    setState(() {
      _busy = false;
      _pairing = pairing;
    });
    try {
      await pairing.done;
      if (!mounted) return;
      AppNotifications.show(context, _strings.chukdooConnectedNotice);
    } on ChukdooPairingCancelled {
      // The user pressed Cancel or left the page.
    } on ChukdooPairingFailed catch (e) {
      if (mounted) AppNotifications.show(context, e.message);
    } finally {
      if (mounted && identical(_pairing, pairing)) {
        setState(() => _pairing = null);
      }
    }
  }

  void _cancelPairing() {
    _pairing?.cancel();
    setState(() => _pairing = null);
  }

  Future<void> _disconnect() async {
    final strings = _strings;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.chukdooDisconnectConfirmTitle),
        content: Text(strings.chukdooDisconnectConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.chukdooCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.chukdooDisconnect),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _connector.disconnect();
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        AppNotifications.show(context, strings.chukdooDisconnectFailed);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    AppNotifications.show(context, strings.chukdooDisconnectedNotice);
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    AppNotifications.show(context, _strings.chukdooCodeCopied);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = _strings;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.resolvedIconColor.withValues(alpha: 0.7),
    );

    return ValueListenableBuilder<ChukdooConnectorState>(
      valueListenable: _connector.state,
      builder: (context, state, _) {
        final pairing = _pairing;
        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: const FloatingAppBar(
            title: Text(ChukdooConnector.displayName),
          ),
          body: SettingsListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            children: [
              Center(
                child: McpConnectorIcon(
                  assetPath: bundledIconAsset(kChukdooConnectorId),
                  name: ChukdooConnector.displayName,
                  size: 72,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  ChukdooConnector.displayName,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                strings.chukdooConnectorDescription,
                textAlign: TextAlign.center,
                style: muted,
              ),
              const SizedBox(height: 24),
              if (state.connected)
                ..._connectedBlock(theme, strings, state)
              else if (pairing != null)
                ..._pairingBlock(theme, strings, pairing)
              else
                ..._disconnectedBlock(theme, strings, state),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _disconnectedBlock(
    ThemeData theme,
    AppLocalizations strings,
    ChukdooConnectorState state,
  ) {
    return [
      if (state.revoked) ...[
        _notice(theme, strings.chukdooRevoked, error: true),
        const SizedBox(height: 16),
      ],
      SizedBox(
        height: 52,
        child: _busy
            ? const _Spinner()
            : FilledButton(
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                onPressed: _connect,
                child: Text(strings.chukdooConnect),
              ),
      ),
    ];
  }

  List<Widget> _pairingBlock(
    ThemeData theme,
    AppLocalizations strings,
    ChukdooPairing pairing,
  ) {
    final local = TimeOfDay.fromDateTime(pairing.expiresAt.toLocal());
    final expires = MaterialLocalizations.of(context).formatTimeOfDay(local);
    return [
      Center(
        child: Text(
          strings.chukdooPairTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SelectableText(
                  pairing.displayCode,
                  key: const ValueKey<String>('chukdoo-pairing-code'),
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 4,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: strings.chukdooCopyCode,
              onPressed: () => _copyCode(pairing.displayCode),
              icon: const AppIcon(Icons.copy_rounded),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _Breadcrumb(text: strings.chukdooPairHint, style: theme.textTheme.bodyMedium),
      const SizedBox(height: 8),
      Text(
        strings.chukdooPairExpires(expires),
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.resolvedIconColor.withValues(alpha: 0.6),
        ),
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 52,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Flexible(
              child: Text(
                strings.chukdooPairWaiting,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _cancelPairing,
              child: Text(strings.chukdooCancel),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _connectedBlock(
    ThemeData theme,
    AppLocalizations strings,
    ChukdooConnectorState state,
  ) {
    final creds = state.credentials!;
    final paired = MaterialLocalizations.of(
      context,
    ).formatMediumDate(creds.pairedAt.toLocal());
    final specs = _connector.specs
        .where((s) => isOfferedChukdooTool(s.name))
        .toList();
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppIcon(
            Icons.check_circle_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            '${strings.chukdooConnected} · ${strings.chukdooPairedSince(paired)}',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 52,
        child: _busy
            ? const _Spinner()
            : FilledButton(
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                onPressed: _disconnect,
                child: Text(strings.chukdooDisconnect),
              ),
      ),
      const SizedBox(height: 12),
      Text(
        strings.chukdooSyncedNote,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.resolvedIconColor.withValues(alpha: 0.7),
        ),
      ),
      if (specs.isNotEmpty) ...[
        const SizedBox(height: 28),
        Text(
          strings.chukdooTools,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.resolvedIconColor.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final spec in specs)
              Chip(
                label: Text(spec.name),
                backgroundColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                side: BorderSide.none,
              ),
          ],
        ),
      ],
    ];
  }

  Widget _notice(ThemeData theme, String text, {bool error = false}) {
    final color = error ? theme.colorScheme.error : theme.colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 20,
          child: Center(
            child: AppIcon(Icons.link_off_rounded, size: 16, color: color),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              height: 20 / 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 24,
      height: 24,
      child: CircularProgressIndicator(strokeWidth: 2.5),
    ),
  );
}

/// "In Chukdoo: Settings → AI access → Pair a device", with a real chevron
/// icon between the steps instead of the arrow glyph, centred on the text.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final parts = text
        .split('→')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final color = style?.color ?? Theme.of(context).resolvedIconColor;
    return Semantics(
      label: parts.join(', '),
      excludeSemantics: true,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 4,
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: AppIcon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: color.withValues(alpha: 0.6),
                ),
              ),
            Text(
              parts[i],
              style: i == 0
                  ? style
                  : style?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}
