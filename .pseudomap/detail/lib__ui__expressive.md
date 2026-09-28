# lib/ui/expressive · Signaturen

## lib/ui/expressive/agent_face.dart  (316 Z.)
- L26 `ShapeBorder agentAvatarShape(String id, AgentAvatarShape? shape, double size)`  — The selected silhouette, shared by monograms, photos and editor previews.
- L44 `class _OvalAvatarBorder extends ShapeBorder`
  - L45 `const _OvalAvatarBorder()`
  - L47 `EdgeInsetsGeometry get dimensions`
  - L49 `Path getOuterPath(Rect rect, {TextDirection? textDirection})`
  - L58 `Path getInnerPath(Rect rect, {TextDirection? textDirection})`
  - L61 `void paint(Canvas canvas, Rect rect, {TextDirection? textDirection})`
  - L63 `ShapeBorder scale(double t)`
- L68 `Color agentAccent( BuildContext context, String agentId, { AgentProfileStore? store, })`  — The accent colour of a coworker: the picked colour, else the stable hue from
- L95 `int _paletteIndex(String agentId)`  — A stable index into [kAgentAccents] from the agent id. Its own hash, so a
- L105 `kAgentAccents = <Color>[ Color(0xFF2962FF), Color(0xFF7C4DFF), Color(0xFFAA00FF), Color(0xFFFF4081), Color(0xFFFF1744), `  — The palette the profile editor offers for a coworker's colour.
- L124 `class ExpressiveFace extends StatelessWidget`  — A face for an identity the caller only knows as an id and a label — a room
  - L125 `const ExpressiveFace({ super.key, required this.id, required this.label, this.size = 32, this.store, this.dimmed = false, })`
  - L134 `final String id`
  - L135 `final String label`
  - L136 `final double size`
  - L137 `final AgentProfileStore? store`
  - L138 `final bool dimmed`
  - L141 `Widget build(BuildContext context)`
- L190 `class AgentFace extends StatelessWidget`
  - L191 `const AgentFace({ super.key, required this.agent, this.size = 56, this.showPresence = true, this.store, this.dimmed = false, this.profileOverride, })`
  - L201 `final AgentsAgent agent`
  - L202 `final double size`
  - L203 `final bool showPresence`
  - L206 `final AgentProfileStore? store`  — Injectable for tests; defaults to the app-wide store.
  - L209 `final bool dimmed`  — A hidden coworker is shown faded in the "show hidden" list.
  - L212 `final AgentProfile? profileOverride`  — An unsaved editor preview; normal app surfaces always read the store.
  - L215 `static Color? presenceColor(AgentActivity activity)`  — The presence dot colour for an activity, or null for no dot.
  - L227 `Widget build(BuildContext context)`
  - L235 `Widget _build(BuildContext context, AgentProfileStore profiles)`

## lib/ui/expressive/agent_status.dart  (256 Z.)
- L35 `String humanToolLabel(String rawName)`  — What one running tool is called, in words a reader recognises. The host's
- L53 `String? workInProgressLabel(AgentsAgent agent, AgentsRun? run)`  — The words for the status line, or null while the coworker is simply idle
- L80 `kStatusDotSizeFactor = 0.55`  — The dot's diameter as a fraction of the font size it sits next to.
- L83 `kStatusDotGap = 6`  — The single gap between the dot and its words.
- L103 `class StatusDot extends StatelessWidget`  — The presence dot of a status line, on ONE optical line with its words.
  - L104 `const StatusDot({super.key, required this.color, required this.fontSize})`
  - L106 `final Color color`
  - L109 `final double fontSize`  — The unscaled font size of the words beside it.
  - L112 `static double sizeIn(BuildContext context, double fontSize)`  — The painted diameter in [context].
  - L116 `Widget build(BuildContext context)`
- L129 `class _BaselinedBox extends SingleChildRenderObjectWidget`  — A box whose baseline is its own bottom edge.
  - L130 `const _BaselinedBox({required super.child})`
  - L133 `RenderObject createRenderObject(BuildContext context)`
- L137 `class _RenderBaselinedBox extends RenderProxyBox`
  - L139 `double? computeDistanceToActualBaseline(TextBaseline baseline)`
  - L142 `double? computeDryBaseline( covariant BoxConstraints constraints, TextBaseline baseline, )`
