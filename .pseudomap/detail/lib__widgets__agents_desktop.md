# lib/widgets/agents_desktop · Signaturen

## lib/widgets/agents_desktop/desktop_controls.dart  (79 Z.)
- L17 `class PaneResizeHandle extends StatelessWidget`  — The drag target on a pane border, drawn as chuk_chat draws the divider in
  - L18 `const PaneResizeHandle({ super.key, required this.onDrag, this.onDragEnd, this.onDoubleTap, this.hitWidth = 6, this.lineColor, this.semanticLabel = 'Resize pane', })`
  - L28 `final ValueChanged<double> onDrag`
  - L29 `final VoidCallback? onDragEnd`
  - L32 `final VoidCallback? onDoubleTap`  — Back to the default width.
  - L33 `final double hitWidth`
  - L34 `final Color? lineColor`
  - L35 `final String semanticLabel`
  - L38 `Widget build(BuildContext context)`
- L67 `String deskShortcutLabel(String keys)`  — The platform's name for the primary modifier: Cmd on a Mac, Ctrl
- L73 `bool deskPrimaryModifierPressed()`  — Whether the platform's primary modifier is down (Cmd on a Mac).

## lib/widgets/agents_desktop/desktop_dialog.dart  (61 Z.)
- L10 `bool isAgentsDesktop(BuildContext context)`  — Whether [context] is laid out as the desktop (not the phone).
- L18 `Future<T?> showAgentsSheetOrDialog<T>({ required BuildContext context, required WidgetBuilder builder, })`  — A form that is a bottom sheet on the phone and a centred dialog, at most
- L40 `class AgentsDesktopDialog extends StatelessWidget`  — The dialog frame itself: chuk_chat's dialog — the surface, corner and
  - L41 `const AgentsDesktopDialog({super.key, required this.child})`
  - L43 `final Widget child`
  - L46 `Widget build(BuildContext context)`

## lib/widgets/agents_desktop/desktop_metrics.dart  (31 Z.)
- L12 `kDeskRosterMin = 220`  — Left pane (roster): resizable between these. The default is the width of
- L13 `kDeskRosterMax = 360`
- L14 `kDeskRosterDefault = 320`
- L17 `kDeskRailWidth = 56`  — The roster folded to chuk's mini rail.
- L20 `kDeskDetailsMin = 300`  — Right pane (details): resizable between these.
- L21 `kDeskDetailsMax = 420`
- L22 `kDeskDetailsDefault = 340`
- L26 `kDeskThreadMin = 420`  — The thread keeps at least this much. Below it the roster folds to the rail
- L29 `kDeskDialogMaxWidth = 480`  — Dialogs on the desktop: at most this wide, with this corner.
- L30 `kDeskDialogRadius = 20`

## lib/widgets/agents_desktop/quick_switcher.dart  (335 Z.)
- L24 `sealed class QuickSwitcherPick`  — What the user picked.
  - L25 `const QuickSwitcherPick()`
- L28 `class QuickSwitcherAgent extends QuickSwitcherPick`
  - L29 `const QuickSwitcherAgent(this.agent)`
  - L30 `final AgentsAgent agent`
- L33 `class QuickSwitcherRoom extends QuickSwitcherPick`
  - L34 `const QuickSwitcherRoom(this.room)`
  - L35 `final AgentsRoom room`
- L40 `Future<QuickSwitcherPick?> showQuickSwitcher( BuildContext context, { required List<AgentsAgent> agents, required List<AgentsRoom> rooms, AgentProfileStore? profiles, AgentReadMarks? readMarks, })`  — Opens the switcher near the top of the window. Returns the pick, or null
- L57 `class QuickSwitcher extends StatefulWidget`
  - L58 `const QuickSwitcher({ super.key, required this.agents, required this.rooms, this.profiles, this.readMarks, })`
  - L66 `final List<AgentsAgent> agents`
  - L67 `final List<AgentsRoom> rooms`
  - L68 `final AgentProfileStore? profiles`
  - L69 `final AgentReadMarks? readMarks`
  - L72 `State<QuickSwitcher> createState()`
- L75 `class _QuickSwitcherState extends State<QuickSwitcher>`
  - L76 `final TextEditingController _query = TextEditingController()`
  - L77 `final FocusNode _queryFocus = FocusNode(debugLabel: 'quick-switcher-field')`
  - L78 `final ScrollController _scroll = ScrollController()`
  - L79 `int _index = 0`
  - L81 `static const double _rowHeight = 40`
  - L84 `static const double _faceSize = 26`  — The face in a row.
  - L87 `void initState()`
  - L93 `void dispose()`
  - L102 `List<QuickSwitcherPick> get _matches`  — Matches first by a name that starts with the query, then by one that
  - L130 `void _move(int delta, int count)`
  - L147 `KeyEventResult _onKey(FocusNode node, KeyEvent event, int count)`
  - L162 `void _open(QuickSwitcherPick pick)`
  - L165 `Widget build(BuildContext context)`
  - L254 `Widget _row( BuildContext context, QuickSwitcherPick pick, bool highlighted, int i, )`
