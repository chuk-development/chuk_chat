/// The home of the phone app: four places, one floating bar.
///
/// Chats is the roster. Media is every picture and file the coworkers have sent,
/// across all of them. Files asks one coworker what is in its workspace, so it
/// starts by naming the coworker. Settings is the settings page itself, not a
/// link to it: a tab that pushes a route and comes back empty is a worse tab
/// than no tab.
///
/// The four tabs are peers, so moving between them is Material's fade-through:
/// the tab you leave fades (and eases down a hair), the tab you arrive at fades
/// up from slightly small. Every tab stays mounted the whole time — the roster
/// keeps its search, its filter and its scroll — so the swap is a paint, never
/// a rebuild.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/platform_specific/mobile/mobile_agent_list.dart';
import 'package:cowork/platform_specific/mobile/mobile_media_page.dart';
import 'package:cowork/platform_specific/mobile/mobile_nav_bar.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/services/cowork/agent_read_marks.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/top_veil.dart';
import 'package:cowork/widgets/chat_documents_panel.dart';

class MobileHome extends StatefulWidget {
  const MobileHome({
    super.key,
    required this.roster,
    required this.chats,
    required this.settings,
    required this.controller,
    this.readMarks,
    this.profiles,
  });

  /// The roster, for the coworker pickers of the other tabs.
  final AgentRosterSource roster;

  /// The Chats tab: the roster as the shell already builds it, wired to open a
  /// conversation.
  final Widget chats;

  /// The Settings tab, built by the shell because it owns the config.
  final Widget settings;

  /// The live relay controller, handed to the documents panel.
  final CoworkRelayController? controller;

  final AgentReadMarks? readMarks;
  final AgentProfileStore? profiles;

  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  int _index = 0;

  AgentReadMarks get _marks => widget.readMarks ?? AgentReadMarks.instance;

  void _openPanel(CoworkAgent agent, String threadKey) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatDocumentsPanel(
          sessionKey: threadKey,
          coworkerName: agent.name,
          controller: widget.controller,
          fullPage: true,
        ),
      ),
    );
  }

  /// The same roster, used to pick whose files to open. It carries no
  /// headline of its own: the navigation bar under it already names the tab,
  /// and the roster header is one row now.
  Widget _picker() {
    return MobileAgentList(
      source: widget.roster,
      readMarks: widget.readMarks,
      profiles: widget.profiles,
      accountLabel: null,
      onSelect: (String agentId, String threadKey) {
        final CoworkAgent? agent = widget.roster.visibleAgents
            .where((CoworkAgent candidate) => candidate.id == agentId)
            .firstOrNull;
        if (agent == null) return;
        _openPanel(agent, threadKey);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[widget.roster, _marks]),
      builder: (BuildContext context, Widget? _) {
        final int unread = _marks.unreadCount(widget.roster.visibleAgents);
        return Stack(
          children: <Widget>[
            Positioned.fill(
              // The bar floats over the content, and the content scrolls out
              // under it. Every tab already keeps the window's bottom inset
              // free, so the bar's height is added to that inset instead of
              // cutting the tab short above it — one change, and a list fades
              // out behind the bar the way the chat fades out behind its
              // header.
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: MediaQuery.paddingOf(context).copyWith(
                    bottom:
                        MediaQuery.paddingOf(context).bottom +
                        MobileNavBar.height,
                  ),
                ),
                child: _FadeThroughTabs(
                  index: _index,
                  children: <Widget>[
                    widget.chats,
                    // Pictures and files, out of every conversation, without
                    // opening one. CoWork has no artifacts of its own: a
                    // coworker writes a real file and sends it.
                    MobileMediaPage(
                      threadKeys: <String>[
                        for (final CoworkAgent agent
                            in widget.roster.visibleAgents)
                          for (final CoworkThreadInfo thread in agent.threads)
                            thread.key,
                      ],
                    ),
                    _picker(),
                    widget.settings,
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BottomVeil(
                child: MobileNavBar(
                  index: _index,
                  onSelected: (int i) => setState(() => _index = i),
                  destinations: <MobileNavDestination>[
                    MobileNavDestination(
                      icon: HugeIcons.message01,
                      label: 'Chats',
                      badge: unread,
                    ),
                    const MobileNavDestination(
                      icon: HugeIcons.album02,
                      label: 'Media',
                    ),
                    const MobileNavDestination(
                      icon: HugeIcons.folder03,
                      label: 'Files',
                    ),
                    const MobileNavDestination(
                      icon: HugeIcons.settings01,
                      label: 'Settings',
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// An [IndexedStack] that fades through instead of cutting.
///
/// All children stay in the tree — the same guarantee [IndexedStack] gives, so
/// the roster is not rebuilt on every tab press — and the swap is painted: the
/// tab being left fades out over the first third, the tab being entered fades
/// in over the rest while it grows the last few percent back to size. Material
/// calls this fade-through, and it is the transition for peers: nothing slides,
/// because neither tab is "further in" than the other.
class _FadeThroughTabs extends StatefulWidget {
  const _FadeThroughTabs({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  /// Inside the 200–350 ms band the rest of the app's motion lives in.
  static const Duration duration = Duration(milliseconds: 300);

  @override
  State<_FadeThroughTabs> createState() => _FadeThroughTabsState();
}

class _FadeThroughTabsState extends State<_FadeThroughTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _FadeThroughTabs.duration,
    value: 1,
  )..addStatusListener(_onStatus);

  /// The tab that is arriving (at rest: the tab that is simply there).
  late int _incoming = widget.index;

  /// The tab that is leaving, while it is still worth painting.
  int? _outgoing;

  bool _reducedMotion = false;

  late final Animation<double> _out = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.35, curve: Curves.easeOut),
  );
  late final Animation<double> _in = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.35, 1, curve: kExpressiveDecelerate),
  );

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (_outgoing == null || !mounted) return;
    setState(() => _outgoing = null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion && (_c.isAnimating || _outgoing != null)) {
      _c.stop();
      _c.value = 1;
      _outgoing = null;
    }
  }

  @override
  void didUpdateWidget(covariant _FadeThroughTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _incoming) return;
    final int leaving = _incoming;
    _incoming = widget.index;
    // Reduced motion: the tab is simply the other one now.
    if (_reducedMotion) {
      _c.value = 1;
      _outgoing = null;
      return;
    }
    _outgoing = leaving;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? _) {
        final double leaving = _out.value;
        final double arriving = _in.value;
        return Stack(
          children: <Widget>[
            // Every tab keeps its slot and its wrapper chain, in the same
            // order, for the life of the widget. That is what keeps the state:
            // change the shape of a slot (Offstage here, Opacity there) and
            // Flutter throws the subtree away and builds a new one, which is
            // exactly the rebuilt roster this is meant to avoid. So the chain
            // is always the same three widgets, and only their values move.
            for (int i = 0; i < widget.children.length; i++)
              Offstage(
                // Laid out either way (see [RenderOffstage]), so a tab that is
                // waiting keeps its scroll position and its controllers.
                offstage: i != _incoming && i != _outgoing,
                child: IgnorePointer(
                  ignoring: i != _incoming,
                  child: Opacity(
                    opacity: i == _incoming
                        ? arriving
                        : (i == _outgoing ? 1 - leaving : 0),
                    child: Transform.scale(
                      scale: i == _incoming
                          ? 0.94 + 0.06 * arriving
                          : (i == _outgoing ? 1 - 0.03 * leaving : 1),
                      child: widget.children[i],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