- L149 `class AgentStatusLine extends StatelessWidget`  — The line itself: the dot, and the words next to it.
  - L150 `const AgentStatusLine({ super.key, required this.agent, this.sessionKey, this.ledger, this.fontSize = 11, this.link, })`
  - L159 `final AgentsAgent agent`
  - L163 `final String? sessionKey`  — The thread whose run is read for the work in progress. Null falls back to
  - L166 `final AgentsRunLedger? ledger`  — Injectable for tests; defaults to the process-wide ledger.
  - L168 `final double fontSize`
  - L172 `final AgentsRelayLink? link`  — The bound transport, for the reachability half of the line. Injectable for
  - L175 `Widget build(BuildContext context)`
  - L199 `Widget _line( BuildContext context, AgentsRunLedger source, { required bool paired, })`
  - L253 `String _defaultSessionKey()`  — A coworker has one permanent session, and its key is the thread's key.

## lib/ui/expressive/bubble_kind.dart  (68 Z.)
- L22 `enum AgentBubbleKind`
  - L22 `answer`
  - L22 `work`
  - L22 `delivery`
  - L22 `problem`
- L25 `@immutable class AgentBubbleColors`  — The fill and the foreground for a coworker's bubble.
  - L27 `const AgentBubbleColors(this.fill, this.onFill)`
  - L29 `final Color fill`
  - L30 `final Color onFill`
- L33 `AgentBubbleColors agentBubbleColors(ColorScheme scheme, AgentBubbleKind kind)`
- L57 `AgentBubbleKind agentBubbleKindFor({ required bool hasProblem, required bool hasMedia, required bool hasToolRuns, required int textLength, })`  — Picks the kind from the facts a bubble has.

## lib/ui/expressive/bubble_shape.dart  (99 Z.)
- L12 `enum BubblePosition`  — Where a bubble sits inside a run of consecutive same-sender messages.
  - L12 `single`
  - L12 `first`
  - L12 `middle`
  - L12 `last`
- L16 `kBubbleRadiusBig = 22`  — The outer corner radius: every corner that does not touch another block of
- L19 `kBubbleRadiusSmall = 7`  — The inner corner radius: the corners where two blocks of one run touch.
- L23 `kBubbleGapInGroup = 3`  — The vertical gap between two blocks of the SAME run. Small enough that the
- L28 `kBubbleGapBetweenGroups = 14`  — The vertical gap between two runs — a different sender, a new day, or a
- L32 `kBubbleGroupPause = Duration(minutes: 15)`  — A pause this long ends a run: two messages further apart than this are two
- L35 `double bubbleGapAbove({required bool startsNewGroup})`  — The gap above a block, from the flag the chat screens already carry.
- L39 `BubblePosition bubblePositionFor(int index, int length)`  — The position of item [index] in a run of [length].
- L47 `BubblePosition bubblePositionFromFlags({ required bool startsNewGroup, required bool endsGroup, })`  — The position derived from the two flags the chat screens already carry.
- L62 `BubblePosition bubblePositionInStack({ required int index, required int length, required bool startsNewGroup, required bool endsGroup, })`  — Where one block of a message sits in the run, when the message draws more
- L74 `BorderRadius bubbleRadius( bool isMine, BubblePosition pos, { double big = kBubbleRadiusBig, double small = kBubbleRadiusSmall, })`  — The corner radii for a bubble at [pos]. [isMine] flips which side carries
- L97 `String formatClock(int seconds)`  — Formats seconds as `m:ss` (75 → "1:15"). Used for voice clips.

## lib/ui/expressive/connected_group.dart  (187 Z.)
- L21 `class ConnectedGroup extends StatelessWidget`
  - L22 `const ConnectedGroup({ super.key, required this.labels, required this.selected, required this.onSelected, this.badges = const <int, int>{}, this.margin = const EdgeInsets.symmetric(horizontal: 16), this.height, })`
  - L32 `final List<String> labels`
  - L33 `final int selected`
  - L34 `final ValueChanged<int> onSelected`
  - L38 `final Map<int, int> badges`  — Optional count shown after a label (segment index → count). A zero or a
  - L42 `final EdgeInsetsGeometry margin`  — The room left around the pill. Edge to edge, unlike the navigation pill:
  - L48 `final double? height`  — The painted height of the strip. Null keeps [PillGeometry.filterHeight],
  - L51 `static const double outerRadius = PillGeometry.filterRadius`  — The corner of the container that holds the segments.
  - L54 `static const double selectedRadius = PillGeometry.filterSegmentRadius`  — The corner of the filled capsule under the selected segment.
  - L57 `Widget build(BuildContext context)`
