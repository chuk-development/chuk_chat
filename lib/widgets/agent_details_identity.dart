/// The top of the desktop details pane: the coworker's face, large and
/// centred, and its name, role and description as form fields.
///
/// Each field saves through a path that already exists. No field uses a new
/// wire message:
///
///  * NAME: the shell's rename path ([onRename]). It writes the roster and
///    sends `agent_rename` to the host. Without [onRename] the field is
///    read-only.
///  * ROLE and DESCRIPTION (the standing brief): [AgentProfileStore], the
///    store the profile edit page writes. No wire frame carries them, so they
///    stay on this device, and the pane says so.
///
/// A field saves when it loses focus, on Enter (single-line fields), and when
/// the pane closes with an edit in it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';

class AgentDetailsIdentity extends StatefulWidget {
  const AgentDetailsIdentity({
    super.key,
    required this.agent,
    this.onRename,
    this.profiles,
  });

  final AgentsAgent agent;

  /// The shell's rename path. Null makes the name field read-only.
  final ValueChanged<String>? onRename;

  /// Where the role and the description are kept. Defaults to
  /// [AgentProfileStore.instance].
  final AgentProfileStore? profiles;

  /// The size of the face at the top of the pane.
  static const double faceSize = 64;

  @override
  State<AgentDetailsIdentity> createState() => _AgentDetailsIdentityState();
}

