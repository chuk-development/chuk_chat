/// The "Permissions" section of a coworker's profile (docs/WIRE_CONTRACT.md,
/// "Agent permissions").
///
/// One switch per permission, a one-line explanation under each, and the
/// rule that matters: a change applies from the coworker's next task. The
/// switches show what the host answered and stay disabled until it has; the
/// host is the truth, the app never guesses a value.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// One switch of the section: the wire key, the words and the icon.
@immutable
class AgentPermissionSpec {
  const AgentPermissionSpec({
    required this.key,
    required this.title,
    required this.explanation,
    required this.icon,
  });

  final String key;
  final String title;
  final String explanation;

  /// A glyph the app's icon table maps to a HugeIcon.
  final IconData icon;
}

/// The switches, in the order of [AgentPermissions.keys].
const List<AgentPermissionSpec> kAgentPermissionSpecs = <AgentPermissionSpec>[
  AgentPermissionSpec(
    key: AgentPermissions.keySudo,
    title: 'Root access (sudo)',
    explanation: 'Install packages and change the system in its sandbox.',
    icon: Icons.terminal,
  ),
  AgentPermissionSpec(
    key: AgentPermissions.keyNetwork,
    title: 'Internet',
    explanation: 'Sandbox and web tools.',
    icon: Icons.public,
  ),
  AgentPermissionSpec(
    key: AgentPermissions.keySecretsEnv,
    title: 'Secrets as env vars',
    explanation: 'Your API keys reach its commands as environment variables.',
    icon: Icons.key,
  ),
  AgentPermissionSpec(
    key: AgentPermissions.keyWorkspaceMount,
    title: 'Write to workspace',
    explanation: 'Change files in its workspace. Off makes it read-only.',
    icon: Icons.folder_outlined,
  ),
  AgentPermissionSpec(
    key: AgentPermissions.keyUserBrowser,
    title: 'Your browser',
    explanation: 'Use the browser add-on on your computer.',
    icon: Icons.laptop_mac,
  ),
];

/// The line under the switches while everything is fine.
const String kPermissionsAppliesLine =
    'Changes apply from the next task. The sandbox is rebuilt then; the '
    'files in its workspace stay.';

/// The subtitle of a switch this host cannot enforce (the local backend).
const String kPermissionNotEnforced = 'Not enforced on this host';

class AgentPermissionsSection extends StatefulWidget {
  const AgentPermissionsSection({
    super.key,
    required this.agentId,
    this.service,
    this.answerTimeout = const Duration(seconds: 10),
  });

  /// The coworker, which is also its thread's `session_key`.
  final String agentId;

  /// Defaults to [AgentsPermissionsService.instance].
  final AgentsPermissionsService? service;

  /// How long to wait for the host (its capability, then its answer) before
  /// saying it gave none.
  final Duration answerTimeout;

  @override
  State<AgentPermissionsSection> createState() =>
      _AgentPermissionsSectionState();
}

enum _Phase { asking, offline, unsupported, noAnswer, ready }

class _AgentPermissionsSectionState extends State<AgentPermissionsSection> {
  late AgentsPermissionsService _service;
  _Phase _phase = _Phase.asking;
  Timer? _answerTimer;

  /// A `get` went out on the current connection and was not answered yet.
  bool _asked = false;
  bool _wasConnected = false;
  bool _wasSupported = false;

  @override
  void initState() {
    super.initState();
    _bind(widget.service ?? AgentsPermissionsService.instance);
  }

  @override
  void didUpdateWidget(AgentPermissionsSection old) {
    super.didUpdateWidget(old);
    if (old.agentId != widget.agentId || old.service != widget.service) {
      _service.removeListener(_onChanged);
      _bind(widget.service ?? AgentsPermissionsService.instance);
    }
  }

  @override
  void dispose() {
    _answerTimer?.cancel();
    _service.removeListener(_onChanged);
    super.dispose();
  }

  /// Called from [initState] and [didUpdateWidget], which both build next,
  /// so the phase is set without [setState].
  void _bind(AgentsPermissionsService service) {
    // A timer of the previous coworker or service must not fire into this
    // one, and its noAnswer/unsupported must not carry over.
    _answerTimer?.cancel();
    _answerTimer = null;
    _service = service;
    _service.attach();
    _service.addListener(_onChanged);
    _asked = false;
    _wasConnected = _service.connected;
    _wasSupported = _service.supported;
    _phase = _Phase.asking;
    _phase = _phaseNow();
    _maybeAsk();
  }