- L121 `class _Segment extends StatelessWidget`
  - L122 `const _Segment({ required this.label, required this.count, required this.selected, required this.height, required this.slop, required this.onTap, })`
  - L131 `final String label`
  - L132 `final int count`
  - L133 `final bool selected`
  - L136 `final double height`  — The painted height of the capsule.
  - L139 `final double slop`  — Transparent room above and below the capsule that still takes the press.
  - L140 `final VoidCallback onTap`
  - L143 `Widget build(BuildContext context)`

## lib/ui/expressive/expressive_screen.dart  (150 Z.)
- L27 `class ExpressiveScreen extends StatelessWidget`
  - L28 `const ExpressiveScreen({ super.key, required this.builder, this.title, this.titleWidget, this.actions = const <Widget>[], this.onBack, this.showBack = true, this.bottomBar, this.backgroundColor, })`
  - L46 `final WidgetBuilder builder`  — The page itself, built BELOW the media query this widget grows.
  - L48 `final String? title`
  - L52 `final Widget? titleWidget`  — A title that is not a plain string (a search field, say). Wins over
  - L55 `final List<Widget> actions`  — Trailing targets. Use [ExpressiveIconButton] so they match the back one.
  - L58 `final VoidCallback? onBack`  — What the back target does. Defaults to popping the route.
  - L60 `final bool showBack`
  - L63 `final Widget? bottomBar`  — A bar pinned to the bottom, on the mirrored veil.
  - L65 `final Color? backgroundColor`
  - L68 `static const double barHeight = 64`  — The height of the bar itself, without the status bar above it.
  - L71 `Widget build(BuildContext context)`

## lib/ui/expressive/face_image.dart  (10 Z.)
- reicht weiter: 'face_image_stub.dart' if (dart.library.io) 'face_image_io.dart'

## lib/ui/expressive/face_image_io.dart  (15 Z.)
- L9 `ImageProvider<Object>? faceImageProvider(String? path)`

## lib/ui/expressive/face_image_stub.dart  (8 Z.)
- L7 `ImageProvider<Object>? faceImageProvider(String? path)`

## lib/ui/expressive/feedback.dart  (174 Z.)
- L12 `void pillToast(BuildContext context, String message, {IconData? icon})`  — A floating pill toast — the expressive replacement for a flat SnackBar.
- L48 `Future<T?> expressiveSheet<T>( BuildContext context, { required String title, required Widget child, })`  — An expressive modal sheet: 36 px top corners, a drag handle, generous pad.
- L92 `class SheetAction extends StatelessWidget`  — A big tappable action row for an expressive sheet.
  - L93 `const SheetAction({ super.key, required this.icon, required this.label, required this.onTap, this.color, this.subtitle, this.enabled = true, })`
  - L103 `final IconData icon`
  - L104 `final String label`
  - L105 `final String? subtitle`
  - L106 `final Color? color`
  - L107 `final VoidCallback onTap`
  - L110 `final bool enabled`  — A parked action (the voice call) is rendered dimmed and does not fire.
  - L113 `Widget build(BuildContext context)`

## lib/ui/expressive/huge_icon.dart  (8 Z.)
- reicht weiter: 'package:chuk_chat/widgets/icons/huge_icon.dart'

## lib/ui/expressive/icon_map.dart  (14 Z.)
- reicht weiter: 'package:chuk_chat/widgets/icons/icon_map.dart'

