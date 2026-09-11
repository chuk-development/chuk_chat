/// Setting a coworker's profile: its picture, its colour, its name, its role
/// line and its standing brief.
///
/// Where each field goes:
///
///  * the NAME is roster data and travels: the page calls back into the shell's
///    rename path, which writes the roster and sends `agent_rename` to the host;
///  * the PICTURE, the COLOUR, the ROLE and the BRIEF have no wire frame, so
///    they are written to [AgentProfileStore] and stay on this device. The page
///    says that under the fields rather than implying the host learns them.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/ui/expressive/icon_map.dart';
import 'package:image_picker/image_picker.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/feedback.dart';
import 'package:cowork/ui/expressive/motion.dart';

class AgentProfileEditPage extends StatefulWidget {
  const AgentProfileEditPage({
    super.key,
    required this.agent,
    required this.source,
    this.onRename,
    this.profiles,
    this.imagePicker,
  });

  final CoworkAgent agent;
  final AgentRosterSource source;

  /// The rename path of the shell — the only field that reaches the host. Null
  /// hides the name field.
  final void Function(CoworkAgent agent)? onRename;

  final AgentProfileStore? profiles;

  /// Injectable for tests; defaults to a real [ImagePicker].
  final ImagePicker? imagePicker;

  static Future<void> open(
    BuildContext context, {
    required CoworkAgent agent,
    required AgentRosterSource source,
    void Function(CoworkAgent agent)? onRename,
    AgentProfileStore? profiles,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AgentProfileEditPage(
          agent: agent,
          source: source,
          onRename: onRename,
          profiles: profiles,
        ),
      ),
    );
  }

  @override
  State<AgentProfileEditPage> createState() => _AgentProfileEditPageState();
}

