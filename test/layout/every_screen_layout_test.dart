/// Every screen and panel, mounted at four window sizes and two text scales,
/// and asked the three questions a layout can fail:
///
///  * did anything throw, and did anything overflow?
///  * does anything paint past the left or right edge?
///  * is every control big enough to hit?
///
/// The catalogue below is the list of surfaces. A screen that cannot be
/// mounted at all is NOT quietly dropped: it is listed in `_cannotMount` with
/// the reason, so the gap is visible instead of looking like a pass.
///
/// The walkers live in `layout_harness.dart`; they name no widget, so a
/// control added tomorrow is measured tomorrow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/agent_profile_edit_page.dart';
import 'package:chuk_chat/pages/agent_profile_page.dart';
import 'package:chuk_chat/pages/automations_page.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/pages/agents_pairing_page.dart';
import 'package:chuk_chat/pages/customization_page.dart';
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/pages/mobile_agents_settings_page.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/pages/secrets_settings_page.dart';
import 'package:chuk_chat/pages/settings/developer_settings_page.dart';
import 'package:chuk_chat/pages/settings/embedding_settings_page.dart';
import 'package:chuk_chat/pages/settings/herenow_settings_page.dart';
import 'package:chuk_chat/pages/settings/mcp_connectors_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/usage_details_page.dart';
import 'package:chuk_chat/pages/workspace_management_page.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_sheet.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/browser_view_page.dart';
import 'package:chuk_chat/widgets/chat_documents_panel.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/widgets/messenger_context_menu.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/widgets/room_create_sheet.dart';
import 'package:chuk_chat/widgets/room_list_view.dart';
import 'package:chuk_chat/widgets/room_members_sheet.dart';

import '../support/fake_relay_controller.dart';
import '../support/shell_config.dart';
import 'layout_harness.dart';

/// Screens left out of the sweep, and why. Never delete a line here to make
/// the sweep look complete.
const Map<String, String> _cannotMount = <String, String>{
  'model_selector_page': 'its initState reaches SupabaseService.client, which '
      'throws "call SupabaseService.initialize() first". The throw escapes as '
      'an unhandled async error, so the screen never reaches a frame worth '
      'measuring. It is also on this task\'s do-not-touch list.',
  'messenger_shell / agents_thread_view': 'the whole live chat stack (relay, '
      'storage, streaming). Covered by its own tests in test/widgets/.',
  'fullscreen_map_page': 'needs a tile provider and a network map surface.',
  'recover_chats_page': 'reads PasswordResetService, which reaches through '
      'SupabaseService.client. That client is gated behind a private '
      '_initialized flag that only SupabaseService.initialize() sets, and that '
      'call needs real credentials — there is no test seam.',
  'credit_display / credit_badge / balance_badge': 'all three mount the same '
      'mixin, which opens a Supabase realtime channel. Its reconnect timers '
      'outlive the widget tree, so the binding fails the test on pending '
      'timers whatever the layout does.',
};

/// Anything a screen made that has to be thrown away afterwards.
class _Bag {
  final List<void Function()> _disposers = <void Function()>[];

  T keep<T>(T value, void Function() dispose) {
    _disposers.add(dispose);
    return value;
  }

  void dispose() {
    for (final void Function() d in _disposers.reversed) {
      d();
    }
    _disposers.clear();
  }
}

// ignore: library_private_types_in_public_api
FakeAgentControlSource _keepControl(_Bag bag, FakeAgentControlSource source) {
  bag.keep(source, source.dispose);
  return source;
}

// ignore: library_private_types_in_public_api
typedef ScreenBuilder = Widget Function(_Bag bag);

class _Screen {
  const _Screen(this.name, this.build, {this.after});

  final String name;
  final ScreenBuilder build;