## lib/ui/expressive/motion.dart  (530 Z.)
- L28 `kExpressiveDecelerate = Cubic(0.05, 0.7, 0.1, 1.0)`  — The bouncy spatial spring used for press and selection feedback.
- L32 `kExpressiveShort = Duration(milliseconds: 180)`  — The matching duration. Long enough to be seen, short enough not to be
- L34 `kSpatialSpring = SpringDescription( mass: 1, stiffness: 420, damping: 22, )`
- L41 `kEffectSpring = SpringDescription( mass: 1, stiffness: 600, damping: 26, )`  — A snappier spring for small effects (icons, indicators).
- L48 `class MorphTap extends StatefulWidget`  — A surface that springs and morphs on press. Wrap ANY tappable element.
  - L49 `const MorphTap({ super.key, required this.child, this.onTap, this.onLongPress, this.color, this.pressedColor, this.shape = const StadiumBorder(), this.pressedShape, this.pressedOutline, this.pressedOutlineWidth = 1.5, this.padding = EdgeInsets.zero, this.pressedScale = 0.93, this.instant = false, this.hitPadding = EdgeInsets.zero, }) : assert( hitPadding == EdgeInsets.zero || instant, 'hitPadding is the area the Listener covers; only instant taps use it', )`
  - L69 `final Widget child`
  - L70 `final VoidCallback? onTap`
  - L71 `final VoidCallback? onLongPress`
  - L72 `final Color? color`
  - L75 `final Color? pressedColor`  — The colour the surface fades toward while held. Null keeps [color].
  - L76 `final ShapeBorder shape`
  - L80 `final ShapeBorder? pressedShape`  — The shape the surface morphs toward while held. Defaults to a blockier
  - L86 `final Color? pressedOutline`  — An outline drawn in the current shape while the surface is held. A
  - L87 `final double pressedOutlineWidth`
  - L88 `final EdgeInsetsGeometry padding`
  - L89 `final double pressedScale`
  - L105 `final bool instant`  — Commit the tap on pointer DOWN instead of on a recognised tap.
  - L110 `final EdgeInsets hitPadding`  — Transparent room around the surface that still takes the press. Only an
  - L113 `State<MorphTap> createState()`
- L116 `class _MorphTapState extends State<MorphTap> with SingleTickerProviderStateMixin`
  - L118 `late final AnimationController _c = AnimationController.unbounded( vsync: this, value: 0, )`
  - L123 `ShapeBorder get _pressed`
  - L133 `bool _reducedMotion = false`  — Reduced motion: the press still happens, it just does not travel.
  - L137 `int? _pointer`  — The pointer that owns the press in [MorphTap.instant] mode. A second
  - L139 `void _instantDown(PointerDownEvent event)`
  - L150 `void _instantRelease(PointerEvent event)`
  - L159 `void didChangeDependencies()`
  - L169 `void dispose()`
  - L174 `void _press(bool down)`
  - L191 `Widget build(BuildContext context)`
- L262 `class _PressOutlinePainter extends CustomPainter`  — Draws [MorphTap.pressedOutline] along the shape the surface currently has.
  - L263 `const _PressOutlinePainter({ required this.shape, required this.color, required this.width, })`
  - L269 `final ShapeBorder shape`
  - L270 `final Color color`
  - L271 `final double width`
  - L274 `void paint(Canvas canvas, Size size)`
  - L289 `bool shouldRepaint(_PressOutlinePainter old)`
- L294 `class ExpressiveButton extends StatelessWidget`  — A fully rounded button that springs and morphs on press.
  - L295 `const ExpressiveButton({ super.key, required this.label, required this.onTap, this.icon, this.color, this.onColor, this.tonal = false, this.dense = false, })`
  - L306 `final IconData? icon`
  - L307 `final String label`
  - L308 `final VoidCallback onTap`
  - L309 `final Color? color`
  - L310 `final Color? onColor`
  - L311 `final bool tonal`
  - L315 `final bool dense`  — The desktop size (docs/DESIGN.md §14.8): a 36 px button for a dialog
  - L318 `Widget build(BuildContext context)`
- L358 `class ExpressiveIconButton extends StatelessWidget`  — The expressive icon target: a soft squircle that squashes a touch more
  - L359 `const ExpressiveIconButton({ super.key, this.icon, this.hugeIcon, required this.onTap, this.color, this.onColor, this.size = 48, this.width, this.tooltip, this.semanticsId, this.parked = false, })`
  - L375 `final IconData? icon`  — A Material glyph. Kept for the screens that have not been moved over yet;
  - L378 `final HugeIconData? hugeIcon`  — The app's own set (docs/DESIGN.md). Wins when both are given.
  - L381 `final VoidCallback? onTap`  — Null disables the button.
  - L382 `final Color? color`
  - L383 `final Color? onColor`
  - L384 `final double size`
  - L389 `final double? width`  — The painted width. Null keeps the square target; a wider value makes the
  - L391 `final String? tooltip`
  - L392 `final String? semanticsId`
  - L396 `final bool parked`  — A target for a feature that is not available yet: it looks disabled and it
  - L399 `Widget build(BuildContext context)`
