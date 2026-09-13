/// A live group-room conversation (§16.1/4c): subscribes to the relay client's
/// inbound and accumulates the room's turns into a [RoomThreadView] as they
/// arrive, then names the stop reason when the exchange ends.
///
/// [RoomThreadView] is a pure render; this is the stateful half that turns a
/// stream of `room_turn` / `room_done` events into the list it draws. The stream
/// is injected, so a test drives it with a fake controller and the shell drives
/// it with the real relay socket — the same widget either way.
///
/// Frames carry a `room_id` (§16.1 4b-relay), so this keeps only the ones for
/// [roomId] and ignores the rest — several rooms can stream over the one socket
/// without crossing wires.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/room_mention_picker.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

class RoomThreadPage extends StatefulWidget {
  const RoomThreadPage({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.userMessage,
    required this.inbound,
    this.members = const <AgentsRoomMember>[],
    this.agents = const <AgentsAgent>[],
    this.rebind,
    this.onSend,
    this.onReady,
  });

  /// The room this page shows. Frames for any other room on the shared socket
  /// are ignored, so several rooms can stream at once without crossing wires.
  final String roomId;

  final String roomName;

  /// The room's members, shown in the header strip and offered by the
  /// composer's `@mention` picker. Empty means no picker: there is nobody to
  /// mention.
  final List<AgentsRoomMember> members;

  /// The roster, only so the mention picker can show a member's display name
  /// and role instead of the bare handle. A member with no agent here still
  /// gets a row, labelled by its handle, so an empty list costs nothing.
  final List<AgentsAgent> agents;

  /// What the user posted to the room, shown at the top.
  final String userMessage;

  /// The relay client's inbound event stream. Room turns and the room's end are
  /// picked out of it; every other event is ignored here (they belong to the
  /// agent thread).
  final Stream<AgentsRelayInbound> inbound;

  /// The shared transport, if the caller wants the page to follow it. When set,
  /// a reconnect (the value changes to a fresh controller) makes the page
  /// re-subscribe to the new inbound and re-run [onReady] — seamless recovery on
  /// a changing network. When null the page uses [inbound] once and shows the
  /// reconnect banner if that stream dies (the tests' path).
  final ValueListenable<AgentsRelayController?>? rebind;

  /// Sends a message to the room (starts an exchange). When null the composer is
  /// hidden — the page is read-only.
  final void Function(String message)? onSend;

  /// Called once after the page subscribes, so the caller can request the stored
  /// history (which then arrives as a `room_history` event on [inbound]).
  final VoidCallback? onReady;

  @override
  State<RoomThreadPage> createState() => _RoomThreadPageState();
}

class _RoomThreadPageState extends State<RoomThreadPage> {
  final List<AgentsRoomTurn> _turns = <AgentsRoomTurn>[];
  final TextEditingController _composer = TextEditingController();
  AgentsRoomStop? _stop;
  bool _running = true;
  bool _disconnected = false;
  StreamSubscription<AgentsRelayInbound>? _sub;
  // The message the user actually sent, shown at the top once sent. Until then
  // the caller's placeholder ([userMessage]) stands in.
  String? _sentMessage;

  // --- the @mention picker -------------------------------------------------
  //
  // The token the caret is in right now, the rows it matches and which of them
  // is highlighted. All three are null/empty when the picker is closed, so
  // "_mentionToken != null" is the one question the composer asks.
  MentionToken? _mentionToken;
  List<MentionEntry> _mentionMatches = const <MentionEntry>[];
  int _mentionIndex = 0;
  // Escape closed the picker on the token that starts here. It stays closed
  // while the caret is still in that same token, and opens again at the next
  // one — otherwise the next keystroke would undo the dismissal.
  int? _dismissedAt;

  @override
  void initState() {
    super.initState();
    _composer.addListener(_syncMention);
    _subscribe(_currentInbound());
    widget.rebind?.addListener(_onRebind);
    // Subscribe first, then ask — so a fast history reply cannot arrive before
    // the listener is attached.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady?.call());
  }

  @override
  void dispose() {
    widget.rebind?.removeListener(_onRebind);
    _sub?.cancel();
    _composer.removeListener(_syncMention);
    _composer.dispose();
    super.dispose();
  }