  /// Runs after the first frames, for a surface that only exists once it is
  /// opened (a menu, a dialog).
  final Future<void> Function(WidgetTester tester)? after;
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

AgentsAgent _agent({
  String id = 'amber',
  String name = 'Amber Fitzgerald-Okonkwo',
  String? role = 'Research and long-form writing',
  bool running = true,
}) => AgentsAgent(
  id: id,
  name: name,
  role: role,
  brief: 'Reads the week and writes the Monday memo.',
  running: running,
  lastActivity: DateTime(2026, 1, 5, 14, 3),
  threads: <AgentsThreadInfo>[
    AgentsThreadInfo(key: '$id-main', title: 'General'),
    AgentsThreadInfo(key: '$id-memo', title: 'Monday memo'),
  ],
);

List<AgentsAgent> _roster() => <AgentsAgent>[
  _agent(),
  _agent(id: 'cobalt', name: 'Cobalt', role: 'Ops', running: false),
  _agent(id: 'jade', name: 'Jade', role: 'Design', running: false),
  _agent(id: 'onyx', name: 'Onyx', role: 'Finance', running: false),
];

AgentsRoomMember _member(String id, String handle) =>
    AgentsRoomMember(agentId: id, handle: handle);

/// A room at the cap, which is the case the member sheet has to survive.
AgentsRoom _fullRoom() => AgentsRoom(
  id: 'r1',
  name: 'Launch week war room',
  members: <AgentsRoomMember>[
    _member('a', 'amber'),
    _member('b', 'cobalt'),
    _member('c', 'jade'),
    _member('d', 'onyx'),
    _member('e', 'saffron'),
    _member('f', 'indigo'),
  ],
);

/// Wraps a panel that has no scaffold of its own.
Widget _hosted(Widget child) => Scaffold(body: SafeArea(child: child));

/// Presents [builder] the way `agents_shell_state` presents it: a scroll
/// controlled modal bottom sheet. The sheet's own constraints are what the
/// content has to live inside, so mounting it flat would test a window the
/// user never sees.
Widget _sheetHost(WidgetBuilder builder) => Scaffold(
  body: Builder(
    builder: (BuildContext context) => Center(
      child: TextButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: builder,
        ),
        child: const Text('Open'),
      ),
    ),
  ),
);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// the catalogue
// ---------------------------------------------------------------------------

