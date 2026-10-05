/// A coworker's Telegram channel, in its controls (bead chuk_chat-02s5).
///
/// One switch, the plain warning that Telegram is not end-to-end encrypted,
/// and the steps that follow from where the host is: paste a bot token, send
/// the bot a message and type the 6-digit code it replies with, then "Linked
/// to NAME" with Unlink. The host runs the bot and is the truth: the switch
/// shows what the host answered, and every state and refusal is said in plain
/// words. Nothing here shows without a host that names `agent_channels`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_channels_service.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class AgentTelegramSection extends StatefulWidget {
  const AgentTelegramSection({
    super.key,
    required this.agentId,
    this.service,
    this.answerTimeout = const Duration(seconds: 10),
  });

  /// The coworker, as the host knows it (its id is its thread's key).
  final String agentId;

  /// Defaults to [AgentsChannelsService.instance].
  final AgentsChannelsService? service;

  /// How long to wait for the host's answer before saying it gave none.
  final Duration answerTimeout;

  @override
  State<AgentTelegramSection> createState() => _AgentTelegramSectionState();
}

class _AgentTelegramSectionState extends State<AgentTelegramSection> {
  late AgentsChannelsService _service;
  final TextEditingController _token = TextEditingController();
  final TextEditingController _code = TextEditingController();
  Timer? _answerTimer;

  /// A `get` went out on the current connection.
  bool _asked = false;
  bool _wasConnected = false;
  bool _wasSupported = false;

  /// The host did not answer in time.
  bool _noAnswer = false;

  /// The user flipped the switch on and the host has no token yet: the token
  /// field is open, nothing was sent.
  bool _enteringToken = false;

  @override
  void initState() {
    super.initState();
    _bind(widget.service ?? AgentsChannelsService.instance);
  }

  @override
  void didUpdateWidget(AgentTelegramSection old) {
    super.didUpdateWidget(old);
    if (old.agentId != widget.agentId || old.service != widget.service) {
      _service.removeListener(_onChanged);
      _token.clear();
      _code.clear();
      _enteringToken = false;
      _bind(widget.service ?? AgentsChannelsService.instance);
    }
  }

  @override
  void dispose() {
    _answerTimer?.cancel();
    _service.removeListener(_onChanged);
    _token.dispose();
    _code.dispose();
    super.dispose();
  }

  void _bind(AgentsChannelsService service) {
    _answerTimer?.cancel();
    _answerTimer = null;
    _service = service;
    _service.attach();
    _service.addListener(_onChanged);
    _asked = false;
    _noAnswer = false;
    _wasConnected = _service.connected;
    _wasSupported = _service.supported;
    _maybeAsk();
  }

  void _maybeAsk() {
    if (_asked || !_service.connected || !_service.supported) return;
    _asked = true;
    unawaited(_ask());
  }

  Future<void> _ask() async {
    final bool sent = await _service.refresh(widget.agentId);
    if (!mounted) return;
    if (!sent) {
      _asked = false;
      return;
    }
    if (_service.stateOf(widget.agentId) == null) _waitForAnswer();
  }

  /// Starts the clock on the host's answer to what just went out.
  void _waitForAnswer() {
    _answerTimer?.cancel();
    _answerTimer = Timer(widget.answerTimeout, () {
      if (!mounted) return;
      final bool waiting =
          _service.isBusy(widget.agentId) ||
          _service.stateOf(widget.agentId) == null;
      if (!waiting) return;
      _service.cancelBusy(widget.agentId);
      setState(() => _noAnswer = true);
    });
  }

  void _onChanged() {
    if (!mounted) return;
    final bool connected = _service.connected;
    final bool supported = _service.supported;
    if ((connected && !_wasConnected) || (supported && !_wasSupported)) {
      _asked = false;
    }
    if (!connected) _asked = false;
    _wasConnected = connected;
    _wasSupported = supported;
    final AgentChannelState? state = _service.stateOf(widget.agentId);
    final String? error = _service.errorOf(widget.agentId);
    setState(() {
      if (state != null && !_service.isBusy(widget.agentId)) {
        _noAnswer = false;
        _answerTimer?.cancel();
      }
      // The host took the token: the field closes and forgets it.
      if (state != null && state.enabled && error == null) {
        _enteringToken = false;
        _token.clear();
      }
      if (state != null && state.linked) _code.clear();
    });
    _maybeAsk();
  }

  Future<void> _act(
    AgentChannelAction action, {
    String? token,
    String? code,
  }) async {
    if (_service.isBusy(widget.agentId)) return;
    setState(() => _noAnswer = false);
    final bool sent = await _service.act(
      widget.agentId,
      action,
      token: token,
      code: code,
    );
    if (!mounted) return;
    if (sent) {
      _waitForAnswer();
    } else {
      setState(() {});
    }
  }

