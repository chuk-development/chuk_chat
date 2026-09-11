/// The home of the phone app: four places, one floating bar.
///
/// Chats is the roster. Media is every picture and file the coworkers have sent,
/// across all of them. Files asks one coworker what is in its workspace, so it
/// starts by naming the coworker. Settings is the settings page itself, not a
/// link to it: a tab that pushes a route and comes back empty is a worse tab
/// than no tab.
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

  Widget _picker(String purpose) {
    return MobileAgentList(
      source: widget.roster,
      readMarks: widget.readMarks,
      profiles: widget.profiles,
      accountLabel: null,
      title: purpose,
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
                child: IndexedStack(
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
                    _picker('Files'),
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
