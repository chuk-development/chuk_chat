// The scene list of the screenshot gallery (test_screenshots/gallery_test.dart).
//
// Every scene is one app surface, built from the app's own widgets with staged
// data: no Supabase, no network, no device storage. The gallery renders each
// scene in four variants (mobile and desktop, light and dark), so a reviewer
// can scan the PNGs and see which screens a change touched.
//
// The fixtures for the settings pages and the Agents surfaces follow the
// catalogue in test/layout/every_screen_layout_test.dart, which proves that
// they mount without a backend. A screen that cannot mount is listed in
// [kGalleryCannotMount] with the reason, so the gap stays visible.
//
// To add a screen: add one GalleryScene to [gallerySceneList]. Keep the order
// stable. The order gives the NN prefix of the file name, and a new scene in
// the middle renames every file after it, which makes the sha256 diff noisy.
// Add new scenes at the end of their group or at the end of the list.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/agent_mail_contacts_page.dart';
import 'package:chuk_chat/pages/agent_mail_detail_page.dart';
import 'package:chuk_chat/pages/agent_mailbox_page.dart';
import 'package:chuk_chat/pages/assistant_settings_page.dart';
import 'package:chuk_chat/pages/automations_page.dart';
import 'package:chuk_chat/pages/customization_page.dart';
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/diagnostics_settings_page.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/pages/secrets_settings_page.dart';
import 'package:chuk_chat/pages/settings/embedding_settings_page.dart';
import 'package:chuk_chat/pages/settings/herenow_settings_page.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/system_prompt_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/tool_calling_settings_page.dart';
import 'package:chuk_chat/pages/usage_details_page.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/chat_composer_box.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/widgets/room_list_view.dart';

import '../../test/support/agent_mail_fake.dart';
import '../../test/support/shell_config.dart';

/// What a scene knows about the variant it renders in.
class GalleryContext {
  GalleryContext({required this.brightness, required this.desktop});

  final Brightness brightness;

  /// True for the 1440x900 desktop variant.
  final bool desktop;

  final List<void Function()> _disposers = <void Function()>[];

  /// Registers [dispose] to run after the capture, and returns [value].
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

typedef GalleryBuilder = Widget Function(GalleryContext ctx);

/// One screen of the gallery.
class GalleryScene {
  const GalleryScene(this.name, this.build, {this.after, this.setUp});

  /// File-name safe: lower case, digits and `-`.
  final String name;
  final GalleryBuilder build;

  /// Runs before the first pump, for static state the screen reads.
  final void Function(GalleryContext ctx)? setUp;

  /// Runs after the first frames, for a surface that only exists once it is
  /// opened (a menu, a sheet).
  final Future<void> Function(WidgetTester tester)? after;
}

/// Screens the gallery leaves out, and why. Do not delete a line here to
/// make the gallery look complete.
const Map<String, String> kGalleryCannotMount = <String, String>{
  'real chat screen (ChukChatUIMobile / ChukChatUIDesktop)': 'needs a live '
      'Supabase session, the local chat cache and the streaming stack. The '
      'chat scenes draw the real MessageBubble and ChatComposerBox in a '
      'staged frame instead.',
  'sidebar (SidebarMobile / SidebarDesktop)': 'initState starts '
      'UpdateCheckService and network listeners whose timers outlive the '
      'widget tree. The chat-list scene draws the seeded chat titles with the '
      'app theme instead.',
  'settings_page': 'reads SupabaseService.auth in initState.',
  'pricing_page': 'mounts CreditDisplay, which opens a Supabase realtime '
      'channel.',
  'workspace_management_page / workspaces_page': 'loads from '
      'WorkspaceStorageService, which has no seam to seed a workspace.',
  'artifact_panel': 'loads versions through ArtifactStorageService, which '
      'reaches Supabase and SQLite.',
  'model_selector_page': 'initState reaches SupabaseService.client.',
  'fullscreen_map_page / <map> blocks': 'need map tiles from the network.',
};

/// The app's default look (the first preset, Aya) for [brightness], i.e. what
/// a new install shows in light or dark mode. The chrome font is Roboto, as
/// in the store harness: the test engine has no platform default font.
ThemeData galleryTheme(Brightness brightness) {
  final ThemeVariant v = kThemePresets.first.variantFor(brightness);
  final ThemeData base = buildAppTheme(
    accent: v.accent,
    iconFg: v.iconFg,
    bg: v.bg,
    brightness: brightness,
    contrast: v.contrast,
  );
  // The theme gives buttons, chips, menus and tooltips a bare TextStyle. On a
  // device that resolves to Roboto; the test engine draws boxes instead.
  ButtonStyle? roboto(ButtonStyle? style) => style?.copyWith(
    textStyle: WidgetStateProperty.resolveWith(
      (Set<WidgetState> states) => (style.textStyle?.resolve(states) ??
              const TextStyle())
          .copyWith(fontFamily: 'Roboto'),
    ),
  );
  TextStyle? r(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'Roboto');

  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'),
    // A bare TextStyle inherits the family from the ambient DefaultTextStyle,
    // which an app bar sets from these two.
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: r(base.appBarTheme.titleTextStyle),
      toolbarTextStyle: r(base.appBarTheme.toolbarTextStyle),
    ),
    filledButtonTheme:
        FilledButtonThemeData(style: roboto(base.filledButtonTheme.style)),
    elevatedButtonTheme:
        ElevatedButtonThemeData(style: roboto(base.elevatedButtonTheme.style)),
    outlinedButtonTheme:
        OutlinedButtonThemeData(style: roboto(base.outlinedButtonTheme.style)),
    textButtonTheme:
        TextButtonThemeData(style: roboto(base.textButtonTheme.style)),
    segmentedButtonTheme: base.segmentedButtonTheme.copyWith(
      style: roboto(base.segmentedButtonTheme.style),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: r(base.chipTheme.labelStyle),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      textStyle: r(base.popupMenuTheme.textStyle),
    ),
    tooltipTheme: base.tooltipTheme.copyWith(
      textStyle: r(base.tooltipTheme.textStyle),
    ),
  );
}