  void _onSwitch(bool on, AgentChannelState state) {
    if (on) {
      // A host that keeps a working token turns it on as it is; otherwise the
      // token comes first.
      if (state.hasToken && state.state != 'unauthorized') {
        unawaited(_act(AgentChannelAction.enable));
      } else {
        setState(() => _enteringToken = true);
      }
      return;
    }
    if (_enteringToken && !state.enabled) {
      setState(() => _enteringToken = false);
      return;
    }
    unawaited(_act(AgentChannelAction.disable));
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text?.trim();
    if (!mounted || text == null || text.isEmpty) return;
    setState(() {
      _token.text = text;
      _token.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_service.supported) return const SizedBox.shrink();
    final AppLocalizations? l = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final AgentChannelState? state = _service.stateOf(widget.agentId);
    final String? error = _service.errorOf(widget.agentId);
    final bool connected = _service.connected;
    final bool busy = _service.isBusy(widget.agentId);
    final bool enabled = state?.enabled ?? false;
    final bool editable = connected && state != null && !busy;
    final bool tokenRefused = enabled && state?.state == 'unauthorized';
    final bool showToken =
        state != null && (_enteringToken || tokenRefused) && connected;
    final bool showCode =
        state != null &&
        enabled &&
        !state.linked &&
        state.state != 'disallowed' &&
        state.state != 'unauthorized' &&
        connected;

    return Column(
      key: const ValueKey<String>('agent-telegram-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ExpressiveGroup(
          children: <Widget>[
            Semantics(
              identifier: 'agent_channel_telegram',
              child: ExpressiveSwitchRow(
                key: const ValueKey<String>('agent-telegram-switch'),
                title: l?.agentsTelegramTitle ?? 'Telegram',
                subtitle: _statusLine(l, state, connected),
                icon: Icons.send_rounded,
                value: enabled || _enteringToken,
                onChanged: editable ? (bool on) => _onSwitch(on, state) : null,
              ),
            ),
            if (state != null && state.linked)
              ExpressiveRow(
                key: const ValueKey<String>('agent-telegram-linked'),
                icon: Icons.link,
                title: state.linkedName.isEmpty
                    ? (l?.agentsTelegramLinkedChat ??
                          'Linked to a Telegram chat')
                    : (l?.agentsTelegramLinkedTo(state.linkedName) ??
                          'Linked to ${state.linkedName}'),
                trailing: _Gate(
                  enabled: editable,
                  child: ExpressiveButton(
                    key: const ValueKey<String>('agent-telegram-unlink'),
                    label: l?.agentsTelegramUnlink ?? 'Unlink',
                    tonal: true,
                    onTap: () => unawaited(_act(AgentChannelAction.unlink)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ExpressiveInfoCard(
          key: const ValueKey<String>('agent-telegram-e2e'),
          text:
              l?.agentsTelegramNotE2e ??
              'Telegram is not end-to-end encrypted.',
          icon: Icons.warning_amber_rounded,
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 8),
          ExpressiveInfoCard(
            key: const ValueKey<String>('agent-telegram-error'),
            text: _errorText(l, error),
            icon: Icons.error_outline,
            tone: theme.colorScheme.errorContainer,
          ),
        ],
        if (showToken) ...<Widget>[
          const SizedBox(height: 8),
          _field(
            context,
            label: l?.agentsTelegramTokenLabel ?? 'Bot token',
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('agent-telegram-token'),
                    controller: _token,
                    enabled: editable,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.deny(RegExp(r'\s')),
                    ],
                    onSubmitted: (_) => _submitToken(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                ExpressiveIconButton(
                  key: const ValueKey<String>('agent-telegram-paste'),
                  icon: Icons.content_paste_rounded,
                  size: 48,
                  tooltip: l?.agentsTelegramPaste ?? 'Paste',
                  onTap: editable ? () => unawaited(_paste()) : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _hint(
            context,
            l?.agentsTelegramTokenHint ??
                'Create a bot with @BotFather and paste its token.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _Gate(
                enabled: editable,
                child: ExpressiveButton(
                  key: const ValueKey<String>('agent-telegram-enable'),
                  label: l?.agentsTelegramTurnOn ?? 'Turn on',
                  onTap: _submitToken,
                ),
              ),
              if (_enteringToken && !enabled)
                ExpressiveButton(
                  key: const ValueKey<String>('agent-telegram-cancel'),
                  label: l?.agentsTelegramCancel ?? 'Cancel',
                  tonal: true,
                  onTap: () => setState(() {
                    _enteringToken = false;
                    _token.clear();
                  }),
                ),
            ],
          ),
        ],
        if (showCode) ...<Widget>[
          const SizedBox(height: 8),
          _hint(
            context,
            state.botUsername.isEmpty
                ? (l?.agentsTelegramLinkStepsNoBot ??
                      'Send any message to your bot, then enter the 6-digit '
                          'code it replies with.')
                : (l?.agentsTelegramLinkSteps(state.botUsername) ??
                      'Send any message to @${state.botUsername}, then enter '
                          'the 6-digit code it replies with.'),
            key: const ValueKey<String>('agent-telegram-link-steps'),
          ),
          const SizedBox(height: 8),
          _field(
            context,
            label: l?.agentsTelegramCodeLabel ?? '6-digit code',
            child: TextField(
              key: const ValueKey<String>('agent-telegram-code'),
              controller: _code,
              enabled: editable,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              onSubmitted: (_) => _submitCode(),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _Gate(
              enabled: editable,
              child: ExpressiveButton(
                key: const ValueKey<String>('agent-telegram-link'),
                label: l?.agentsTelegramLink ?? 'Link',
                onTap: _submitCode,
              ),
            ),
          ),
        ],
        if (state != null &&
            state.hasToken &&
            !enabled &&
            !_enteringToken &&
            connected) ...<Widget>[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _Gate(
              enabled: editable,
              child: ExpressiveButton(
                key: const ValueKey<String>('agent-telegram-forget'),
                label: l?.agentsTelegramForget ?? 'Remove bot',
                tonal: true,
                onTap: () => unawaited(_act(AgentChannelAction.forget)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _submitToken() {
    final String token = _token.text.trim();
    if (token.isEmpty) {
      // The host would answer token_required; say it without the round trip.
      _service.handleFrame(<String, dynamic>{
        'type': 'agent_channel',
        'agent_id': widget.agentId,
        'channel': kTelegramChannel,
        'error': 'token_required',
      });
      return;
    }
    unawaited(_act(AgentChannelAction.enable, token: token));
  }

  void _submitCode() {
    final String code = _code.text.trim();
    if (code.length != 6) return;
    unawaited(_act(AgentChannelAction.link, code: code));
  }

  Widget _field(
    BuildContext context, {
    required String label,
    required Widget child,
  }) {
    final ThemeData theme = Theme.of(context);
    return ExpressiveField(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.m3.onSurfaceVariant,
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _hint(BuildContext context, String text, {Key? key}) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.m3.onSurfaceVariant,
          height: 1.4,
        ),
      ),
    );
  }

  String _statusLine(
    AppLocalizations? l,
    AgentChannelState? state,
    bool connected,
  ) {
    if (!connected) {
      return l?.agentsTelegramOffline ?? 'Not connected to the host.';
    }
    if (state == null) {
      return _noAnswer
          ? (l?.agentsTelegramNoAnswer ?? 'The host did not answer.')
          : (l?.agentsTelegramAsking ?? 'Asking the host…');
    }
    if (_noAnswer) {
      return l?.agentsTelegramNoAnswer ?? 'The host did not answer.';
    }
    if (!state.allowed) {
      return l?.agentsTelegramStateDisallowed ??
          'Telegram is turned off on this host.';
    }
    return switch (state.state) {
      'disallowed' =>
        l?.agentsTelegramStateDisallowed ??
            'Telegram is turned off on this host.',
      'starting' => l?.agentsTelegramStateStarting ?? 'Starting…',
      'polling' =>
        state.botUsername.isEmpty
            ? (l?.agentsTelegramStateOn ?? 'On')
            : (l?.agentsTelegramStatePolling(state.botUsername) ??
                  'On · @${state.botUsername}'),
      'backoff' =>
        l?.agentsTelegramStateBackoff ?? 'Cannot reach Telegram. Trying again.',
      'conflict' =>
        l?.agentsTelegramStateConflict ??
            'Another program uses this bot token.',
      'unauthorized' =>
        l?.agentsTelegramStateUnauthorized ??
            'Telegram refused the token. Paste a new one.',
      'stopped' => l?.agentsTelegramStateStopped ?? 'Stopped.',
      _ => l?.agentsTelegramStateOff ?? 'Off',
    };
  }

  String _errorText(AppLocalizations? l, String code) => switch (code) {
    'token_required' =>
      l?.agentsTelegramErrTokenRequired ?? 'Paste the bot token first.',
    'token_invalid' =>
      l?.agentsTelegramErrTokenInvalid ?? 'That is not a bot token.',
    'token_in_use' =>
      l?.agentsTelegramErrTokenInUse ??
          'Another coworker already uses this bot.',
    'disallowed' =>
      l?.agentsTelegramStateDisallowed ??
          'Telegram is turned off on this host.',
    'not_running' =>
      l?.agentsTelegramErrNotRunning ??
          'The bot is not running. Turn it on first.',
    'wrong_code' =>
      l?.agentsTelegramErrWrongCode ??
          'Wrong code. Check the message from the bot.',
    'too_many_attempts' =>
      l?.agentsTelegramErrTooManyAttempts ??
          'Too many wrong codes. Send the bot a new message to get a new '
              'code.',
    'no_pending_link' =>
      l?.agentsTelegramErrNoPendingLink ??
          'No code is waiting. Send the bot a message first.',
    'unknown_agent' =>
      l?.agentsTelegramErrUnknownAgent ??
          'The host does not know this coworker.',
    _ => l?.agentsTelegramErrOther(code) ?? 'The host said: $code',
  };
}

/// Greys out and blocks a button while the host has not answered. The button
/// family has no disabled state of its own.
class _Gate extends StatelessWidget {
  const _Gate({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: Opacity(opacity: enabled ? 1 : 0.5, child: child),
  );
}