  /// The inbound to listen to now: the live controller's when following one,
  /// else the fixed stream passed in.
  Stream<AgentsRelayInbound> _currentInbound() =>
      widget.rebind != null ? _fromRebind() : widget.inbound;

  Stream<AgentsRelayInbound> _fromRebind() {
    final controller = widget.rebind!.value;
    // No controller yet -> a stream that never emits; the rebind listener will
    // swap us onto the real one the moment it arrives.
    return controller?.inbound ?? const Stream<AgentsRelayInbound>.empty();
  }

  void _subscribe(Stream<AgentsRelayInbound> stream) {
    _sub?.cancel();
    _sub = stream.listen(_onInbound, onDone: _onStreamClosed);
  }

  void _onRebind() {
    // The transport changed (a reconnect). Follow it: re-subscribe to the new
    // inbound, drop the disconnected state, and re-run onReady so the room is
    // re-synced and its history re-requested on the fresh socket.
    if (!mounted) return;
    final controller = widget.rebind!.value;
    if (controller == null) {
      _onStreamClosed();
      return;
    }
    setState(() => _disconnected = false);
    _subscribe(controller.inbound);
    widget.onReady?.call();
  }

  Widget _reconnectBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            AppIcon(
              Icons.wifi_off,
              size: 16,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Connection changed. Reopen the room to continue.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _send() {
    final text = _composer.text.trim();
    final onSend = widget.onSend;
    if (text.isEmpty || onSend == null || _disconnected) return;
    onSend(text);
    setState(() {
      _sentMessage = text;
      // A new exchange: clear the previous turns and re-enter the running state.
      _turns.clear();
      _stop = null;
      _running = true;
      _composer.clear();
    });
  }

  // --- the @mention picker -------------------------------------------------

  bool get _mentionOpen => _mentionToken != null && _mentionMatches.isNotEmpty;

  /// Every row the room offers, `@all` first. Rebuilt per keystroke: a room has
  /// a handful of members, and a cached list would go stale on a rename.
  List<MentionEntry> get _mentionEntries =>
      mentionEntriesFor(members: widget.members, agents: widget.agents);

  /// Read the composer and decide whether the picker is open, and on what.
  void _syncMention() {
    if (!mounted) return;
    final TextSelection sel = _composer.selection;
    final MentionToken? token =
        (widget.members.isEmpty ||
            _disconnected ||
            !sel.isValid ||
            !sel.isCollapsed)
        ? null
        : activeMentionToken(_composer.text, sel.baseOffset);
    // A token that was dismissed stays dismissed until the caret leaves it.
    if (token != null && _dismissedAt == token.start) {
      if (_mentionToken != null) setState(_clearMentionState);
      return;
    }
    if (token == null) {
      if (_mentionToken != null || _dismissedAt != null) {
        setState(() {
          _clearMentionState();
          _dismissedAt = null;
        });
      }
      return;
    }
    final List<MentionEntry> matches = filterMentions(
      _mentionEntries,
      token.query,
    );
    // Keep the highlight on the same handle while the list narrows, so a row
    // does not change under a finger that is already on the way to Enter.
    final String? wanted =
        _mentionOpen && _mentionIndex < _mentionMatches.length
        ? _mentionMatches[_mentionIndex].handle
        : null;
    final int keep = wanted == null
        ? -1
        : matches.indexWhere((MentionEntry e) => e.handle == wanted);
    setState(() {
      _dismissedAt = null;
      _mentionToken = matches.isEmpty ? null : token;
      _mentionMatches = matches;
      _mentionIndex = keep >= 0 ? keep : 0;
    });
  }

  void _clearMentionState() {
    _mentionToken = null;
    _mentionMatches = const <MentionEntry>[];
    _mentionIndex = 0;
  }

  /// Escape, or a tap anywhere outside the composer.
  void _closeMention() {
    if (_mentionToken == null) return;
    setState(() {
      _dismissedAt = _mentionToken!.start;
      _clearMentionState();
    });
  }

  void _moveMention(int delta) {
    if (!_mentionOpen) return;
    final int n = _mentionMatches.length;
    setState(() => _mentionIndex = (_mentionIndex + delta + n) % n);
  }

  /// Write the handle into the composer. Setting the value fires the listener,
  /// which finds no open token after the trailing space and closes the picker.
  void _acceptMention(MentionEntry entry) {
    final MentionToken? token = _mentionToken;
    if (token == null) return;
    final MentionEdit edit = applyMention(
      text: _composer.text,
      token: token,
      handle: entry.handle,
    );
    _composer.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection.collapsed(offset: edit.caret),
    );
  }

