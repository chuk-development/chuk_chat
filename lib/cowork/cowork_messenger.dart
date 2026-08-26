// CoWork messenger — the Slack-like surface: a roster of AI coworker agents on
// the left, the selected thread on the right. Responsive: two panes on wide
// screens, roster→thread navigation on narrow ones.
//
// Basic UI stage: roster + threads are mock (see cowork_models.dart), the
// composer appends locally and the agent replies with a canned line. The
// Python backend (manager/relay/executor) and the real API wiring land next.

import 'package:flutter/material.dart';

import 'package:chuk_chat/cowork/cowork_avatar.dart';
import 'package:chuk_chat/cowork/cowork_models.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/mobile_chat_widgets.dart';

class CoworkMessenger extends StatefulWidget {
  const CoworkMessenger({super.key});

  @override
  State<CoworkMessenger> createState() => _CoworkMessengerState();
}

class _CoworkMessengerState extends State<CoworkMessenger> {
  late List<CoworkAgent> _roster;
  String? _selectedId;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _roster = mockCoworkRoster();
    _selectedId = _roster.isNotEmpty ? _roster.first.id : null;
  }

  CoworkAgent? get _selected {
    if (_selectedId == null) return null;
    for (final a in _roster) {
      if (a.id == _selectedId) return a;
    }
    return null;
  }

  List<CoworkAgent> get _filtered {
    if (_query.trim().isEmpty) return _roster;
    final q = _query.toLowerCase();
    return _roster
        .where(
          (a) =>
              a.name.toLowerCase().contains(q) ||
              a.preview.toLowerCase().contains(q),
        )
        .toList();
  }

  void _send(String text) {
    final agent = _selected;
    if (agent == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      final updated = agent.copyWith(
        thread: [...agent.thread, CoworkTurn(text: trimmed, isUser: true)],
        preview: trimmed,
        time: 'now',
        unread: 0,
        working: true,
      );
      _replace(updated);
    });

    // Simulated agent acknowledgement — placeholder until the backend streams
    // a real run back into the thread.
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      final live = _selectedForId(agent.id);
      if (live == null) return;
      setState(() {
        final reply =
            'On it. I\'ll pick up "$trimmed" and stream the run back here.';
        _replace(
          live.copyWith(
            thread: [...live.thread, CoworkTurn(text: reply, isUser: false)],
            preview: reply,
            working: false,
          ),
        );
      });
    });
  }

  CoworkAgent? _selectedForId(String id) {
    for (final a in _roster) {
      if (a.id == id) return a;
    }
    return null;
  }

  void _replace(CoworkAgent updated) {
    final i = _roster.indexWhere((a) => a.id == updated.id);
    if (i >= 0) _roster[i] = updated;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        if (wide) {
          return Row(
            children: [
              SizedBox(
                width: 300,
                child: _RosterPane(
                  agents: _filtered,
                  selectedId: _selectedId,
                  query: _query,
                  onQuery: (q) => setState(() => _query = q),
                  onSelect: (id) => setState(() => _selectedId = id),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: _selected == null
                    ? const _EmptyThread()
                    : _ThreadPane(agent: _selected!, onSend: _send),
              ),
            ],
          );
        }

        // Narrow: roster, or the thread with a back button.
        final agent = _selected;
        if (agent == null || _selectedId == null) {
          return _RosterPane(
            agents: _filtered,
            selectedId: null,
            query: _query,
            onQuery: (q) => setState(() => _query = q),
            onSelect: (id) => setState(() => _selectedId = id),
          );
        }
        return _ThreadPane(
          agent: agent,
          onSend: _send,
          onBack: () => setState(() => _selectedId = null),
        );
      },
    );
  }
}

/* ------------------------------- Roster ------------------------------- */

class _RosterPane extends StatelessWidget {
  const _RosterPane({
    required this.agents,
    required this.selectedId,
    required this.query,
    required this.onQuery,
    required this.onSelect,
  });

