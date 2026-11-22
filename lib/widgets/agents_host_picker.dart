/// "Which computer?" — the step of the new-agent flow that only exists while
/// more than one computer is paired (CHAT-177, docs/agents/MULTI_HOST.md).
///
/// A centred dialog (docs/DESIGN.md §14.6) with the computers as one
/// `MenuTileGroup` run: the computer used last is the chosen row, so Enter
/// or a tap on "Next" keeps it. Each row says what kind of computer it is
/// and whether it is online right now.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_dialog.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

/// Asks on which computer a new agent runs. Returns its host id, or null on
/// Cancel. With fewer than two [hosts] it does not ask and returns the one
/// host id (or null with none).
Future<String?> showAgentHostPicker(
  BuildContext context, {
  required List<AgentsStoredPairing> hosts,
  String? initialHostId,
  bool Function(String hostId)? isOnline,
}) async {
  if (hosts.isEmpty) return null;
  if (hosts.length == 1) return hosts.single.hostId;
  return showDialog<String>(
    context: context,
    builder: (_) => AgentHostPickerDialog(
      hosts: hosts,
      initialHostId: initialHostId,
      isOnline: isOnline,
    ),
  );
}

class AgentHostPickerDialog extends StatefulWidget {
  const AgentHostPickerDialog({
    super.key,
    required this.hosts,
    this.initialHostId,
    this.isOnline,
  });

  final List<AgentsStoredPairing> hosts;
  final String? initialHostId;
  final bool Function(String hostId)? isOnline;

  @override
  State<AgentHostPickerDialog> createState() => _AgentHostPickerDialogState();
}

class _AgentHostPickerDialogState extends State<AgentHostPickerDialog> {
  late String _chosen = _initial();

  String _initial() {
    final String? wanted = widget.initialHostId;
    for (final AgentsStoredPairing h in widget.hosts) {
      if (h.hostId == wanted) return h.hostId;
    }
    return widget.hosts.first.hostId;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final bool desk = isAgentsDesktop(context);
    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          desk ? kDeskDialogRadius : kRadiusDialog,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: desk
              ? const EdgeInsets.fromLTRB(22, 20, 22, 18)
              : const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Which computer?',
                style: desk
                    ? text.titleLarge?.copyWith(fontWeight: FontWeight.w700)
                    : text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                'The new agent runs and keeps its files there.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: MenuTileGroup.single(
                    color: scheme.surfaceContainerLow,
                    children: <Widget>[
                      for (final AgentsStoredPairing host in widget.hosts)
                        MenuActionRow(
                          key: ValueKey<String>(
                            'agents-host-pick-${host.hostId}',
                          ),
                          label: host.label,
                          subtitle: _subtitle(host),
                          leading: HugeIcon(
                            host.effectiveKind == AgentsHostKind.cloud
                                ? HugeIcons.cloud
                                : HugeIcons.computer,
                            size: 20,
                            color: host.hostId == _chosen
                                ? scheme.onTertiaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                          selected: host.hostId == _chosen,
                          onTap: () => setState(() => _chosen = host.hostId),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  ExpressiveButton(
                    label: 'Cancel',
                    color: scheme.surfaceContainerHighest,
                    onColor: scheme.onSurfaceVariant,
                    dense: desk,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  ExpressiveButton(
                    key: const ValueKey<String>('agents-host-pick-next'),
                    label: 'Next',
                    dense: desk,
                    onTap: () => Navigator.of(context).pop(_chosen),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(AgentsStoredPairing host) {
    final String kind = host.effectiveKind == AgentsHostKind.cloud
        ? 'Cloud computer'
        : 'Your computer';
    final bool Function(String)? online = widget.isOnline;
    if (online == null) return kind;
    return '$kind · ${online(host.hostId) ? 'Online' : 'Offline'}';
  }
}