class _AgentProfileEditPageState extends State<AgentProfileEditPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.agent.name,
  );
  late final TextEditingController _role = TextEditingController(
    text: _initialRole(),
  );
  late final TextEditingController _brief = TextEditingController(
    text: _initialBrief(),
  );

  AgentProfileStore get _store => widget.profiles ?? AgentProfileStore.instance;

  /// The colour picked in this session; null means "keep what is stored".
  int? _color;
  AgentAvatarShape? _shape;
  bool _clearColor = false;
  bool _busy = false;

  String _initialRole() {
    final String? stored = _store.profileOf(widget.agent.id).role?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return widget.agent.role?.trim() ?? '';
  }

  String _initialBrief() {
    final String? stored = _store.profileOf(widget.agent.id).brief?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return widget.agent.brief?.trim() ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    _brief.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final ImagePicker picker = widget.imagePicker ?? ImagePicker();
    try {
      final XFile? file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (file == null) return;
      final String? stored = await _store.setPhotoFromFile(
        widget.agent.id,
        file.path,
      );
      if (!mounted) return;
      if (stored == null) {
        pillToast(
          context,
          'Could not store that picture',
          icon: Icons.error_outline_rounded,
        );
        return;
      }
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      pillToast(
        context,
        'Could not open the gallery',
        icon: Icons.error_outline_rounded,
      );
      debugPrint('⚠️ [AgentProfileEdit] pickPhoto failed: $error');
    }
  }

  Future<void> _removePhoto() async {
    await _store.update(widget.agent.id, clearPhoto: true);
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final String name = _name.text.trim();
    final String role = _role.text.trim();
    final String brief = _brief.text.trim();

    // The name first: it is the one field with a host behind it.
    if (widget.onRename != null &&
        name.isNotEmpty &&
        name != widget.agent.name) {
      widget.onRename!(widget.agent.copyWith(name: name));
    }

    await _store.update(
      widget.agent.id,
      role: role.isEmpty ? null : role,
      brief: brief.isEmpty ? null : brief,
      clearRole: role.isEmpty,
      clearBrief: brief.isEmpty,
      colorValue: _color,
      clearColor: _clearColor,
      shape: _shape,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    pillToast(context, 'Profile saved', icon: Icons.check_rounded);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return AnimatedBuilder(
      animation: _store,
      builder: (BuildContext context, Widget? _) {
        final CoworkAgent agent =
            widget.source.byId(widget.agent.id) ?? widget.agent;
        final int? storedColor = _store.profileOf(agent.id).colorValue;
        final int? shownColor = _clearColor ? null : (_color ?? storedColor);
        return ExpressiveScreen(
          backgroundColor: scheme.surface,
          title: 'Edit profile',
          actions: <Widget>[
            TextButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
          ],
          builder: (BuildContext context) => ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.paddingOf(context).top + 12,
              20,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            children: <Widget>[
              Center(
                child: Column(
                  children: <Widget>[
                    // The face reads the store, so a new picture or colour shows
                    // the moment it is written.
                    _FacePreview(
                      agent: agent,
                      store: _store,
                      overrideColor: shownColor,
                      shape: _shape ?? _store.profileOf(agent.id).shape,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        ExpressiveButton(
                          icon: Icons.photo_camera_rounded,
                          label: 'Picture',
                          tonal: true,
                          onTap: _pickPhoto,
                        ),
                        if (_store.profileOf(agent.id).photoPath != null) ...[
                          const SizedBox(width: 10),
                          ExpressiveIconButton(
                            icon: Icons.delete_outline_rounded,
                            size: 46,
                            tooltip: 'Remove the picture',
                            onTap: _removePhoto,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              _SectionLabel('Figure'),
              const SizedBox(height: 8),
              // Colour and silhouette are one decision — what this coworker
              // looks like everywhere — so they sit in one card with one reset,
              // instead of two labelled sections the user has to connect.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _ColorRow(
                      selected: shownColor,
                      onPick: (int value) => setState(() {
                        _color = value;
                        _clearColor = false;
                      }),
                      onReset: () => setState(() {
                        _color = null;
                        _clearColor = true;
                      }),
                    ),
                    const SizedBox(height: 14),
                    Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 14),
                    _ShapeRow(
                      agentId: agent.id,
                      colour: shownColor == null
                          ? agentAccent(context, agent.id, store: _store)
                          : Color(shownColor),
                      selected: _shape ?? _store.profileOf(agent.id).shape,
                      onPick: (AgentAvatarShape? shape) =>
                          setState(() => _shape = shape),
                    ),
                    const SizedBox(height: 6),
                    Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('avatar_reset_default'),
                        onPressed: () => setState(() {
                          _color = null;
                          _clearColor = true;
                          _shape = AgentAvatarShape.expressive;
                        }),
                        child: const Text('Reset to default'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "How this coworker's mark looks everywhere",
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              if (widget.onRename != null) ...<Widget>[
                _SectionLabel('Name'),
                const SizedBox(height: 8),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(18)),
                      borderSide: BorderSide.none,
                    ),
                    hintText: 'Coworker name',
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'The host keeps the name, so it survives a fresh install.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
              ],
              _SectionLabel('Role'),
              const SizedBox(height: 8),
              TextField(
                controller: _role,
                decoration: const InputDecoration(
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(18)),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'researcher, release manager, …',
                ),
              ),
              const SizedBox(height: 24),
              _SectionLabel('Standing brief'),
              const SizedBox(height: 8),
              TextField(
                controller: _brief,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(18)),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'What this coworker takes care of',
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: <Widget>[
                    AppIcon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Picture, shape, colour, role and brief are kept on this '
                        'device. The relay carries names only.',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The face as it will look, with the colour the user is trying out.
class _FacePreview extends StatelessWidget {
  const _FacePreview({
    required this.agent,
    required this.store,
    required this.overrideColor,
    required this.shape,
  });

  final CoworkAgent agent;
  final AgentProfileStore store;
  final int? overrideColor;
  final AgentAvatarShape? shape;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: AgentFace(
        agent: agent,
        size: 104,
        store: store,
        showPresence: false,
        profileOverride: store
            .profileOf(agent.id)
            .copyWith(
              colorValue: overrideColor,
              clearColor: overrideColor == null,
              shape: shape,
            ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
      ),
    );
  }
}

/// The colour palette, plus a "back to the derived colour" target.
class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.selected,
    required this.onPick,
    required this.onReset,
  });

  final int? selected;
  final ValueChanged<int> onPick;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (final Color color in kAgentAccents)
          GestureDetector(
            key: ValueKey('avatar_color_${color.toARGB32()}'),
            onTap: () => onPick(color.toARGB32()),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: selected == color.toARGB32()
                    ? Border.all(color: scheme.onSurface, width: 3)
                    : null,
              ),
              child: selected == color.toARGB32()
                  ? const AppIcon(
                      Icons.check_rounded,
                      size: 20,
                      color: Colors.white,
                    )
                  : null,
            ),
          ),
        GestureDetector(
          key: const ValueKey('avatar_color_default'),
          onTap: onReset,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: selected == null
                  ? Border.all(color: scheme.onSurface, width: 3)
                  : null,
            ),
            child: AppIcon(
              Icons.auto_awesome_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// The silhouettes a coworker can be given, drawn as themselves.
///
/// A row of shapes says what it offers; a row of chips labelled "Rounded
/// square" makes the reader translate a word back into a picture. The first
/// entry is the automatic one — the silhouette derived from the agent id,
/// which is what a coworker wears until somebody picks.
class _ShapeRow extends StatelessWidget {
  const _ShapeRow({
    required this.agentId,
    required this.colour,
    required this.selected,
    required this.onPick,
  });

  final String agentId;
  final Color colour;
  final AgentAvatarShape? selected;
  final ValueChanged<AgentAvatarShape?> onPick;

  static const List<AgentAvatarShape> _offered = <AgentAvatarShape>[
    AgentAvatarShape.expressive,
    AgentAvatarShape.round,
    AgentAvatarShape.roundedSquare,
    AgentAvatarShape.oval,
    AgentAvatarShape.triangle,
    AgentAvatarShape.gem,
    AgentAvatarShape.clover,
    AgentAvatarShape.flower,
    AgentAvatarShape.cookie,
    AgentAvatarShape.diamond,
    AgentAvatarShape.burst,
    AgentAvatarShape.square,
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AgentAvatarShape current = selected ?? AgentAvatarShape.expressive;
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _offered.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (BuildContext context, int i) {
          final AgentAvatarShape shape = _offered[i];
          final bool isSelected = shape == current;
          return GestureDetector(
            key: ValueKey('avatar_shape_${shape.name}'),
            onTap: () => onPick(shape),
            child: Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: isSelected
                    ? Border.all(color: scheme.onSurface, width: 2)
                    : null,
              ),
              child: Container(
                width: 34,
                height: 34,
                decoration: ShapeDecoration(
                  color: colour,
                  shape: agentAvatarShape(agentId, shape, 34),
                ),
                child: shape == AgentAvatarShape.expressive
                    ? AppIcon(
                        Icons.auto_awesome_rounded,
                        size: 16,
                        color: scheme.surface,
                      )
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }
}