  final List<CoworkAgent> agents;
  final String? selectedId;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      child: Column(
        children: [
          // Header row: title + new-agent button.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 6),
            child: Row(
              children: [
                Text(
                  'CoWork',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'New coworker',
                  icon: Icon(Icons.add, color: scheme.onSurfaceVariant),
                  onPressed: () {},
                ),
              ],
            ),
          ),
          // Search.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              onChanged: onQuery,
              style: TextStyle(color: scheme.onSurface, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search',
                hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: agents.length,
              itemBuilder: (context, i) {
                final a = agents[i];
                return _RosterRow(
                  agent: a,
                  selected: a.id == selectedId,
                  onTap: () => onSelect(a.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RosterRow extends StatelessWidget {
  const _RosterRow({
    required this.agent,
    required this.selected,
    required this.onTap,
  });

  final CoworkAgent agent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.7)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CoworkAvatar(agent: agent, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              agent.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            agent.time,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              agent.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (agent.unread > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${agent.unread}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onPrimary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ------------------------------- Thread ------------------------------- */

class _ThreadPane extends StatefulWidget {
  const _ThreadPane({required this.agent, required this.onSend, this.onBack});

  final CoworkAgent agent;
  final ValueChanged<String> onSend;
  final VoidCallback? onBack;

  @override
  State<_ThreadPane> createState() => _ThreadPaneState();
}

class _ThreadPaneState extends State<_ThreadPane> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  // Separate node for the KeyboardListener wrapper — sharing the TextField's
  // node makes it a parent of itself and crashes on build.
  final _kbFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ThreadPane old) {
    super.didUpdateWidget(old);
    // New turns arrived — keep the latest in view.
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _submit() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    widget.onSend(text);
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _kbFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agent = widget.agent;
    return Column(
      children: [
        _ThreadHeader(agent: agent, onBack: widget.onBack),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            itemCount: agent.thread.length,
            itemBuilder: (context, i) {
              final turn = agent.thread[i];
              if (!turn.isUser && turn.working) {
                return _WorkingCard(text: turn.text);
              }
              return Align(
                alignment: turn.isUser
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: MessageBubble(
                  message: turn.text,
                  isUser: turn.isUser,
                  maxWidth: 560,
                ),
              );
            },
          ),
        ),
        _Composer(
          agentName: agent.name,
          controller: _controller,
          focus: _focus,
          kbFocus: _kbFocus,
          onSubmit: _submit,
        ),
      ],
    );
  }
}

class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({required this.agent, this.onBack});

  final CoworkAgent agent;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              icon: Icon(Icons.arrow_back, color: scheme.onSurfaceVariant),
              onPressed: onBack,
            ),
          CoworkAvatar(agent: agent, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              agent.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Screen',
            icon: Icon(
              Icons.desktop_windows_outlined,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}

/// A live-run card — the "Computer / Working" block from the reference.
class _WorkingCard extends StatelessWidget {
  const _WorkingCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.desktop_windows_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                'Computer',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 12, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      'Working',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.agentName,
    required this.controller,
    required this.focus,
    required this.kbFocus,
    required this.onSubmit,
  });

  final String agentName;
  final TextEditingController controller;
  final FocusNode focus;
  final FocusNode kbFocus;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: Icon(Icons.add, color: scheme.onSurfaceVariant),
                onPressed: () {},
              ),
              Expanded(
                child: buildKeyboardListener(
                  focusNode: kbFocus,
                  controller: controller,
                  onSend: onSubmit,
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    minLines: 1,
                    maxLines: 6,
                    style: TextStyle(color: scheme.onSurface, fontSize: 14.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Message $agentName',
                      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final hasText = value.text.trim().isNotEmpty;
                  return buildTinyActionButton(
                    icon: hasText
                        ? Icons.arrow_upward_rounded
                        : Icons.mic_none_rounded,
                    color: scheme.primary,
                    onTap: hasText ? onSubmit : () {},
                    buttonSize: 40,
                    iconSize: 18,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        'Pick a coworker to open the thread',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
