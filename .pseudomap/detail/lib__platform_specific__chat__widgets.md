# lib/platform_specific/chat/widgets · Signaturen

## lib/platform_specific/chat/widgets/chat_message_list_item.dart  (230 Z.)
- L20 `class ChatMessageListItem extends StatelessWidget`  — One message row shared by the desktop and mobile chat lists.
  - L21 `const ChatMessageListItem({ super.key, required this.messages, required this.index, required this.data, required this.uuid, required this.maxWidth, required this.activeChatId, required this.flyInKey, required this.showToolCalls, required this.showReasoningTokens, required this.showModelInfo, required this.showTps, required this.isEditing, required this.actions, required this.userMessageActions, required this.onSwitchVariant, this.onAskUserAnswer, this.onConnectMcpServer, this.onOpenUiMessage, this.onContinueGeneration, this.messengerMode = false, this.reaction, this.onReaction, this.onReply, this.onEditRequested, })`
  - L49 `final List<Map<String, String>> messages`
  - L50 `final int index`
  - L51 `final MessageRenderData data`
  - L52 `final Uuid uuid`
  - L53 `final double maxWidth`
  - L54 `final String? activeChatId`
  - L55 `final String? flyInKey`
  - L56 `final bool showToolCalls`
  - L57 `final bool showReasoningTokens`
  - L58 `final bool showModelInfo`
  - L59 `final bool showTps`
  - L60 `final bool isEditing`
  - L61 `final List<MessageBubbleAction> actions`
  - L62 `final List<MessageBubbleAction> userMessageActions`
  - L63 `final ValueChanged<int> onSwitchVariant`
  - L64 `final ValueChanged<String>? onAskUserAnswer`
  - L65 `final ValueChanged<String>? onConnectMcpServer`
  - L69 `final ValueChanged<String>? onOpenUiMessage`  — Sends a message an OpenUI view in this answer composed, as a user
  - L70 `final VoidCallback? onContinueGeneration`
  - L75 `final bool messengerMode`  — Agents's messenger behaviour: reactions, reply and the long-press menu.
  - L78 `final String? reaction`  — The reader's own reaction on this message, if any.
  - L81 `final ValueChanged<String>? onReaction`  — Toggle a reaction. Null hides the reaction picker.
  - L84 `final VoidCallback? onReply`  — Quote this message in the composer. Null hides "Reply".
  - L87 `final VoidCallback? onEditRequested`  — Edit this (user) message from the messenger menu.
  - L90 `Widget build(BuildContext context)`

## lib/platform_specific/chat/widgets/composer_send_button.dart  (237 Z.)
- L23 `enum ComposerSendFace`  — What the composer's primary target shows.
  - L23 `send`
  - L23 `voice`
  - L23 `stop`
  - L23 `loading`
- L26 `kComposerSendSwap = Duration(milliseconds: 150)`  — How long the face change takes.
- L28 `class ComposerSendButton extends StatelessWidget`
  - L29 `const ComposerSendButton({ super.key, required this.controller, required this.onSend, required this.width, required this.height, required this.radius, this.hasOtherContent = false, this.onVoice, this.onStop, this.stopping = false, this.loading = false, this.sendIcon = Icons.north_rounded, this.iconSize = 18, this.stopIconSize, this.sendIconScaleY = 1, this.spinnerSize, this.spinnerStroke = 2, this.semanticsId = 'send_button', })`
  - L51 `final TextEditingController controller`  — The composer's text. The face follows it as the user types.
  - L54 `final bool hasOtherContent`  — Content that is not text: an attachment, an open microphone.
  - L57 `final VoidCallback onSend`  — Sends what the composer holds.
  - L61 `final VoidCallback? onVoice`  — Starts the voice call. Null: this build or this chat has no call, so
  - L64 `final VoidCallback? onStop`  — Stops the streaming response.
  - L67 `final bool stopping`  — A response streams and the target is the stop target.
  - L70 `final bool loading`  — A recording is transcribed. The target shows a spinner and takes no tap.
  - L72 `final double width`
  - L73 `final double height`
  - L74 `final double radius`
  - L77 `final IconData sendIcon`  — The send glyph, as today's composer drew it.
  - L80 `final double iconSize`  — Size of the send glyph. The voice glyph uses the same size.
  - L83 `final double? stopIconSize`  — Size of the stop glyph. Null: [iconSize].
  - L86 `final double sendIconScaleY`  — The desktop arrow is drawn slightly flattened.
  - L89 `final double? spinnerSize`  — Null: the button's short side less 16.
  - L90 `final double spinnerStroke`
  - L92 `final String semanticsId`
  - L99 `static bool stopsWhile({required bool busy, required bool micActive})`  — The face for a composer state. Loading wins, then stop, then content.
  - L102 `static ComposerSendFace faceFor({ required bool hasContent, required bool voiceAvailable, bool stopping = false, bool loading = false, })`
  - L115 `Widget build(BuildContext context)`
  - L131 `Widget _build(BuildContext context, ComposerSendFace face, bool hasContent)`
  - L199 `Widget _glyph(ComposerSendFace face, Color on)`

## lib/platform_specific/chat/widgets/mobile_chat_widgets.dart  (213 Z.)
- L14 `Widget buildTinyIconButton({ IconData? icon, String? svgAssetPath, required VoidCallback? onTap, required bool isActive, required Color color, double buttonSize = 38, double cornerRadius = 12, double iconSize = 18, String? semanticsId, })`  — Build a tiny icon button widget
- L61 `Widget buildTinyActionButton({ IconData? icon, String? svgAssetPath, required VoidCallback onTap, required Color color, bool isLoading = false, double buttonSize = 40, double iconSize = 16, String? semanticsId, })`  — Build a tiny action button widget (for send, etc.)
- L129 `Widget buildAttachmentSheetOption({ required BuildContext context, required IconData icon, required String label, required VoidCallback onTap, required bool isEnabled, })`  — Build attachment sheet option (for bottom sheet)
- L182 `Widget buildKeyboardListener({ required FocusNode focusNode, required TextEditingController controller, required VoidCallback onSend, required Widget child, })`  — Build keyboard listener for text field (handles Enter/Shift+Enter)
