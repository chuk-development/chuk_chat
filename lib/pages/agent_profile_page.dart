/// A coworker's profile: who it is, what it is doing, and everything the user
/// can set or manage about it.
///
/// This is the messenger's contact page, with a coworker in place of a person.
/// The header is the blob face, the name, the role line and the live state; the
/// action row is Message, the parked voice call, Controls and — only while it
/// really has one open — the coworker's browser. Under that: the standing brief,
/// the schedule, the one permanent session, and the manage block (edit, rename,
/// hide, delete).
///
/// The page never invents a fact. A field the app does not have (the host does
/// not serve a brief, and no wire frame carries a picture) is either shown from
/// the local profile store or left out.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/pages/agent_profile_edit_page.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/feedback.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/working_dots.dart';

class AgentProfilePage extends StatelessWidget {
  const AgentProfilePage({
    super.key,
    required this.agentId,
    required this.source,
    this.onRename,
    this.onDelete,
    this.onOpenControls,
    this.onOpenBrowser,
    this.onMessage,
    this.profiles,
  });

  /// The coworker is read from the roster by id on every build, so a rename or a
  /// state change lands here without the caller pushing a new page.
  final String agentId;
  final AgentRosterSource source;

  /// Renames the coworker. This is the one field that reaches the host.
  final void Function(CoworkAgent agent)? onRename;

  /// Deletes the coworker. The page pops itself first.
  final void Function(CoworkAgent agent)? onDelete;

  /// Opens the agent control surface.
  final VoidCallback? onOpenControls;

  /// Opens the coworker's browser. Null when it has none open.
  final VoidCallback? onOpenBrowser;

  /// Back to the conversation. Null when the page was opened from the chat
  /// itself, where "Message" is just "go back".
  final VoidCallback? onMessage;

  final AgentProfileStore? profiles;

