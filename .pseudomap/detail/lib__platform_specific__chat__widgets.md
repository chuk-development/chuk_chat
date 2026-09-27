# lib/platform_specific/chat/widgets · Signaturen

## lib/platform_specific/chat/widgets/chat_message_list_item.dart  (237 Z.)
- L18 `class ChatMessageListItem extends StatelessWidget`  — One message row shared by the desktop and mobile chat lists.
  - L19 `const ChatMessageListItem({ super.key, required this.messages, required this.index, required this.data, required this.uuid, required this.maxWidth, required this.activeChatId, required this.flyInKey, required this.showToolCalls, required this.showReasoningTokens, required this.showModelInfo, required this.showTps, required this.isEditing, required this.actions, required this.userMessageActions, required this.onSwitchVariant, this.onAskUserAnswer, this.onConnectMcpServer, this.onContinueGeneration, this.messengerMode = false, this.agentsRuns = false, this.reaction, this.onReaction, this.onReply, this.onEditRequested, this.hoverActions = false, })`
  - L51 `final bool hoverActions`  — The Agents desktop transcript (docs/DESIGN.md §14.4): the message's
  - L53 `final List<Map<String, String>> messages`
  - L54 `final int index`
  - L55 `final MessageRenderData data`
  - L56 `final Uuid uuid`
  - L57 `final double maxWidth`
  - L58 `final String? activeChatId`
  - L59 `final String? flyInKey`
  - L60 `final bool showToolCalls`
  - L61 `final bool showReasoningTokens`
  - L62 `final bool showModelInfo`
  - L63 `final bool showTps`
  - L64 `final bool isEditing`
  - L65 `final List<MessageBubbleAction> actions`
  - L66 `final List<MessageBubbleAction> userMessageActions`
  - L67 `final ValueChanged<int> onSwitchVariant`
  - L68 `final ValueChanged<String>? onAskUserAnswer`
  - L69 `final ValueChanged<String>? onConnectMcpServer`
  - L70 `final VoidCallback? onContinueGeneration`
  - L75 `final bool messengerMode`  — Agents's messenger presentation. Off everywhere upstream's chat builds
  - L80 `final bool agentsRuns`  — Agents's bubble runs: a day change or a pause longer than
  - L83 `final String? reaction`  — The reader's own reaction on this message, if any.
  - L86 `final ValueChanged<String>? onReaction`  — Toggle a reaction. Null hides the reaction picker.
  - L89 `final VoidCallback? onReply`  — Quote this message in the composer. Null hides "Reply".
  - L92 `final VoidCallback? onEditRequested`  — Edit this (user) message from the messenger menu.
  - L95 `Widget build(BuildContext context)`
  - L229 `Widget _withHoverActions(Widget row)`

## lib/platform_specific/chat/widgets/mobile_chat_widgets.dart  (209 Z.)
- L15 `Widget buildTinyIconButton({ IconData? icon, String? svgAssetPath, required VoidCallback? onTap, required bool isActive, required Color color, double buttonSize = 38, double cornerRadius = 12, double iconSize = 18, String? semanticsId, })`  — Build a tiny icon button widget
- L62 `Widget buildTinyActionButton({ IconData? icon, String? svgAssetPath, required VoidCallback onTap, required Color color, bool isLoading = false, double buttonSize = 40, double iconSize = 16, String? semanticsId, })`  — Build a tiny action button widget (for send, etc.)
- L125 `Widget buildAttachmentSheetOption({ required BuildContext context, required IconData icon, required String label, required VoidCallback onTap, required bool isEnabled, })`  — Build attachment sheet option (for bottom sheet)
- L178 `Widget buildKeyboardListener({ required FocusNode focusNode, required TextEditingController controller, required VoidCallback onSend, required Widget child, })`  — Build keyboard listener for text field (handles Enter/Shift+Enter)
