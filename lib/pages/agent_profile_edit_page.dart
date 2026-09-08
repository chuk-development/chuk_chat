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
    if (widget.onRename != null && name.isNotEmpty && name != widget.agent.name) {
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
        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: AppBar(
            backgroundColor: scheme.surface,
            title: const Text('Edit profile'),
            actions: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: TextButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
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
              _SectionLabel('Colour'),
              const SizedBox(height: 8),
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
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Picture, colour, role and brief are kept on this '
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
  });

  final CoworkAgent agent;
  final AgentProfileStore store;
  final int? overrideColor;

  @override
  Widget build(BuildContext context) {
    // AgentFace reads the stored colour; a colour picked but not saved yet is
    // painted as a ring around it, so the choice is visible before Save.
    final Color ring = overrideColor != null
        ? Color(overrideColor!)
        : agentAccent(context, agent.id, store: store);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 3),
      ),
      child: AgentFace(
        agent: agent,
        size: 104,
        store: store,
        showPresence: false,
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
            onTap: () => onPick(color.toARGB32()),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: selected == color.toARGB32()
                    ? Border.all(color: scheme.onSurface, width: 3)
                    : null,
              ),
              child: selected == color.toARGB32()
                  ? const Icon(Icons.check_rounded, size: 20, color: Colors.white)
                  : null,
            ),
          ),
        GestureDetector(
          onTap: onReset,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: selected == null
                  ? Border.all(color: scheme.onSurface, width: 3)
                  : null,
            ),
            child: Icon(
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
