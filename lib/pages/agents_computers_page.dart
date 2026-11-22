/// Settings > Computers (CHAT-177, docs/agents/MULTI_HOST.md "UI"): every
/// computer this account has paired, with its name, its kind, whether it is
/// online right now, and Rename and Remove.
///
/// The page reads the pairing store and the link registry; it owns no socket.
/// A rename is stored in the encrypted trust record, so every device of the
/// account shows the same name. Remove unlinks the computer on every device
/// (its mirrored row is deleted) and drops its link here. Before that the
/// other computers are told to forget it (CHAT-177 phase 2,
/// [AgentsHostPeering.unlink]).
///
/// With two or more computers each one also says how many others it is
/// linked to (what its `host_peer_list` said last; a hint, not presence).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/agents/agents_host_peering.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agent_name_dialog.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/floating_page_scaffold.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

class AgentsComputersPage extends StatefulWidget {
  const AgentsComputersPage({
    super.key,
    this.store,
    this.links,
    this.onAddComputer,
    this.peering,
  });

  /// Introduces and unlinks computers. Null reads
  /// [AgentsHostPeering.current] (none: Remove only removes the pairing).
  final AgentsHostPeering? peering;

  /// Null builds the default store (the OS keychain).
  final AgentsPairingStore? store;

  /// Null reads [AgentsRelayLinks.instance].
  final AgentsRelayLinks? links;

  /// Opens the install page for one more computer. Null hides the row.
  final VoidCallback? onAddComputer;

  static const ValueKey<String> addKey = ValueKey<String>(
    'settings_computers_add',
  );

  static ValueKey<String> rowKey(String hostId) =>
      ValueKey<String>('settings_computer_$hostId');
  static ValueKey<String> renameKey(String hostId) =>
      ValueKey<String>('settings_computer_rename_$hostId');
  static ValueKey<String> removeKey(String hostId) =>
      ValueKey<String>('settings_computer_remove_$hostId');

  @override
  State<AgentsComputersPage> createState() => _AgentsComputersPageState();
}

class _AgentsComputersPageState extends State<AgentsComputersPage> {
  late final AgentsPairingStore _store = widget.store ?? AgentsPairingStore();
  AgentsRelayLinks get _links => widget.links ?? AgentsRelayLinks.instance;
  late final AgentsHostPeering? _peering =
      widget.peering ?? AgentsHostPeering.current;

  List<AgentsStoredPairing> _hosts = const <AgentsStoredPairing>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_read);
    _links.addListener(_onLinks);
    _links.primary.controller.addListener(_onLinks);
    _peering?.addListener(_onLinks);
    unawaited(_read());
  }

  @override
  void dispose() {
    _store.changes.removeListener(_read);
    _links.removeListener(_onLinks);
    _links.primary.controller.removeListener(_onLinks);
    _peering?.removeListener(_onLinks);
    super.dispose();
  }

  void _onLinks() {
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    List<AgentsStoredPairing> hosts;
    try {
      hosts = await _store.listPairings();
    } catch (_) {
      hosts = const <AgentsStoredPairing>[];
    }
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _loaded = true;
    });
  }

  Future<void> _rename(AgentsStoredPairing host) async {
    final String? name = await showAgentNameDialog(
      context,
      title: 'Rename computer',
      submitLabel: 'Save',
      initialName: host.displayName ?? host.label,
      hintText: 'Computer name',
    );
    if (!mounted || name == null) return;
    await _store.renamePairing(host.hostId, name);
  }

  Future<void> _remove(AgentsStoredPairing host) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Remove ${host.label}?'),
        content: const Text(
          'This unlinks the computer from your account on every device. '
          'Its agents stay on the computer. To use it again you have to '
          'add it once more.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('settings_computer_remove_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final AgentsHostPeering? peering = _peering;
    if (peering != null) {
      // The other computers forget it first, then the pairing goes.
      await peering.unlink(host.hostId);
    } else {
      await _store.removePairing(host.hostId);
    }
    _links.drop(host.hostId);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FloatingPageScaffold(
      appBar: const FloatingAppBar(title: Text('Computers')),
      body: SettingsListView(
        key: const ValueKey<String>('settings_computers'),
        children: <Widget>[
          if (_loaded && _hosts.isEmpty)
            ExpressiveGroup(
              children: <Widget>[
                const ExpressiveRow(
                  icon: Icons.computer_outlined,
                  title: 'No computer yet',
                  subtitle: 'Add one to run agents on it.',
                ),
              ],
            ),
          for (final AgentsStoredPairing host in _hosts) ...<Widget>[
            ExpressiveSectionHeader(host.label),
            ExpressiveGroup(
              children: <Widget>[
                // The header names the computer; the row says what it is
                // and whether it is up.
                ExpressiveRow(
                  key: AgentsComputersPage.rowKey(host.hostId),
                  leading: _KindTile(host: host),
                  title: host.effectiveKind == AgentsHostKind.cloud
                      ? 'Cloud computer'
                      : 'Your computer',
                  subtitle: _statusLine(host),
                  trailing: _OnlineDot(online: _isOnline(host)),
                ),
                ExpressiveRow(
                  key: AgentsComputersPage.renameKey(host.hostId),
                  icon: Icons.edit_outlined,
                  title: 'Rename',
                  onTap: () => unawaited(_rename(host)),
                ),
                ExpressiveRow(
                  key: AgentsComputersPage.removeKey(host.hostId),
                  icon: Icons.delete_outline,
                  title: 'Remove',
                  tone: scheme.errorContainer,
                  onTap: () => unawaited(_remove(host)),
                ),
              ],
            ),
          ],
          if (widget.onAddComputer case final VoidCallback add) ...<Widget>[
            const SizedBox(height: 8),
            ExpressiveGroup(
              children: <Widget>[
                ExpressiveRow(
                  key: AgentsComputersPage.addKey,
                  icon: Icons.add,
                  title: 'Add a computer',
                  onTap: add,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// "Online" / "Offline", and with two or more computers how many others
  /// this one is linked to, when it said.
  String _statusLine(AgentsStoredPairing host) {
    final String online = _isOnline(host) ? 'Online' : 'Offline';
    if (_hosts.length < 2) return online;
    final int? linked = _peering?.linkedCount(host.hostId);
    if (linked == null) return online;
    final int others = _hosts.length - 1;
    final String peers = linked == 0
        ? 'not linked yet'
        : linked >= others
        ? (others == 1 ? 'linked' : 'linked to all')
        : 'linked to $linked of $others';
    return '$online · $peers';
  }

  bool _isOnline(AgentsStoredPairing host) {
    final AgentsRelayLinks links = _links;
    if (host.hostId == links.primaryHostId) return links.primary.isUp;
    return links.secondaryFor(host.hostId)?.isUp ?? false;
  }
}

/// The kind of computer as the row's icon tile.
class _KindTile extends StatelessWidget {
  const _KindTile({required this.host});

  final AgentsStoredPairing host;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: HugeIcon(
        host.effectiveKind == AgentsHostKind.cloud
            ? HugeIcons.cloud
            : HugeIcons.computer,
        size: 20,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}

/// A flat dot: green while the computer's link is up, the quiet outline
/// colour while it is not. No halo, no glow.
class _OnlineDot extends StatelessWidget {
  const _OnlineDot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      label: online ? 'Online' : 'Offline',
      child: Container(
        key: ValueKey<String>(online ? 'computer-online' : 'computer-offline'),
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: online ? theme.m3.success : theme.m3.outline,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
