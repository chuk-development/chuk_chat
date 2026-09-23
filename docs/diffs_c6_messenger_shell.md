# Diff proposal for `app/lib/pages/messenger_shell.dart` (owner: cowork-5c)

From cowork-c6 (mobile layer). Mounts the Grok-Bot phone layout on narrow
windows. Everything it calls already exists in the shell; the new widgets are
in `app/lib/platform_specific/mobile/` (analyze 0, tests green).
`AgentsThreadView` already has `topInset` and `phoneLayout` (c6 set them).

## Imports (add)

```dart
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_sheet.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
```

## build(): the `thread` local becomes a builder

Replace

```dart
        final thread = AgentsThreadView(
          key: _threadViewKey,
          ...
          onOpenModelScreen: _openModelScreen,
        );
```

with

```dart
        // One builder for both layouts. The GlobalKey keeps the live thread
        // view (and its socket) alive when the layout flips; the phone layout
        // only adds the floating-bar inset and forces chuk's phone screen.
        AgentsThreadView buildThread({double topInset = 0, bool phone = false}) =>
            AgentsThreadView(
              key: _threadViewKey,
              controllerBuilder: widget.relayControllerBuilder ??
                  () => _buildRelayController(_pairingStore),
              sessionSource: widget.sessionSource,
              pairingStore: _pairingStore,
              threadKey: _selectedThreadKey,
              onPaired: _onPaired,
              onRunStateChanged: (threadKey, running) {
                final agentId = _agentIdForThread(threadKey);
                if (agentId != null) _roster.markRunning(agentId, running);
              },
              onActivity: (threadKey, when) {
                final agentId = _agentIdForThread(threadKey);
                if (agentId != null) {
                  _roster.markActivity(agentId, threadKey, when);
                }
              },
              onController: _onController,
              onOpenModelScreen: _openModelScreen,
              topInset: topInset,
              phoneLayout: phone,
            );
        final thread = buildThread();
        final phone = !wide && MobileLayout.isPhoneWidth(constraints.maxWidth);
        final agent = _selectedAgent;
```

## build(): the Scaffold

Replace

```dart
        return Scaffold(
          key: _scaffoldKey,
          appBar: _buildAppBar(context, wide),
          endDrawer: _buildControlDrawer(context),
          body: wide
              ? Row(...)
              : IndexedStack(
                  index: _showThreadOnNarrow ? 1 : 0,
                  children: [roster, thread],
                ),
        );
```

with

```dart
        return Scaffold(
          key: _scaffoldKey,
          // A phone has no app bar: the mobile chrome floats over the chat and
          // the home list carries its own chips (Grok Bot).
          appBar: phone ? null : _buildAppBar(context, wide),
          endDrawer: _buildControlDrawer(context),
          body: wide
              ? Row(...)                                   // unchanged
              : phone
                  ? _buildPhoneBody(context, buildThread, agent)
                  : IndexedStack(                          // unchanged (tablet)
                      index: _showThreadOnNarrow ? 1 : 0,
                      children: [roster, thread],
                    ),
        );
```

## New method

```dart
  /// The phone layout (docs/MOBILE_GROKBOT_STRUCTURE.md): the coworker list as
  /// an inbox, the chat with the floating chrome on top. Back (chip, system
  /// back, edge swipe) flips the same flag the tablet path uses.
  Widget _buildPhoneBody(
    BuildContext context,
    AgentsThreadView Function({double topInset, bool phone}) buildThread,
    AgentsAgent? agent,
  ) {
    if (_showThreadOnNarrow && agent != null) {
      return MobileChatScreen(
        agent: agent,
        onBack: () => setState(() => _showThreadOnNarrow = false),
        onOpenProfile: () => _scaffoldKey.currentState?.openEndDrawer(),
        onOpenBrowser: _openBrowserView,
        onMore: () => MobileAgentSheet.show(
          context,
          agent: agent,
          onControls: () => _scaffoldKey.currentState?.openEndDrawer(),
          onRooms: _openRooms,
          onCopyChat: _copyFullChat,
          onSettings: _openSettings,
          onSignOut: widget.onSignOut ?? () => const AuthService().signOut(),
        ),
        bodyBuilder: (context, topInset) =>
            buildThread(topInset: topInset, phone: true),
      );
    }
    // CORRECTED by cowork-5c: the thread view must stay mounted on the inbox
    // screen too. It owns the relay controller (reconnect at bootstrap,
    // onPaired → host agent in the roster, adoption of a run in flight).
    // Off-stage under the list, like chuk's root wrapper keeps its chat.
    return Stack(
      children: [
        Positioned.fill(child: Offstage(child: buildThread(phone: true))),
        Positioned.fill(
          child: MobileAgentList(
            source: _roster,
            selectedAgentId: _selectedAgentId,
            onSelect: _select,
            onAddAgent: _openOnboarding,
            onOpenAccount: _openSettings,
            // Optional: the signed-in user's name/e-mail for the monogram
            // chip; null shows a person icon.
            accountLabel: null,
          ),
        ),
      ],
    );
  }
```

Status: APPLIED by cowork-5c (with the correction above). Tests added by 5c:
"a phone window shows the inbox, then the chat, and back again" (420 px) and
a tablet test (660 px).

Notes for 5c:
- `_select` already sets `_showThreadOnNarrow = true`, so a row tap opens the chat.
- The end drawer (`AgentControlPanel`) stays as the bot "profile" for now; a
  bottom sheet can replace it later.
- The `IndexedStack` tablet path and the wide `Row` are untouched.
- Tests: `messenger_shell_test` pumps a narrow window (< 600) → it now renders
  `MobileAgentList` instead of `AgentRosterView`; a test that looks for the
  `AppBar` title or the roster tiles on narrow needs `MobileAgentRow`
  (`ValueKey('mobile-agent-<id>')`) or a wider window. Send me the red ones.