  /// Pushes the page as a route.
  static Future<void> open(
    BuildContext context, {
    required String agentId,
    required AgentRosterSource source,
    void Function(CoworkAgent agent)? onRename,
    void Function(CoworkAgent agent)? onDelete,
    VoidCallback? onOpenControls,
    VoidCallback? onOpenBrowser,
    VoidCallback? onMessage,
    AgentProfileStore? profiles,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AgentProfilePage(
          agentId: agentId,
          source: source,
          onRename: onRename,
          onDelete: onDelete,
          onOpenControls: onOpenControls,
          onOpenBrowser: onOpenBrowser,
          onMessage: onMessage,
          profiles: profiles,
        ),
      ),
    );
  }

  AgentProfileStore get _store => profiles ?? AgentProfileStore.instance;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[source, _store]),
      builder: (BuildContext context, Widget? _) {
        final CoworkAgent? agent = source.byId(agentId);
        if (agent == null) {
          // The coworker was deleted while the page was open. Say so instead of
          // rendering an empty shell.
          return Scaffold(
            appBar: AppBar(title: const Text('Coworker')),
            body: const Center(child: Text('This coworker is gone.')),
          );
        }
        return _build(context, agent);
      },
    );
  }

  Widget _build(BuildContext context, CoworkAgent agent) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final AgentProfile profile = _store.profileOf(agent.id);
    final Color accent = agentAccent(context, agent.id, store: _store);
    final String? role = _roleOf(agent, profile);
    final String? brief = _briefOf(agent, profile);

    return Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            pinned: true,
            backgroundColor: scheme.surface,
            toolbarHeight: 58,
            titleSpacing: 6,
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ExpressiveIconButton(
                  icon: Icons.arrow_back_rounded,
                  size: 42,
                  onTap: () => Navigator.of(context).maybePop(),
                  tooltip: 'Back',
                  semanticsId: 'agent_profile_back',
                ),
              ),
            ),
            leadingWidth: 62,
            title: Text(
              'Profile',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ExpressiveIconButton(
                  icon: Icons.edit_rounded,
                  size: 42,
                  color: scheme.primaryContainer,
                  onColor: scheme.onPrimaryContainer,
                  tooltip: 'Edit profile',
                  semanticsId: 'agent_profile_edit',
                  onTap: () => AgentProfileEditPage.open(
                    context,
                    agent: agent,
                    source: source,
                    onRename: onRename,
                    profiles: _store,
                  ),
                ),
              ),
            ],
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: Column(
                children: <Widget>[
                  AgentFace(agent: agent, size: 112, store: _store),
                  const SizedBox(height: 16),
                  Text(
                    agent.name,
                    textAlign: TextAlign.center,
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  if (role != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      role,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  _StatePill(agent: agent, accent: accent),
                  const SizedBox(height: 20),
                  _ActionRow(
                    onMessage: onMessage,
                    onOpenControls: onOpenControls,
                    onOpenBrowser: onOpenBrowser,
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (brief != null)
                    _InfoCard(
                      icon: Icons.assignment_rounded,
                      label: 'Standing brief',
                      value: brief,
                    ),
                  if (agent.schedule != null)
                    _InfoCard(
                      icon: Icons.schedule_rounded,
                      label: 'Schedule',
                      value: agent.schedule!.source,
                      note: agent.onHost
                          ? null
                          : 'Set in this app; the host does not run it yet.',
                    ),
                  _InfoCard(
                    icon: Icons.forum_rounded,
                    label: 'Session',
                    value: agent.threads.isEmpty
                        ? 'No session yet'
                        : agent.threads.first.title,
                    note: agent.threads.isEmpty
                        ? null
                        : 'One permanent session · ${agent.threads.first.key}',
                  ),
                  _InfoCard(
                    icon: agent.onHost
                        ? Icons.verified_rounded
                        : Icons.phonelink_off_rounded,
                    label: 'Runs on the host',
                    value: agent.onHost
                        ? 'Yes — this coworker runs on the paired host'
                        : 'Not yet — it lives in this app only',
                  ),
                  if (agent.attachmentNames.isNotEmpty)
                    _InfoCard(
                      icon: Icons.attach_file_rounded,
                      label: 'Attachments named at onboarding',
                      value: agent.attachmentNames.join(', '),
                      note: 'Names only — no file was pushed to the host.',
                    ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                    child: Text(
                      'MANAGE',
                      style: text.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  SheetAction(
                    icon: Icons.person_rounded,
                    label: 'Edit profile',
                    subtitle: 'Picture, colour, role, brief',
                    onTap: () => AgentProfileEditPage.open(
                      context,
                      agent: agent,
                      source: source,
                      onRename: onRename,
                      profiles: _store,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (onRename != null) ...<Widget>[
                    SheetAction(
                      icon: Icons.badge_rounded,
                      label: 'Rename',
                      subtitle: 'The host keeps the new name',
                      onTap: () => onRename!(agent),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (onOpenControls != null) ...<Widget>[
                    SheetAction(
                      icon: Icons.tune_rounded,
                      label: 'Agent controls',
                      onTap: onOpenControls!,
                    ),
                    const SizedBox(height: 8),
                  ],
                  SheetAction(
                    icon: Icons.call_rounded,
                    label: 'Voice call',
                    subtitle: 'Not available yet',
                    enabled: false,
                    onTap: () {},
                  ),
                  const SizedBox(height: 8),
                  SheetAction(
                    icon: Icons.visibility_off_rounded,
                    label: 'Hide from the list',
                    subtitle: 'Keeps the coworker and its session',
                    onTap: () {
                      source.hideAgent(agent.id);
                      pillToast(
                        context,
                        '${agent.name} is hidden',
                        icon: Icons.visibility_off_rounded,
                      );
                      Navigator.of(context).maybePop();
                    },
                  ),
                  if (onDelete != null) ...<Widget>[
                    const SizedBox(height: 8),
                    SheetAction(
                      icon: Icons.delete_rounded,
                      label: 'Delete coworker',
                      color: scheme.error,
                      onTap: () => _confirmDelete(context, agent),
                    ),
                  ],
                  SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, CoworkAgent agent) async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final NavigatorState navigator = Navigator.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('Delete ${agent.name}?'),
        content: const Text(
          'The coworker and its session are removed from this app, and it is '
          'pulled out of every room it is in.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.forget(agent.id);
    onDelete?.call(agent);
    navigator.maybePop();
  }

  String? _roleOf(CoworkAgent agent, AgentProfile profile) {
    final String? stored = profile.role?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final String? own = agent.role?.trim();
    return (own == null || own.isEmpty) ? null : own;
  }

  String? _briefOf(CoworkAgent agent, AgentProfile profile) {
    final String? stored = profile.brief?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final String? own = agent.brief?.trim();
    return (own == null || own.isEmpty) ? null : own;
  }
}

/// The live-state pill under the name: what the coworker is doing right now.
class _StatePill extends StatelessWidget {
  const _StatePill({required this.agent, required this.accent});

  final CoworkAgent agent;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    late final Widget label;
    late final Color color;
    switch (agent.activity) {
      case AgentActivity.working:
        color = scheme.primary;
        label = WorkingDots(color: scheme.primary, label: 'working');
      case AgentActivity.scheduled:
        color = scheme.tertiary;
        label = Text(
          'scheduled',
          style: TextStyle(
            color: scheme.tertiary,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        );
      case AgentActivity.waiting:
        color = scheme.onSurfaceVariant;
        label = Text(
          'waiting for a task',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.14),
        shape: const StadiumBorder(),
      ),
      child: label,
    );
  }
}

/// The row of round targets under the header.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.onMessage,
    required this.onOpenControls,
    required this.onOpenBrowser,
  });

  final VoidCallback? onMessage;
  final VoidCallback? onOpenControls;
  final VoidCallback? onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        _Action(
          icon: Icons.chat_bubble_rounded,
          label: 'Message',
          color: scheme.primaryContainer,
          onColor: scheme.onPrimaryContainer,
          onTap: onMessage ?? () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 14),
        // Parked, exactly like the header target.
        _Action(
          icon: Icons.call_rounded,
          label: 'Call',
          parked: true,
          onTap: () => pillToast(
            context,
            'Voice calls with a coworker are not available yet',
            icon: Icons.call_end_rounded,
          ),
        ),
        if (onOpenControls != null) ...<Widget>[
          const SizedBox(width: 14),
          _Action(
            icon: Icons.tune_rounded,
            label: 'Controls',
            onTap: onOpenControls!,
          ),
        ],
        if (onOpenBrowser != null) ...<Widget>[
          const SizedBox(width: 14),
          _Action(
            icon: Icons.desktop_windows_rounded,
            label: 'Browser',
            color: scheme.tertiaryContainer,
            onColor: scheme.onTertiaryContainer,
            onTap: onOpenBrowser!,
          ),
        ],
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.onColor,
    this.parked = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Color? onColor;
  final bool parked;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ExpressiveIconButton(
          icon: icon,
          size: 52,
          color: color,
          onColor: onColor,
          parked: parked,
          onTap: onTap,
          tooltip: label,
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: parked
                ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                : scheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// One labelled card in the profile body.
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.label,
    required this.value,
    this.note,
  });

  final IconData icon;
  final String label;
  final String value;

  /// A second line that qualifies the value — used where the app must say that
  /// something is local only.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label.toUpperCase(),
                    style: text.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.7,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (note != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      note!,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