  _Phase _phaseNow() {
    if (_service.isKnown(widget.agentId)) {
      return _service.connected ? _Phase.ready : _Phase.offline;
    }
    if (!_service.connected) return _Phase.offline;
    return _phase == _Phase.noAnswer || _phase == _Phase.unsupported
        ? _phase
        : _Phase.asking;
  }

  /// Ask when there is a host that can answer and nothing went out yet. A
  /// host that has not named the capability gets [answerTimeout] to do so.
  void _maybeAsk() {
    if (_asked || !_service.connected) return;
    _answerTimer?.cancel();
    if (!_service.supported) {
      _answerTimer = Timer(widget.answerTimeout, () {
        if (!mounted || _service.supported) return;
        setState(() => _phase = _Phase.unsupported);
      });
      return;
    }
    _asked = true;
    unawaited(_ask());
  }

  Future<void> _ask() async {
    final bool sent = await _service.refresh(widget.agentId);
    if (!mounted) return;
    if (!sent) {
      _asked = false;
      setState(() => _phase = _Phase.offline);
      return;
    }
    if (_service.isKnown(widget.agentId)) return;
    _answerTimer = Timer(widget.answerTimeout, () {
      if (!mounted || _service.isKnown(widget.agentId)) return;
      setState(() => _phase = _Phase.noAnswer);
    });
  }

  void _onChanged() {
    if (!mounted) return;
    final bool connected = _service.connected;
    final bool supported = _service.supported;
    // A new connection, or a host that just named the capability: ask again.
    // This is also the retry after a failed send.
    if ((connected && !_wasConnected) || (supported && !_wasSupported)) {
      _asked = false;
      if (_phase != _Phase.ready) _phase = _Phase.asking;
    }
    if (!connected) _asked = false;
    _wasConnected = connected;
    _wasSupported = supported;
    setState(() {
      if (_service.isKnown(widget.agentId) && connected) {
        _answerTimer?.cancel();
        _phase = _Phase.ready;
      } else {
        _phase = _phaseNow();
      }
    });
    _maybeAsk();
  }

  Future<void> _toggle(String key, bool on) async {
    final bool sent = await _service.setSwitch(widget.agentId, key, on);
    if (!mounted || sent) return;
    setState(() => _phase = _Phase.offline);
    pillToast(context, 'Not connected to the host');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool known = _service.isKnown(widget.agentId);
    final bool editable = known && _phase == _Phase.ready;
    final AgentPermissions permissions = _service.permissionsOf(widget.agentId);
    final String? error = _service.errorOf(widget.agentId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: Text(
            'PERMISSIONS',
            style: text.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
        ExpressiveGroup(
          children: <Widget>[
            for (final AgentPermissionSpec spec in kAgentPermissionSpecs)
              _row(spec, permissions, editable),
          ],
        ),
        const SizedBox(height: 8),
        if (error != null) ...<Widget>[
          ExpressiveInfoCard(
            key: const ValueKey<String>('agent-permissions-error'),
            text: known
                ? 'The host kept the last setting: $error'
                : 'The host said: $error',
            icon: Icons.error_outline,
            tone: scheme.errorContainer,
          ),
          const SizedBox(height: 8),
        ],
        ExpressiveInfoCard(
          key: const ValueKey<String>('agent-permissions-status'),
          text: _statusLine(known),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _row(
    AgentPermissionSpec spec,
    AgentPermissions permissions,
    bool editable,
  ) {
    final bool enforced = _service.isEnforced(widget.agentId, spec.key);
    return Semantics(
      identifier: 'agent_permission_${spec.key}',
      child: ExpressiveSwitchRow(
        key: ValueKey<String>('agent-permission-${spec.key}'),
        title: spec.title,
        subtitle: enforced ? spec.explanation : kPermissionNotEnforced,
        icon: spec.icon,
        value: permissions.isOn(spec.key),
        onChanged: editable && enforced
            ? (bool on) => _toggle(spec.key, on)
            : null,
      ),
    );
  }

  String _statusLine(bool known) {
    switch (_phase) {
      case _Phase.offline:
        return known
            ? 'Not connected to the host. Connect to change permissions.'
            : 'Not connected to the host. Connect to see and change '
                  'permissions.';
      case _Phase.unsupported:
        return 'This host does not manage permissions yet. Update the host '
            'to switch them.';
      case _Phase.noAnswer:
        return 'The host did not answer. Update the host to manage '
            'permissions.';
      case _Phase.asking:
        return 'Asking the host…';
      case _Phase.ready:
        return kPermissionsAppliesLine;
    }
  }
}
