/// The home of the phone app: three places, one floating bar.
///
/// Chats is the roster. Media is every picture and file the coworkers have sent,
/// across all of them. Settings is the settings page itself, not a link to it:
/// a tab that pushes a route and comes back empty is a worse tab than no tab.
/// A coworker's workspace files open from inside its chat.
///
/// The three tabs are peers, so moving between them is Material's fade-through:
/// the tab you leave fades (and eases down a hair), the tab you arrive at fades
/// up from slightly small. Every tab stays mounted the whole time — the roster
/// keeps its search, its filter and its scroll — so the swap is a paint, never
/// a rebuild.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_media_page.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_nav_bar.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/top_veil.dart';

class MobileHome extends StatefulWidget {
  const MobileHome({
    super.key,
    required this.roster,
    required this.chats,
    required this.settings,
    this.readMarks,
  });

  /// The roster, for the media tab's thread keys and the unread badge.
  final AgentRosterSource roster;

  /// The Chats tab: the roster as the shell already builds it, wired to open a
  /// conversation.
  final Widget chats;

  /// The Settings tab, built by the shell because it owns the config.
  final Widget settings;

  final AgentReadMarks? readMarks;

  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  int _index = 0;

  AgentReadMarks get _marks => widget.readMarks ?? AgentReadMarks.instance;

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
                child: FadeThroughTabs(
                  index: _index,
                  children: <Widget>[
                    widget.chats,
                    // Pictures and files, out of every conversation, without
                    // opening one. Agents has no artifacts of its own: a
                    // coworker writes a real file and sends it.
                    MobileMediaPage(
                      threadKeys: <String>[
                        for (final AgentsAgent agent
                            in widget.roster.visibleAgents)
                          for (final AgentsThreadInfo thread in agent.threads)
                            thread.key,
                      ],
                    ),
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
///
/// A child that is not in front can take no focus and runs no tickers: a
/// hidden composer must not open the keyboard, and a hidden list has nothing
/// to animate. The messenger shell uses the same widget for the Chat | Agents
/// switch, whose two halves are peers in exactly this sense.
class FadeThroughTabs extends StatefulWidget {
  const FadeThroughTabs({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  /// Inside the 200–350 ms band the rest of the app's motion lives in.
  static const Duration duration = Duration(milliseconds: 300);

  @override
  State<FadeThroughTabs> createState() => _FadeThroughTabsState();
}

class _FadeThroughTabsState extends State<FadeThroughTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: FadeThroughTabs.duration,
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
  void didUpdateWidget(covariant FadeThroughTabs oldWidget) {
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
            // is always the same widgets, and only their values move.
            for (int i = 0; i < widget.children.length; i++)
              Offstage(
                // Laid out either way (see [RenderOffstage]), so a tab that is
                // waiting keeps its scroll position and its controllers.
                offstage: i != _incoming && i != _outgoing,
                child: TickerMode(
                  enabled: i == _incoming || i == _outgoing,
                  child: ExcludeFocus(
                    excluding: i != _incoming,
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
                ),
              ),
          ],
        );
      },
    );
  }
}
