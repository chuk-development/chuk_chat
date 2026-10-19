# lib/platform_specific/chat/widgets · Signaturen

## lib/platform_specific/chat/widgets/chat_message_list_item.dart  (224 Z.)
- L19 `class ChatMessageListItem extends StatelessWidget`  — One message row shared by the desktop and mobile chat lists.
  - L20 `const ChatMessageListItem({ super.key, required this.messages, required this.index, required this.data, required this.uuid, required this.maxWidth, required this.activeChatId, required this.flyInKey, required this.showToolCalls, required this.showReasoningTokens, required this.showModelInfo, required this.showTps, required this.isEditing, required this.actions, required this.userMessageActions, required this.onSwitchVariant, this.onAskUserAnswer, this.onConnectMcpServer, this.onOpenUiMessage, this.onContinueGeneration, this.messengerMode = false, this.reaction, this.onReaction, this.onReply, this.onEditRequested, })`
  - L48 `final List<Map<String, String>> messages`
  - L49 `final int index`
  - L50 `final MessageRenderData data`
  - L51 `final Uuid uuid`
  - L52 `final double maxWidth`
  - L53 `final String? activeChatId`
  - L54 `final String? flyInKey`
  - L55 `final bool showToolCalls`
  - L56 `final bool showReasoningTokens`
  - L57 `final bool showModelInfo`
  - L58 `final bool showTps`
  - L59 `final bool isEditing`
  - L60 `final List<MessageBubbleAction> actions`
  - L61 `final List<MessageBubbleAction> userMessageActions`
  - L62 `final ValueChanged<int> onSwitchVariant`
  - L63 `final ValueChanged<String>? onAskUserAnswer`
  - L64 `final ValueChanged<String>? onConnectMcpServer`
  - L68 `final ValueChanged<String>? onOpenUiMessage`  — Sends a message an OpenUI view in this answer composed, as a user
  - L69 `final VoidCallback? onContinueGeneration`
  - L74 `final bool messengerMode`  — Agents's messenger behaviour: reactions, reply and the long-press menu.
  - L77 `final String? reaction`  — The reader's own reaction on this message, if any.
  - L80 `final ValueChanged<String>? onReaction`  — Toggle a reaction. Null hides the reaction picker.
  - L83 `final VoidCallback? onReply`  — Quote this message in the composer. Null hides "Reply".
  - L86 `final VoidCallback? onEditRequested`  — Edit this (user) message from the messenger menu.
  - L89 `Widget build(BuildContext context)`

## lib/platform_specific/chat/widgets/mobile_chat_widgets.dart  (213 Z.)
- L14 `Widget buildTinyIconButton({ IconData? icon, String? svgAssetPath, required VoidCallback? onTap, required bool isActive, required Color color, double buttonSize = 38, double cornerRadius = 12, double iconSize = 18, String? semanticsId, })`  — Build a tiny icon button widget
- L61 `Widget buildTinyActionButton({ IconData? icon, String? svgAssetPath, required VoidCallback onTap, required Color color, bool isLoading = false, double buttonSize = 40, double iconSize = 16, String? semanticsId, })`  — Build a tiny action button widget (for send, etc.)
- L129 `Widget buildAttachmentSheetOption({ required BuildContext context, required IconData icon, required String label, required VoidCallback onTap, required bool isEnabled, })`  — Build attachment sheet option (for bottom sheet)
- L182 `Widget buildKeyboardListener({ required FocusNode focusNode, required TextEditingController controller, required VoidCallback onSend, required Widget child, })`  — Build keyboard listener for text field (handles Enter/Shift+Enter)