class _AgentDetailsIdentityState extends State<AgentDetailsIdentity> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _role = TextEditingController();
  final TextEditingController _brief = TextEditingController();
  final FocusNode _nameFocus = FocusNode(debugLabel: 'details-name');
  final FocusNode _roleFocus = FocusNode(debugLabel: 'details-role');
  final FocusNode _briefFocus = FocusNode(debugLabel: 'details-brief');

  /// The values the fields last showed from their store. A field whose text
  /// differs from these has an edit that is not saved yet.
  String _savedRole = '';
  String _savedBrief = '';

  /// The name last handed to the rename path. Enter and the loss of focus
  /// that follows it both commit; the roster's new name arrives a frame
  /// later, so without this the host would get the same rename twice.
  String? _sentName;

  AgentProfileStore get _store => widget.profiles ?? AgentProfileStore.instance;

  @override
  void initState() {
    super.initState();
    _takeAll();
    _nameFocus.addListener(_onNameFocus);
    _roleFocus.addListener(_onRoleFocus);
    _briefFocus.addListener(_onBriefFocus);
    _store.addListener(_onStore);
  }

  @override
  void didUpdateWidget(AgentDetailsIdentity old) {
    super.didUpdateWidget(old);
    if (old.profiles != widget.profiles) {
      (old.profiles ?? AgentProfileStore.instance).removeListener(_onStore);
      _store.addListener(_onStore);
    }
    if (old.agent.id != widget.agent.id) {
      _takeAll();
      return;
    }
    // A rename from somewhere else (the roster menu, the host) shows here,
    // unless the user is typing a new name now.
    if (old.agent.name != widget.agent.name) {
      _sentName = null;
      if (!_nameFocus.hasFocus) _name.text = widget.agent.name;
    }
    if (old.agent.role != widget.agent.role ||
        old.agent.brief != widget.agent.brief) {
      _onStore();
    }
  }

  @override
  void dispose() {
    // An edit still in a field when the pane closes is saved, after this
    // frame: saving notifies listeners, which must not happen while the tree
    // is being torn down.
    final String name = _name.text.trim();
    final String role = _role.text.trim();
    final String brief = _brief.text.trim();
    final bool nameDirty =
        name.isNotEmpty && name != widget.agent.name && name != _sentName;
    final bool roleDirty = role != _savedRole;
    final bool briefDirty = brief != _savedBrief;
    if (nameDirty || roleDirty || briefDirty) {
      final ValueChanged<String>? rename = widget.onRename;
      final AgentProfileStore store = _store;
      final AgentsAgent agent = widget.agent;
      scheduleMicrotask(() {
        if (nameDirty) rename?.call(name);
        if (roleDirty || briefDirty) {
          unawaited(
            _write(
              store,
              agent,
              role: roleDirty ? role : null,
              brief: briefDirty ? brief : null,
            ),
          );
        }
      });
    }
    _store.removeListener(_onStore);
    _nameFocus.dispose();
    _roleFocus.dispose();
    _briefFocus.dispose();
    _name.dispose();
    _role.dispose();
    _brief.dispose();
    super.dispose();
  }

  // --- values ----------------------------------------------------------------

  /// The stored value first, then what the roster knows. This is the order
  /// the profile edit page uses.
  String _storedRole() =>
      _store.profileOf(widget.agent.id).roleOver(widget.agent.role) ?? '';

  String _storedBrief() =>
      _store.profileOf(widget.agent.id).briefOver(widget.agent.brief) ?? '';

  void _takeAll() {
    _sentName = null;
    _name.text = widget.agent.name;
    _savedRole = _storedRole();
    _savedBrief = _storedBrief();
    _role.text = _savedRole;
    _brief.text = _savedBrief;
  }

  /// The store changed (it loaded, or the edit page saved). A field the user
  /// is not editing takes the new value.
  void _onStore() {
    if (!mounted) return;
    final String role = _storedRole();
    final String brief = _storedBrief();
    if (!_roleFocus.hasFocus && _role.text.trim() == _savedRole) {
      _role.text = role;
      _savedRole = role;
    }
    if (!_briefFocus.hasFocus && _brief.text.trim() == _savedBrief) {
      _brief.text = brief;
      _savedBrief = brief;
    }
  }

  // --- saving ----------------------------------------------------------------

  void _onNameFocus() {
    if (!_nameFocus.hasFocus) _commitName();
  }

  void _onRoleFocus() {
    if (!_roleFocus.hasFocus) _commitRole();
  }

  void _onBriefFocus() {
    if (!_briefFocus.hasFocus) _commitBrief();
  }

  void _commitName() {
    final ValueChanged<String>? rename = widget.onRename;
    if (rename == null) return;
    final String name = _name.text.trim();
    // An empty name is not a name: the field goes back to the one it had.
    if (name.isEmpty) {
      _name.text = widget.agent.name;
      return;
    }
    if (name == widget.agent.name || name == _sentName) return;
    _sentName = name;
    rename(name);
  }

  void _commitRole() {
    final String role = _role.text.trim();
    if (role == _savedRole) return;
    _savedRole = role;
    unawaited(_write(_store, widget.agent, role: role, brief: null));
  }

  void _commitBrief() {
    final String brief = _brief.text.trim();
    if (brief == _savedBrief) return;
    _savedBrief = brief;
    unawaited(_write(_store, widget.agent, role: null, brief: brief));
  }

  /// Writes the given fields; a null field is left as it is. An emptied
  /// field over a line the agent has is stored empty, so the clear sticks
  /// ([AgentProfile.storedText]); otherwise it is removed.
  static Future<void> _write(
    AgentProfileStore store,
    AgentsAgent agent, {
    required String? role,
    required String? brief,
  }) {
    final String? roleValue = role == null
        ? null
        : AgentProfile.storedText(role, agent.role);
    final String? briefValue = brief == null
        ? null
        : AgentProfile.storedText(brief, agent.brief);
    return store.update(
      agent.id,
      role: roleValue,
      clearRole: role != null && roleValue == null,
      brief: briefValue,
      clearBrief: brief != null && briefValue == null,
    );
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canRename = widget.onRename != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: AgentFace(
            key: const ValueKey<String>('details-face'),
            agent: widget.agent,
            size: AgentDetailsIdentity.faceSize,
            store: _store,
            showPresence: false,
          ),
        ),
        const SizedBox(height: 20),
        _label(context, 'Name'),
        TextField(
          key: const ValueKey<String>('details-name-field'),
          controller: _name,
          focusNode: _nameFocus,
          readOnly: !canRename,
          textInputAction: TextInputAction.done,
          decoration: _decoration(hint: 'Coworker name'),
          onSubmitted: (_) => _commitName(),
        ),
        const SizedBox(height: 14),
        _label(context, 'Role (optional)'),
        TextField(
          key: const ValueKey<String>('details-role-field'),
          controller: _role,
          focusNode: _roleFocus,
          textInputAction: TextInputAction.done,
          decoration: _decoration(hint: 'Research, marketing, admin'),
          onSubmitted: (_) => _commitRole(),
        ),
        const SizedBox(height: 14),
        _label(context, 'Description'),
        TextField(
          key: const ValueKey<String>('details-brief-field'),
          controller: _brief,
          focusNode: _briefFocus,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          decoration: _decoration(hint: 'What this coworker takes care of'),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Role and description stay on this device.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// The app's form field look (the profile edit page uses the same): a
  /// filled field, corner 18, no outline.
  static InputDecoration _decoration({required String hint}) => InputDecoration(
    isDense: true,
    filled: true,
    hintText: hint,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(18)),
      borderSide: BorderSide.none,
    ),
  );
}
