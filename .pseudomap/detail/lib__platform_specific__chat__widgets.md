# lib/platform_specific/chat/widgets · Signatures

## lib/platform_specific/chat/widgets/desktop_chat_widgets.dart  (64 Z.)

- L6 `Widget buildDesktopIconButton({ required IconData icon, required VoidCallback onTap, required bool isActive, required Color iconFg, required Color bg, String? debugLabel, })`  — Build icon button for desktop UI

## lib/platform_specific/chat/widgets/fullscreen_composer.dart  (149 Z.)

- L26 `Future<String?> showFullscreenComposer( BuildContext context, { required String initialText, })`  — Opens the message being written on a screen of its own.
- L38 `class _FullscreenComposerPage extends StatefulWidget`
  - L39 `const _FullscreenComposerPage({required this.initialText})`
  - L41 `final String initialText`
  - L44 `State<_FullscreenComposerPage> createState()`
- L48 `class _FullscreenComposerPageState extends State<_FullscreenComposerPage>`
  - L49 `late final TextEditingController _controller`
  - L50 `late final FocusNode _focusNode`
  - L53 `void initState()`
  - L65 `void dispose()`
  - L71 `void _close()`
  - L74 `Widget build(BuildContext context)`

## lib/platform_specific/chat/widgets/mobile_chat_widgets.dart  (346 Z.)

- L14 `Widget buildTinyIconButton({ IconData? icon, String? svgAssetPath, required VoidCallback? onTap, required bool isActive, required Color color, double buttonSize = 38, double cornerRadius = 12, double iconSize = 18, String? semanticsId, })`  — Build a tiny icon button widget
- L61 `Widget buildTinyActionButton({ IconData? icon, String? svgAssetPath, required VoidCallback onTap, required Color color, bool isLoading = false, double buttonSize = 40, double iconSize = 16, String? semanticsId, })`  — Build a tiny action button widget (for send, etc.)
- L122 `Widget buildAttachmentSheetOption({ required BuildContext context, required IconData icon, required String label, required VoidCallback onTap, required bool isEnabled, })`  — Build attachment sheet option (for bottom sheet)
- L175 `Widget buildKeyboardListener({ required FocusNode focusNode, required TextEditingController controller, required VoidCallback onSend, required Widget child, })`  — Build keyboard listener for text field (handles Enter/Shift+Enter)
- L215 `class ComposerInputRow extends StatelessWidget`  — Row one of the mobile composer: the text field, and — while the microphone
  - L216 `const ComposerInputRow({ super.key, required this.isRecording, required this.audioLevels, required this.accentColor, required this.timeColor, required this.child, })`
  - L225 `final bool isRecording`
  - L228 `final List<double> audioLevels`  — The recorder's rolling level buffer (0..1, oldest first).
  - L231 `final Color accentColor`  — The colour of the bars.
  - L234 `final Color timeColor`  — The colour of the elapsed time.
  - L237 `final Widget child`  — The text field of the composer.
  - L240 `Widget build(BuildContext context)`
- L268 `class RecordingWaveformBar extends StatefulWidget`  — The open microphone: the live waveform, and the elapsed time beside it.
  - L269 `const RecordingWaveformBar({ super.key, required this.audioLevels, required this.color, required this.timeColor, })`
  - L276 `final List<double> audioLevels`
  - L277 `final Color color`
  - L278 `final Color timeColor`
  - L281 `State<RecordingWaveformBar> createState()`
- L284 `class _RecordingWaveformBarState extends State<RecordingWaveformBar>`
  - L285 `final Stopwatch _clock = Stopwatch()`
  - L286 `Timer? _ticker`
  - L287 `Duration _elapsed = Duration.zero`
  - L290 `void initState()`
  - L300 `void dispose()`
  - L306 `static String _format(Duration value)`
  - L313 `Widget build(BuildContext context)`