- L456 `class ExpressiveLoader extends StatefulWidget`  — The expressive spinner: a cookie blob that turns while its scallop depth
  - L457 `const ExpressiveLoader({super.key, this.size = 48, this.color})`
  - L459 `final double size`
  - L460 `final Color? color`
  - L463 `State<ExpressiveLoader> createState()`
- L466 `class _ExpressiveLoaderState extends State<ExpressiveLoader> with SingleTickerProviderStateMixin`
  - L468 `late final AnimationController _c = AnimationController( vsync: this, duration: const Duration(milliseconds: 1400), )..repeat()`
  - L474 `void dispose()`
  - L480 `Widget build(BuildContext context)`
- L495 `class _BlobPainter extends CustomPainter`
  - L496 `_BlobPainter({required this.t, required this.color})`
  - L498 `final double t`
  - L499 `final Color color`
  - L502 `void paint(Canvas canvas, Size size)`
  - L528 `bool shouldRepaint(_BlobPainter old)`

## lib/ui/expressive/pill_geometry.dart  (102 Z.)
- L27 `abstract final class PillGeometry`
  - L28 `const PillGeometry._()`
  - L32 `static const double inset = 8`  — The background that shows around the segments: above, below, at both ends
  - L35 `static const double segmentHeight = 44`  — The height of one segment, and so the height of the filled capsule.
  - L39 `static const double tapSlop = 4`  — How far a segment's tap area reaches into the ring, above and below.
  - L43 `static const double tapHeight = segmentHeight + tapSlop * 2`  — What a finger hits: the capsule plus the ring it reaches into. At or
  - L46 `static const double height = segmentHeight + inset * 2`  — The height of the whole pill.
  - L50 `static const EdgeInsets shellPadding = EdgeInsets.symmetric( horizontal: inset, vertical: inset - tapSlop, )`  — The padding of the shell that holds the segments. Short of [inset] top
  - L56 `static const double segmentRadius = segmentHeight / 2`  — The corner of a segment: half its height, which is a stadium.
  - L59 `static const double radius = segmentRadius + inset`  — The corner of the pill that holds the segments.
  - L70 `static const double filterInset = 3`  — The hairline of background around the switch's capsule.
  - L76 `static const double filterSegmentHeight = 32`  — The height of one switch segment, and so of its filled capsule. Short of
  - L84 `static const double filterTapSlop = 8`  — How far a switch segment's tap area reaches past the capsule, into the
  - L87 `static const double filterTapHeight = filterSegmentHeight + filterTapSlop * 2`  — What a finger hits on the switch: the whole strip.
  - L91 `static const double filterHeight = filterSegmentHeight + filterInset * 2`  — The height of the whole switch.
  - L94 `static const double filterSegmentRadius = filterSegmentHeight / 2`  — The corner of a switch segment: a stadium.
  - L97 `static const double filterRadius = filterSegmentRadius + filterInset`  — The corner of the shell that holds them, concentric with the capsule.
  - L100 `static const EdgeInsets filterShellPadding = EdgeInsets.all(filterInset)`  — The padding of that shell.

## lib/ui/expressive/shapes.dart  (244 Z.)
- L19 `class CookieShape extends ShapeBorder`  — A scalloped blob. [softness] 0 is a circle; about 0.2 is a deep scallop.
  - L20 `const CookieShape({this.lobes = 8, this.softness = 0.12, this.rotation = 0})`
  - L22 `final int lobes`
  - L23 `final double softness`
  - L27 `final double rotation`  — Orientation in radians, so two blobs with the same lobe count still look
  - L29 `Path _build(Rect rect)`
  - L50 `Path getOuterPath(Rect rect, {TextDirection? textDirection})`
  - L53 `Path getInnerPath(Rect rect, {TextDirection? textDirection})`
  - L56 `void paint(Canvas canvas, Rect rect, {TextDirection? textDirection})`
  - L59 `ShapeBorder scale(double t)`
  - L63 `EdgeInsetsGeometry get dimensions`