  /// The composer's keys, read before the text field sees them.
  ///
  /// This node sits between the field and the app's default text shortcuts, so
  /// what it handles never reaches them: with the picker open Enter picks a
  /// handle instead of sending — the one failure mode worth the extra node.
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (!_mentionOpen) return KeyEventResult.ignored;
      _closeMention();
      return KeyEventResult.handled;
    }
    if (_mentionOpen) {
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveMention(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveMention(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.tab) {
        _acceptMention(_mentionMatches[_mentionIndex]);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // Picker closed: plain Enter sends, Shift+Enter still writes a newline.
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The soft keyboard's action key. It never reaches [_onComposerKey], so it
  /// has to make the same choice: accept a highlighted handle, else send.
  void _onSubmitted() {
    if (_mentionOpen) {
      _acceptMention(_mentionMatches[_mentionIndex]);
      return;
    }
    _send();
  }

  void _onInbound(AgentsRelayInbound event) {
    if (!mounted) return;
    switch (event) {
      case AgentsRelayRoomTurn(
        :final roomId,
        :final round,
        :final agentId,
        :final handle,
        :final text,
      ):
        if (roomId != widget.roomId) break; // another room on the same socket
        setState(() {
          _turns.add(
            AgentsRoomTurn(
              round: round,
              agentId: agentId,
              handle: handle,
              text: text,
            ),
          );
        });
      case AgentsRelayRoomHistory(:final roomId, :final turns):
        if (roomId != widget.roomId) break;
        setState(() {
          // History replaces the view: it is the last exchange, and it is over.
          _turns
            ..clear()
            ..addAll(
              turns.map(
                (t) => AgentsRoomTurn(
                  round: t.round,
                  agentId: t.agentId,
                  handle: t.handle,
                  text: t.text,
                ),
              ),
            );
          if (_turns.isNotEmpty) _running = false;
        });
      case AgentsRelayRoomDone(:final roomId, :final reason):
        if (roomId != widget.roomId) break;
        setState(() {
          _stop = AgentsRoomStop.fromWire(reason);
          _running = false;
        });
      default:
        // Not a room event — it belongs to the agent thread, not here.
        break;
    }
  }

  void _onStreamClosed() {
    // The controller's inbound stream closed — the socket was rebuilt (a
    // reconnect on a changing network). This page is bound to the dead stream,
    // so it can receive nothing more; say so plainly rather than hanging on a
    // silent room. Reopening the room binds to the live socket again.
    if (!mounted) return;
    setState(() {
      _disconnected = true;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final thread = RoomThreadView(
      roomName: widget.roomName,
      userMessage: _sentMessage ?? widget.userMessage,
      turns: _turns,
      members: widget.members,
      stop: _stop,
      running: _running,
    );
    final banner = _disconnected ? _reconnectBanner(context) : null;
    if (widget.onSend == null) {
      return banner == null
          ? thread
          : Column(
              children: [
                banner,
                Expanded(child: thread),
              ],
            );
    }
    return Column(
      children: [
        ?banner,
        Expanded(child: thread),
        // One region around the picker and the composer: a tap anywhere else
        // closes the picker, the way a dropdown closes when you look away.
        TapRegion(
          onTapOutside: (_) => _closeMention(),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_mentionOpen) ...[
                    RoomMentionPicker(
                      entries: _mentionMatches,
                      selected: _mentionIndex,
                      onPick: _acceptMention,
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Focus(
                          // Not a stop on the way round the screen: it only
                          // reads the keys the field is about to get.
                          canRequestFocus: false,
                          skipTraversal: true,
                          onKeyEvent: _onComposerKey,
                          child: TextField(
                            controller: _composer,
                            minLines: 1,
                            maxLines: 4,
                            // Once the socket is gone there is nowhere to send:
                            // disable the field so the user is not typing into
                            // a dead room.
                            enabled: !_disconnected,
                            decoration: InputDecoration(
                              hintText: _disconnected
                                  ? 'Reopen the room to send'
                                  : 'Message the room…',
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _onSubmitted(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        icon: const AppIcon(Icons.send),
                        onPressed: _disconnected ? null : _send,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
