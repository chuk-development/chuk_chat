// lib/widgets/agents_host_tag.dart
//
// The small label that says which computer an agent lives on (CHAT-177,
// docs/agents/MULTI_HOST.md "UI"): "PC", "Cloud" or the name the user gave
// the computer. It shows only while more than one computer is paired; with
// one there is nothing to tell apart, and the rows look as they always did.
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';

/// The labels of the paired computers, kept by the Agents shell. Rows read
/// it through [AgentsHostTag], so no row needs a new parameter.
class AgentsHostLabels extends ChangeNotifier {
  AgentsHostLabels._();

  static final AgentsHostLabels instance = AgentsHostLabels._();

  Map<String, String> _labels = const <String, String>{};
  String? _primary;

  /// How many computers are paired.
  int get count => _labels.length;

  /// Takes the paired computers and the computer on screen (the one an
  /// agent from before CHAT-177, with no computer of its own, lives on).
  void update(List<AgentsStoredPairing> hosts, String? primaryHostId) {
    final Map<String, String> next = <String, String>{
      for (final AgentsStoredPairing h in hosts) h.hostId: h.label,
    };
    if (_primary == primaryHostId && mapEquals(next, _labels)) return;
    _labels = next;
    _primary = primaryHostId;
    notifyListeners();
  }

  /// The label for [hostId], or null while fewer than two computers are
  /// paired. A null [hostId] is the computer on screen.
  String? labelFor(String? hostId) {
    if (_labels.length < 2) return null;
    return _labels[hostId ?? _primary];
  }

  @visibleForTesting
  void reset() {
    _labels = const <String, String>{};
    _primary = null;
    notifyListeners();
  }
}

/// A quiet tonal pill with the computer's label. Draws nothing while one
/// computer is paired. Flat: no border, no shadow, no glow.
class AgentsHostTag extends StatelessWidget {
  const AgentsHostTag({
    super.key,
    required this.hostId,
    this.labels,
    this.leadingGap = 0,
  });

  /// Space before the tag, drawn only when the tag is: a row with one
  /// computer keeps its old spacing.
  final double leadingGap;

  /// The agent's computer ([AgentsAgent.hostId]); null is the computer on
  /// screen.
  final String? hostId;

  /// The label source. Null reads [AgentsHostLabels.instance].
  final AgentsHostLabels? labels;

  @override
  Widget build(BuildContext context) {
    final AgentsHostLabels source = labels ?? AgentsHostLabels.instance;
    return ListenableBuilder(
      listenable: source,
      builder: (BuildContext context, Widget? _) {
        final String? label = source.labelFor(hostId);
        if (label == null) return const SizedBox.shrink();
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;
        final Widget tag = Container(
          key: const ValueKey<String>('agents-host-tag'),
          // A name the user typed can be long; the tag stays a tag.
          constraints: const BoxConstraints(maxWidth: 104),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        if (leadingGap <= 0) return tag;
        return Padding(
          padding: EdgeInsetsDirectional.only(start: leadingGap),
          child: tag,
        );
      },
    );
  }
}