List<_Screen> _screens() => <_Screen>[
  // -- pages ---------------------------------------------------------------
  _Screen('settings_page', (_) => SettingsPage(config: testShellConfig())),
  _Screen('theme_page', (_) => ThemePage(config: testShellConfig())),
  _Screen('customization_page',
      (_) => CustomizationPage(config: testShellConfig())),
  _Screen('account_settings_page', (_) => const AccountSettingsPage()),
  _Screen('about_page', (_) => const AboutPage()),
  _Screen('secrets_settings_page', (_) => const SecretsSettingsPage()),
  _Screen('skills_settings_page', (_) => const SkillsSettingsPage()),
  _Screen('automations_page', (_) => const AutomationsPage()),
  _Screen('login_page', (_) => const LoginPage()),
  _Screen('agents_pairing_page',
      (_) => const AgentsPairingPage(cameraAvailable: false)),
  _Screen('coming_soon_page', (_) => const ComingSoonPage(
        title: 'Workspaces',
        message: 'Not on the phone yet. The host still owns this one.',
      )),
  _Screen('pricing_page', (_) => const PricingPage()),
  _Screen('usage_details_page', (_) => const UsageDetailsPage()),
  _Screen('workspace_management_page',
      (_) => const WorkspaceManagementPage(workspaceId: 'ws-1')),
  _Screen('desktop_settings_modal',
      (_) => Scaffold(body: DesktopSettingsModal(config: testShellConfig()))),
  _Screen('settings/developer_settings_page',
      (_) => const DeveloperSettingsPage()),
  _Screen('settings/embedding_settings_page',
      (_) => const EmbeddingSettingsPage()),
  _Screen('settings/herenow_settings_page', (_) => const HereNowSettingsPage()),
  _Screen('settings/mcp_connectors_page', (_) => const McpConnectorsPage()),
  _Screen('agent_profile_page', (_Bag bag) {
    final LocalAgentRosterSource source = LocalAgentRosterSource(
      seed: _roster(),
    );
    bag.keep(source, source.dispose);
    final AgentProfileStore profiles = AgentProfileStore();
    bag.keep(profiles, profiles.dispose);
    return AgentProfilePage(
      agentId: 'amber',
      source: source,
      profiles: profiles,
      onRename: (_) {},
      onDelete: (_) {},
      onOpenControls: () {},
      onOpenBrowser: () {},
      onMessage: () {},
    );
  }),
  _Screen('agent_profile_edit_page', (_Bag bag) {
    final LocalAgentRosterSource source = LocalAgentRosterSource(
      seed: _roster(),
    );
    bag.keep(source, source.dispose);
    final AgentProfileStore profiles = AgentProfileStore();
    bag.keep(profiles, profiles.dispose);
    return AgentProfileEditPage(
      agent: _agent(),
      source: source,
      profiles: profiles,
      onRename: (_) {},
    );
  }),
  _Screen('mobile_agents_settings_page', (_Bag bag) {
    final LocalAgentRosterSource source = LocalAgentRosterSource(
      seed: _roster(),
    );
    bag.keep(source, source.dispose);
    final AgentProfileStore profiles = AgentProfileStore();
    bag.keep(profiles, profiles.dispose);
    final MobileChatPreferences prefs = MobileChatPreferences();
    bag.keep(prefs, prefs.dispose);
    return MobileAgentsSettingsPage(
      agentId: 'amber',
      source: source,
      profiles: profiles,
      preferences: prefs,
      onEdit: () {},
      onControls: () {},
      onModel: () {},
      onAutomations: () {},
      onSkills: () {},
      onConnectors: () {},
      onSecrets: () {},
      onRooms: () {},
      onSettings: () {},
      onDocuments: () {},
      onCopyChat: () {},
      onBrowser: () {},
      onDelete: () {},
      onChat: () {},
    );
  }),

  // -- the mobile layer ----------------------------------------------------
  _Screen('mobile/mobile_agent_list', (_Bag bag) {
    final LocalAgentRosterSource source = LocalAgentRosterSource(
      seed: _roster(),
    );
    bag.keep(source, source.dispose);
    return _hosted(
      MobileAgentList(
        source: source,
        onSelect: (_, _) {},
        selectedAgentId: 'amber',
        accountLabel: 'chuk@example.com',
        onAddAgent: () {},
        onOpenAccount: () {},
        onOpenProfile: (_) {},
        onRenameAgent: (_) {},
        onDeleteAgent: (_) {},
        now: () => DateTime(2026, 1, 5, 15),
      ),
    );
  }),
  _Screen('mobile/mobile_agent_sheet', (_) => _hosted(
        MobileAgentSheet(
          agent: _agent(),
          onProfile: () {},
          onControls: () {},
          onRename: () {},
          onRooms: () {},
          onCopyChat: () {},
          onSettings: () {},
          onSignOut: () {},
        ),
      )),
  _Screen('mobile/mobile_chat_chrome', (_) => _hosted(
        MobileChatChrome(
          agent: _agent(),
          onBack: () {},
          onOpenProfile: () {},
          onOpenFiles: () {},
          onOpenBrowser: () {},
          browserAvailable: true,
          onReconnect: () {},
          onMore: () {},
        ),
      )),
  _Screen('mobile/mobile_chat_screen', (_) => MobileChatScreen(
        agent: _agent(),
        onBack: () {},
        onOpenProfile: () {},
        onOpenFiles: () {},
        onMore: () {},
        bodyBuilder: (BuildContext context, double topInset) => ListView(
          padding: EdgeInsets.only(top: topInset),
          children: const <Widget>[
            Padding(
              padding: EdgeInsets.all(16),
              child: Text('A message from the coworker'),
            ),
          ],
        ),
      )),

  // -- panels and sheets ---------------------------------------------------
  _Screen('widgets/chat_documents_panel', (_Bag bag) {
    final FakeRelayController relay = FakeRelayController();
    bag.keep(relay, relay.dispose);
    return _hosted(
      ChatDocumentsPanel(
        sessionKey: 'amber-main',
        controller: relay,
        coworkerName: 'Amber',
      ),
    );
  }),
  _Screen('widgets/agent_control_panel', (_Bag bag) {
    final FakeAgentControlSource source = _keepControl(
      bag,
      FakeAgentControlSource(
        initial: const AgentControlSnapshot(
          model: ControlAvailable<AgentModelChoice>(
            AgentModelChoice(
              id: 'anthropic/claude-sonnet-4-5-20260101',
              provider: 'anthropic',
              reasoningEffort: 'medium',
            ),
          ),
          tokens: ControlAvailable<AgentTokenUsage>(
            AgentTokenUsage(total: 12345678, runs: 31, lastRun: 54321),
          ),
          runtime: ControlAvailable<AgentSessionRuntime>(
            AgentSessionRuntime(
              active: Duration(hours: 3, minutes: 4, seconds: 2),
              runs: 31,
              running: true,
              current: Duration(seconds: 9),
            ),
          ),
          sandbox: ControlAvailable<AgentSandbox>(
            AgentSandbox(
              kind: 'docker',
              container: 'agents-amber-0a1b2c3d',
              containerId: 'deadbeef0011',
              workspace: '/home/chuk/.agents/agents/amber/workspace',
            ),
          ),
          skills: ControlAvailable<List<AgentSkill>>(<AgentSkill>[
            AgentSkill(
              name: 'deep-research',
              description: 'Reads the web and writes a brief.',
              enabled: true,
            ),
            AgentSkill(
              name: 'youtube-transcript',
              description: 'Pulls a transcript from a video.',
              enabled: false,
            ),
          ]),
        ),
      ),
    );
    return _hosted(
      AgentControlPanel(agent: _agent(id: 'host:amber'), source: source),
    );
  }),
  _Screen(
    'widgets/room_members_sheet (full room)',
    (_) => _sheetHost(
      (BuildContext context) => RoomMembersSheet(
        room: _fullRoom(),
        candidates: const <AgentsAgent>[],
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ),
    after: _openSheet,
  ),
  _Screen(
    'widgets/room_members_sheet (room of two, roster waiting)',
    (_) => _sheetHost(
      (BuildContext context) => RoomMembersSheet(
        room: AgentsRoom(
          id: 'r2',
          name: 'ops',
          members: <AgentsRoomMember>[
            _member('a', 'amber'),
            _member('b', 'cobalt'),
          ],
        ),
        candidates: _roster(),
        onAdd: (_) {},
        onRemove: (_) {},
      ),
    ),
    after: _openSheet,
  ),
  _Screen(
    'widgets/room_create_sheet',
    (_) => _sheetHost(
      (BuildContext context) =>
          RoomCreateSheet(agents: _roster(), onSubmit: (_) {}, onCancel: () {}),
    ),
    after: _openSheet,
  ),
  _Screen('widgets/room_list_view', (_Bag bag) {
    final LocalRoomSource source = LocalRoomSource();
    bag.keep(source, source.dispose);
    source.addRoom(AgentsRoomDraft(
      name: 'Launch week war room',
      members: <AgentsRoomMember>[
        _member('a', 'amber'),
        _member('b', 'cobalt'),
        _member('c', 'jade'),
        _member('d', 'onyx'),
        _member('e', 'saffron'),
        _member('f', 'indigo'),
      ],
    ));
    source.addRoom(AgentsRoomDraft(
      name: 'ops',
      members: <AgentsRoomMember>[_member('a', 'amber'), _member('b', 'cobalt')],
    ));
    return _hosted(
      RoomListView(
        source: source,
        onSelect: (_) {},
        onCreate: () {},
        onDelete: (_) {},
        onRename: (_, _) {},
        onManageMembers: (_) {},
      ),
    );
  }),
  // With no account behind it the dropdown has no catalogue, so this is the
  // empty state — which is exactly the state a signed-out phone shows.
  _Screen('widgets/model_selection_dropdown', (_Bag bag) {
    final FocusNode node = FocusNode();
    bag.keep(node, node.dispose);
    return _hosted(
      Align(
        alignment: Alignment.topLeft,
        child: ModelSelectionDropdown(
          initialSelectedModelId: 'anthropic/claude-sonnet-4-5',
          onModelSelected: (_) {},
          textFieldFocusNode: node,
        ),
      ),
    );
  }),
  _Screen('widgets/chat_mode_selector', (_) => _hosted(
        Align(
          alignment: Alignment.topLeft,
          child: ChatModeSelector(
            mode: ChatMode.thinking,
            onModeChanged: (_) {},
            onModelSelected: (_) {},
            onOpenModelScreen: () {},
            selectedModelId: 'anthropic/claude-sonnet-4-5',
            modelLabel: 'Claude Sonnet 4.5',
            reasoningEffort: 'medium',
            reasoningLevels: const <String>['off', 'low', 'medium', 'high'],
            onReasoningEffortChanged: (_) {},
          ),
        ),
      )),
  _Screen('widgets/attachment_preview_bar', (_) => _hosted(
        Align(
          alignment: Alignment.topLeft,
          child: AttachmentPreviewBar(
            files: <AttachedFile>[
              AttachedFile(
                id: 'doc',
                fileName: 'quarterly-review-notes.txt',
                fileSizeBytes: 2048,
                markdownContent: 'hello',
              ),
              AttachedFile(
                id: 'img',
                fileName: 'screenshot.png',
                fileSizeBytes: 40960,
                isImage: true,
              ),
            ],
            onRemove: (_) {},
            onCopy: (_) async {},
          ),
        ),
      )),
  _Screen('widgets/browser_view_page', (_Bag bag) {
    final FakeRelayController relay = FakeRelayController();
    bag.keep(relay, relay.dispose);
    return BrowserViewPage(controller: relay);
  }),
  _Screen(
    'widgets/messenger_context_menu',
    (_) => Scaffold(
      body: Builder(
        builder: (BuildContext context) => Center(
          child: TextButton(
            onPressed: () => showMessengerContextMenu(
              context: context,
              anchor: const Rect.fromLTWH(20, 150, 280, 100),
              preview: const Text('A message long enough to wrap once or twice'),
              canEdit: true,
              canReply: true,
              isUser: true,
              canReact: true,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
    after: (WidgetTester tester) async {
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    },
  ),
];

// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsRelayLink.instance.reset();
  });
  tearDown(() => AgentsRelayLink.instance.reset());

  test('the screens this sweep cannot mount are named, with the reason', () {
    expect(_cannotMount, isNotEmpty);
  });

  // A sweep that cannot fail proves nothing. This plants one of each fault
  // and insists the walkers see it.
  testWidgets('the walkers catch a planted fault', (WidgetTester tester) async {
    final List<FlutterErrorDetails> planted = <FlutterErrorDetails>[];
    final List<FlutterErrorDetails> errors = await collectErrors(() async {
      await pumpAt(
        tester,
        Scaffold(
          body: Column(
            children: <Widget>[
              // 1. a row wider than the window: overflow AND a box past the
              //    right edge.
              Row(
                children: <Widget>[
                  Container(width: 900, height: 20, color: Colors.red),
                ],
              ),
              // 2. a control far too small to hit.
              InkWell(
                onTap: () {},
                child: const SizedBox(width: 24, height: 24),
              ),
              // 3. writing nobody can read.
              const Text('tiny', style: TextStyle(fontSize: 6)),
            ],
          ),
        ),
        size: const Size(360, 800),
        textScale: 1.0,
      );

      expect(
        findHorizontalBleed(tester, const Size(360, 800)),
        isNotEmpty,
        reason: 'the 900 dp box was not seen leaving the window',
      );
      expect(
        findSmallTargets(tester).map((SmallTarget t) => t.size),
        contains(const Size(24, 24)),
      );
      expect(
        findTinyText(tester).map((TinyText t) => t.text),
        contains('tiny'),
      );
      await unpump(tester);
    });
    planted.addAll(errors.where(isOverflow));
    expect(planted, isNotEmpty, reason: 'the overflow was not seen');
  });

  for (final _Screen screen in _screens()) {
    for (final LayoutSize window in kLayoutSizes) {
      testWidgets('${screen.name} @ ${window.name}', (WidgetTester tester) async {
        for (final double scale in kTextScales) {
          final _Bag bag = _Bag();
          late List<Bleed> bleed;
          late List<SmallTarget> small;
          late List<TinyText> tiny;

          final List<FlutterErrorDetails> errors = await collectErrors(() async {
            await pumpAt(
              tester,
              screen.build(bag),
              size: window.size,
              textScale: scale,
            );
            await screen.after?.call(tester);
            bleed = findHorizontalBleed(tester, window.size);
            small = findSmallTargets(tester);
            tiny = findTinyText(tester);
            await unpump(tester);
          });
          bag.dispose();

          final String where = '${screen.name} @ $window @ text x$scale';
          expect(
            errors.where(isOverflow),
            isEmpty,
            reason: '$where overflowed:\n  ${describeErrors(errors)}',
          );
          expect(
            errors,
            isEmpty,
            reason: '$where threw:\n  ${describeErrors(errors)}',
          );
          expect(tester.takeException(), isNull, reason: where);
          expect(
            bleed,
            isEmpty,
            reason: '$where paints past the edge:\n  ${bleed.join('\n  ')}',
          );
          expect(
            small,
            isEmpty,
            reason: '$where has controls under 48 dp:\n  ${small.join('\n  ')}',
          );
          expect(
            tiny,
            isEmpty,
            reason: '$where has text under $kMinFontSize px:'
                '\n  ${tiny.join('\n  ')}',
          );
        }
      });
    }
  }
}