// ---------------------------------------------------------------------------
// staged chat
// ---------------------------------------------------------------------------

/// A chat screen around [children]: header, message list, the real composer.
/// On desktop the column is centred at the width the desktop chat uses.
class _ChatFrame extends StatelessWidget {
  const _ChatFrame({
    required this.ctx,
    required this.title,
    required this.children,
  });

  final GalleryContext ctx;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final Widget column = Column(
      children: <Widget>[
        Expanded(
          child: children.isEmpty
              ? Center(
                  child: Text(
                    'How can I help you today?',
                    style: theme.textTheme.headlineSmall,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  physics: const NeverScrollableScrollPhysics(),
                  children: children,
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ChatComposerBox(
            field: const TextField(
              decoration: InputDecoration(
                hintText: 'Ask anything',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
            actions: <Widget>[
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.attach_file_rounded),
              ),
              ChatModeSelector(
                mode: ChatMode.thinking,
                onModeChanged: (_) {},
                onModelSelected: (_) {},
                onOpenModelScreen: () {},
                selectedModelId: 'deepseek/deepseek-v4-pro-0813',
                modelLabel: 'DeepSeek V4 Pro',
                reasoningEffort: 'medium',
                reasoningLevels: const <String>['off', 'low', 'medium', 'high'],
                onReasoningEffortChanged: (_) {},
              ),
              const Spacer(),
              IconButton.filled(
                onPressed: () {},
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const Icon(Icons.menu_rounded),
        title: Text(title, style: theme.textTheme.titleMedium),
        actions: const <Widget>[
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Icon(Icons.edit_square),
          ),
        ],
      ),
      body: SafeArea(
        child: ctx.desktop
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: column,
                ),
              )
            : column,
      ),
    );
  }
}

MessageBubble _user(String text) => MessageBubble(message: text, isUser: true);

MessageBubble _assistant(
  List<ContentBlock> blocks, {
  String modelLabel = 'DeepSeek V4 Pro',
  String? reasoning,
  double? tps,
  Duration? workedFor,
}) => MessageBubble(
  message: '',
  isUser: false,
  contentBlocks: blocks,
  modelLabel: modelLabel,
  reasoning: reasoning,
  workedFor: workedFor,
  showModelInfo: true,
  showTps: tps != null,
  showReasoningTokens: reasoning != null,
  tps: tps,
);

Widget _chat(GalleryContext ctx, String title, List<Widget> children) =>
    _ChatFrame(ctx: ctx, title: title, children: children);

const String _markdownAnswer =
    '## Rust or Go\n\n'
    '**Rust** when you have hard latency limits or cannot afford a garbage '
    'collector. **Go** when throughput and shipping speed matter.\n\n'
    '| | Rust | Go |\n'
    '|---|---|---|\n'
    '| GC | no | yes |\n'
    '| Build time | slow | fast |\n'
    '| Generics | yes | yes |\n\n'
    '1. Pick the latency budget first.\n'
    '2. Then pick the language.\n\n'
    '> A REST API is almost always Go.\n\n'
    '```rust\n'
    'let total: u64 = items\n'
    '    .par_iter()\n'
    '    .map(|i| i.weight)\n'
    '    .sum();\n'
    '```';

const String _chartAnswer =
    'The Bitcoin price over the last 7 days:\n\n'
    '<chart>{"type":"line","title":"BTC / EUR","labels":["Mon","Tue","Wed",'
    '"Thu","Fri","Sat","Sun"],"datasets":[{"label":"Close","data":[61200,'
    '62050,61780,63410,64020,63550,64880]}]}</chart>\n\n'
    'Up 6 % over the week.';

const String _barChartAnswer =
    '<chart>{"type":"bar","title":"Tokens per day","labels":["Mon","Tue",'
    '"Wed","Thu","Fri"],"datasets":[{"label":"Input","data":[120,180,90,240,'
    '160]},{"label":"Output","data":[60,75,40,110,80]}]}</chart>';

/// The forecast days are relative to today, so the card reads "Today" /
/// "Tomorrow" on every run and the PNG hash stays stable. A third day would
/// show a weekday name, which changes every day.
String _weatherAnswer() {
  String day(int offset) => DateTime.now()
      .add(Duration(days: offset))
      .toIso8601String()
      .substring(0, 10);
  return
    '<weather>{"location":"Kiel, DE","current":{"temp":14,"feels_like":12,'
    '"condition":"Partly cloudy","code":2,"unit_temp":"C","humidity":71,'
    '"wind_speed":18,"wind_dir":"SW","unit_wind":"km/h","precipitation":0.2,'
    '"unit_precip":"mm"},"hourly":[{"time":"13:00","temp":14,"code":2,'
    '"precip_prob":10},{"time":"14:00","temp":15,"code":1,"precip_prob":5},'
    '{"time":"15:00","temp":15,"code":3,"precip_prob":20},{"time":"16:00",'
    '"temp":13,"code":61,"precip_prob":60}],"daily":[{"date":"${day(0)}",'
    '"code":2,"temp_max":15,"temp_min":8,"precip_prob":20},{"date":'
    '"${day(1)}","code":61,"temp_max":12,"temp_min":7,"precip_prob":80}]}'
    '</weather>';
}

const String _openUiAnswer =
    'Here is the comparison:\n\n'
    '```openui-lang\n'
    'root = Card([t, b])\n'
    't = TextContent("Rust has no garbage collector. Go builds faster.")\n'
    'b = Button("Show benchmarks")\n'
    '```';

ToolCall _webSearch() => ToolCall(
  id: 'call_1',
  name: 'web_search',
  arguments: const <String, dynamic>{'query': 'WebGPU changes this week'},
  status: ToolCallStatus.completed,
  result:
      '1. WebGPU compute pipeline caching lands\n'
      '   https://developer.chrome.com/webgpu\n'
      '2. Firefox ships WebGPU on Linux\n'
      '   https://hacks.mozilla.org/webgpu\n',
);

// ---------------------------------------------------------------------------
// chat list
// ---------------------------------------------------------------------------

const List<String> _chatTitles = <String>[
  'Rust vs. Go',
  'Weather in Kiel',
  'Bitcoin chart',
  'Trip to Lisbon',
  'Fix the CI cache',
  'Birthday gift ideas',
  'SQL window functions',
  'Translate the README',
];

void _seedChats(GalleryContext ctx) {
  final DateTime base = DateTime(2026, 10, 17, 12);
  ChatStorageState.chatsById.clear();
  for (int i = 0; i < _chatTitles.length; i++) {
    final String id = 'gallery-chat-$i';
    ChatStorageState.chatsById[id] = StoredChat.forSidebar(
      id: id,
      createdAt: base.subtract(Duration(hours: i * 9)),
      updatedAt: base.subtract(Duration(hours: i * 9)),
      isStarred: i == 1,
      title: _chatTitles[i],
    );
  }
  ctx.keep<void>(null, ChatStorageState.chatsById.clear);
}

/// The chat titles as the sidebar lists them, read back from the seeded
/// chat store, in the app theme.
class _ChatList extends StatelessWidget {
  const _ChatList();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<StoredChat> chats = ChatStorageState.savedChats;
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: ListView(
        children: <Widget>[
          for (final StoredChat chat in chats)
            ListTile(
              leading: Icon(
                chat.isStarred
                    ? Icons.star_rounded
                    : Icons.chat_bubble_outline_rounded,
              ),
              title: Text(chat.title ?? ''),
              selected: chat.id == 'gallery-chat-0',
              selectedTileColor: theme.colorScheme.secondaryContainer,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Agents fixtures (see test/layout/every_screen_layout_test.dart)
// ---------------------------------------------------------------------------

AgentsAgent _agent({
  String id = 'amber',
  String name = 'Amber',
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
];

AgentsRoomMember _member(String id, String handle) =>
    AgentsRoomMember(agentId: id, handle: handle);

Widget _hosted(Widget child) => Scaffold(body: SafeArea(child: child));

Widget _mailDetail(String id) {
  final FakeAgentMailServer server = FakeAgentMailServer();
  return AgentMailDetailPage(
    summary: server.summaryOf(id),
    service: server.service(),
  );
}

// ---------------------------------------------------------------------------
// the list
// ---------------------------------------------------------------------------

List<GalleryScene> gallerySceneList() => <GalleryScene>[
  // -- chat ----------------------------------------------------------------
  GalleryScene('chat-empty', (GalleryContext ctx) => _chat(ctx, 'New chat',
      const <Widget>[])),
  GalleryScene('chat-markdown-code', (GalleryContext ctx) => _chat(
        ctx,
        'Rust vs. Go',
        <Widget>[
          _user('When should I pick Rust over Go?'),
          const SizedBox(height: 8),
          _assistant(
            const <ContentBlock>[ContentBlock.text(_markdownAnswer)],
            tps: 84.2,
          ),
        ],
      )),
  GalleryScene('chat-tool-call', (GalleryContext ctx) => _chat(
        ctx,
        'Web research',
        <Widget>[
          _user('What changed in WebGPU this week?'),
          const SizedBox(height: 8),
          _assistant(
            <ContentBlock>[
              ContentBlock.toolCalls(<ToolCall>[_webSearch()]),
              const ContentBlock.text(
                'Two things this week:\n\n'
                '- Chrome now caches compiled compute pipelines.\n'
                '- Firefox ships WebGPU on Linux, on the Vulkan backend.',
              ),
            ],
            modelLabel: 'GLM 5.3 Flash',
            workedFor: const Duration(seconds: 7),
          ),
        ],
      )),
  GalleryScene('chat-reasoning', (GalleryContext ctx) => _chat(
        ctx,
        'Reasoning',
        <Widget>[
          _user('A train runs 90 minutes at 120 km/h. How far does it get?'),
          const SizedBox(height: 8),
          _assistant(
            const <ContentBlock>[ContentBlock.text('**180 km.**')],
            reasoning: '90 minutes is 1.5 hours. Distance is speed times '
                'time, so 120 * 1.5.',
            tps: 71.9,
          ),
        ],
      )),
  GalleryScene('chat-line-chart', (GalleryContext ctx) => _chat(
        ctx,
        'Bitcoin chart',
        <Widget>[
          _user('Chart the Bitcoin price over the last 7 days'),
          const SizedBox(height: 8),
          _assistant(const <ContentBlock>[ContentBlock.text(_chartAnswer)]),
        ],
      )),
  GalleryScene('chat-bar-chart', (GalleryContext ctx) => _chat(
        ctx,
        'Usage',
        <Widget>[
          _user('Show my token use this week as bars'),
          const SizedBox(height: 8),
          _assistant(const <ContentBlock>[ContentBlock.text(_barChartAnswer)]),
        ],
      )),
  GalleryScene('chat-weather-card', (GalleryContext ctx) => _chat(
        ctx,
        'Weather in Kiel',
        <Widget>[
          _user('Show the weather forecast for Kiel as a weather card'),
          const SizedBox(height: 8),
          _assistant(<ContentBlock>[ContentBlock.text(_weatherAnswer())]),
        ],
      )),
  GalleryScene('chat-openui-view', (GalleryContext ctx) => _chat(
        ctx,
        'OpenUI view',
        <Widget>[
          _user('Compare Rust and Go as a card'),
          const SizedBox(height: 8),
          _assistant(const <ContentBlock>[ContentBlock.text(_openUiAnswer)]),
        ],
      )),
  GalleryScene(
    'chat-list',
    (_) => const _ChatList(),
    setUp: _seedChats,
  ),

  // -- composer parts ------------------------------------------------------
  GalleryScene('model-dropdown', (GalleryContext ctx) {
    final FocusNode node = FocusNode();
    ctx.keep(node, node.dispose);
    return _hosted(
      Align(
        alignment: Alignment.topLeft,
        child: ModelSelectionDropdown(
          initialSelectedModelId: 'deepseek/deepseek-v4-pro-0813',
          onModelSelected: (_) {},
          textFieldFocusNode: node,
        ),
      ),
    );
  }),
  GalleryScene('attachment-preview-bar', (_) => _hosted(
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

  // -- account and settings ------------------------------------------------
  GalleryScene('login', (_) => const LoginPage()),
  GalleryScene('settings-desktop-modal', (GalleryContext ctx) => Scaffold(
        body: DesktopSettingsModal(
          config: testShellConfig(themeMode: ctx.brightness),
        ),
      )),
  GalleryScene('settings-theme', (GalleryContext ctx) =>
      ThemePage(config: testShellConfig(themeMode: ctx.brightness))),
  GalleryScene('settings-customization', (GalleryContext ctx) =>
      CustomizationPage(config: testShellConfig(themeMode: ctx.brightness))),
  GalleryScene('settings-tool-calling', (GalleryContext ctx) =>
      ToolCallingSettingsPage(
        config: testShellConfig(themeMode: ctx.brightness),
      )),
  GalleryScene('settings-account', (_) => const AccountSettingsPage()),
  GalleryScene('settings-system-prompt', (_) => const SystemPromptPage()),
  GalleryScene('settings-assistant', (_) => const AssistantSettingsPage()),
  GalleryScene('settings-skills', (_) => const SkillsSettingsPage()),
  GalleryScene('settings-secrets', (_) => const SecretsSettingsPage()),
  GalleryScene('settings-mcp-connectors', (_) => const McpConnectorsPage()),
  GalleryScene('settings-embedding', (_) => const EmbeddingSettingsPage()),
  GalleryScene('settings-herenow', (_) => const HereNowSettingsPage()),
  GalleryScene('settings-diagnostics', (_) => const DeveloperOptionsPage()),
  GalleryScene('settings-usage', (_) => const UsageDetailsPage()),
  GalleryScene('settings-automations', (_) => const AutomationsPage()),
  GalleryScene('about', (_) => const AboutPage()),

  // -- Agents (= CoWork) ---------------------------------------------------
  GalleryScene('agents-list', (GalleryContext ctx) {
    final LocalAgentRosterSource source = LocalAgentRosterSource(
      seed: _roster(),
    );
    ctx.keep(source, source.dispose);
    final LocalRoomSource rooms = LocalRoomSource();
    ctx.keep(rooms, rooms.dispose);
    rooms.addRoom(AgentsRoomDraft(
      name: 'Launch week',
      members: <AgentsRoomMember>[
        _member('a', 'amber'),
        _member('b', 'cobalt'),
        _member('c', 'jade'),
      ],
    ));
    return _hosted(
      MobileAgentList(
        source: source,
        rooms: rooms,
        onOpenRoom: (_) {},
        onCreateRoom: () {},
        onSelect: (_, _) {},
        selectedAgentId: 'amber',
        accountLabel: 'demo@example.com',
        onAddAgent: () {},
        onOpenAccount: () {},
        onOpenProfile: (_) {},
        onRenameAgent: (_) {},
        onDeleteAgent: (_) {},
        now: () => DateTime(2026, 1, 5, 15),
      ),
    );
  }),
  GalleryScene('agents-rooms', (GalleryContext ctx) {
    final LocalRoomSource source = LocalRoomSource();
    ctx.keep(source, source.dispose);
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
  GalleryScene('agents-skills', (_) => const AgentsSkillsSettingsPage()),
  GalleryScene('agents-mailbox', (_) => AgentMailboxPage(
        service: FakeAgentMailServer(frozen: true, sendSuspended: true)
            .service(),
        now: () => DateTime(2026, 9, 30, 12),
      )),
  GalleryScene('agents-mail-detail', (_) => _mailDetail('m1')),
  GalleryScene('agents-mail-contacts', (_) => AgentMailContactsPage(
        service: FakeAgentMailServer().service(),
      )),
];