- L68 `int shapeIndexFor(String key)`  — A stable shape index from an identity [key] (an agent id). Same key, same
- L77 `ShapeBorder expressiveShapeFor(String key)`  — [expressiveShape] keyed by identity instead of list position.
- L89 `ShapeBorder expressiveShape(int i)`  — One curated silhouette per index.
- L127 `class PolygonShape extends ShapeBorder`  — A regular polygon with rounded corners, inscribed in the box.
  - L128 `const PolygonShape({ required this.sides, this.cornerFactor = 0.25, this.rotation = 0, }) : assert(sides >= 3)`
  - L134 `final int sides`
  - L135 `final double cornerFactor`
  - L138 `final double rotation`  — Orientation in radians. A square turns into a diamond at pi / 4.
  - L140 `Path _build(Rect rect)`
  - L204 `static Offset _towards(Offset from, Offset to, double distance)`
  - L214 `Path getOuterPath(Rect rect, {TextDirection? textDirection})`
  - L217 `Path getInnerPath(Rect rect, {TextDirection? textDirection})`
  - L220 `void paint(Canvas canvas, Rect rect, {TextDirection? textDirection})`
  - L223 `ShapeBorder scale(double t)`
  - L230 `EdgeInsetsGeometry get dimensions`
- L242 `double monogramDrop(ShapeBorder shape)`  — How far the monogram of a face has to sit below the middle of its box for

## lib/ui/expressive/staggered.dart  (90 Z.)
- L15 `class StaggeredItem extends StatefulWidget`
  - L16 `const StaggeredItem({super.key, required this.index, required this.child})`
  - L18 `final int index`
  - L19 `final Widget child`
  - L22 `static const Duration motion = Duration(milliseconds: 460)`  — How long one row's own motion takes.
  - L25 `static Duration delayFor(int index)`  — Delay per row, capped at the 13th row.
  - L29 `State<StaggeredItem> createState()`
- L32 `class _StaggeredItemState extends State<StaggeredItem> with SingleTickerProviderStateMixin`
  - L34 `late final int _delayMs = StaggeredItem.delayFor(widget.index).inMilliseconds`
  - L35 `late final int _totalMs = _delayMs + StaggeredItem.motion.inMilliseconds`
  - L37 `late final AnimationController _c = AnimationController( vsync: this, duration: Duration(milliseconds: _totalMs), )`
  - L42 `late final Animation<double> _t = CurvedAnimation( parent: _c, curve: Interval(_delayMs / _totalMs, 1, curve: Curves.easeOutCubic), )`
  - L47 `bool _started = false`
  - L50 `void didChangeDependencies()`
  - L67 `void dispose()`
  - L73 `Widget build(BuildContext context)`

## lib/ui/expressive/top_veil.dart  (94 Z.)
- L17 `BoxDecoration topVeilDecoration(ColorScheme scheme)`  — The gradient itself, for surfaces that place their own bar (a pinned
- L31 `class TopVeil extends StatelessWidget`
  - L32 `const TopVeil({super.key, required this.child, this.fadeBelow = 26})`
  - L35 `final Widget child`  — The bar itself: the row of targets, the title, whatever floats.
  - L38 `final double fadeBelow`  — How much room the gradient gets under [child] to reach zero.
  - L41 `Widget build(BuildContext context)`
- L59 `BoxDecoration bottomVeilDecoration(ColorScheme scheme)`  — The veil under a floating bottom bar: nothing at the top, heaviest at the
- L74 `class BottomVeil extends StatelessWidget`  — [child] on the bottom veil, with room above it for the gradient to fade in.
  - L75 `const BottomVeil({super.key, required this.child, this.fadeAbove = 26})`
  - L77 `final Widget child`
  - L78 `final double fadeAbove`
  - L81 `Widget build(BuildContext context)`

## lib/ui/expressive/waveform.dart  (9 Z.)
- reicht weiter: 'package:chuk_chat/widgets/waveform.dart'

## lib/ui/expressive/working_dots.dart  (75 Z.)
- L11 `class WorkingDots extends StatefulWidget`
  - L12 `const WorkingDots({super.key, required this.color, this.label = 'working'})`
  - L14 `final Color color`
  - L15 `final String label`
  - L18 `State<WorkingDots> createState()`
- L21 `class _WorkingDotsState extends State<WorkingDots> with SingleTickerProviderStateMixin`
  - L23 `late final AnimationController _c = AnimationController( vsync: this, duration: const Duration(milliseconds: 1100), )..repeat()`
  - L29 `void dispose()`
  - L35 `Widget build(BuildContext context)`
