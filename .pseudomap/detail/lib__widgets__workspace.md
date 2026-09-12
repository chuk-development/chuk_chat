# lib/widgets/workspace · Signatures

## lib/widgets/workspace/workspace_actions_mixin.dart  (274 Z.)

- L30 `mixin WorkspaceActionsMixin<T extends StatefulWidget> on State<T>`  — Shared workspace actions for a [State] that manages a single workspace.
  - L32 `String get workspaceId`  — Id of the workspace this state operates on.
  - L38 `bool isUploadingFile = false`
  - L39 `String? uploadFileName`
  - L42 `String uploadStatus = ''`  — `'uploading'`, `'converting'` or `''`.
  - L43 `double uploadProgress = 0.0`
  - L49 `StreamSubscription<void>? _workspaceChangesSub`
  - L52 `void listenToWorkspaceChanges(VoidCallback onChange)`  — Calls [onChange] whenever the workspace store reports a change.
  - L62 `void cancelWorkspaceChangesSubscription()`  — Stops the subscription started by [listenToWorkspaceChanges].
  - L74 `Future<void> loadWorkspaceAndChats({ required void Function(Workspace workspace, List<StoredChat> chats) onLoaded, required VoidCallback onFailed, })`  — Loads the workspace plus its chats and hands both to [onLoaded] inside a
  - L109 `Future<void> uploadFileToWorkspace({ Future<bool> Function(int estimatedTokens)? confirmOversizedUpload, })`  — Picks a file and uploads it into the workspace, driving the
  - L161 `Future<void> deleteWorkspaceFile( WorkspaceFile file, { String? title, String? body, String? cancelLabel, String? deleteLabel, String Function(String error)? failedMessage, })`  — Asks for confirmation and deletes [file] from the workspace.
  - L201 `void viewWorkspaceFile(BuildContext viewerContext, WorkspaceFile file)`  — Opens the file viewer after the current frame, using [viewerContext].
  - L214 `Future<bool> saveWorkspaceInstructions( String instructions, { String? successMessage, })`  — Saves the workspace's custom system prompt. Returns `true` when the save
  - L240 `Future<void> addChatToWorkspace({ required Iterable<String> existingChatIds, required Future<StoredChat?> Function(List<StoredChat> available) pickChat, })`  — Lets the user pick one of the chats that are not in the workspace yet and
  - L265 `Future<void> removeChatFromWorkspace(String chatId)`  — Removes [chatId] from the workspace.

## lib/widgets/workspace/workspace_common_widgets.dart  (348 Z.)

- L18 `class WorkspaceCountBadge extends StatelessWidget`  — Small pill with a count, used in the workspace tab bars.
  - L19 `final int count`
  - L20 `final Color color`
  - L22 `const WorkspaceCountBadge({ super.key, required this.count, required this.color, })`
  - L29 `Widget build(BuildContext context)`
- L49 `class WorkspaceEmptyState extends StatelessWidget`  — Centered "nothing here yet" placeholder used by the files and chats tabs.
  - L50 `final IconData icon`
  - L51 `final String title`
  - L52 `final String subtitle`
  - L54 `const WorkspaceEmptyState({ super.key, required this.icon, required this.title, required this.subtitle, })`
  - L62 `Widget build(BuildContext context)`
- L94 `class WorkspaceUploadProgressCard extends StatelessWidget`  — Card that shows the running file upload (progress bar + status text).
  - L95 `final String? fileName`
  - L96 `final String status`
  - L97 `final double progress`
  - L98 `final Color displayColor`
  - L100 `const WorkspaceUploadProgressCard({ super.key, required this.fileName, required this.status, required this.progress, required this.displayColor, })`
  - L109 `Widget build(BuildContext context)`
- L164 `class WorkspaceFileTile extends StatelessWidget`  — One row in a workspace file list: icon, name, caller-supplied subtitle and
  - L165 `final WorkspaceFile file`
  - L166 `final String workspaceId`
  - L167 `final Color displayColor`
  - L168 `final bool isDark`
  - L171 `final Widget subtitle`  — Subtitle row content, e.g. size plus a context-usage chip.
  - L174 `final void Function(BuildContext menuContext) onView`  — Called with the popup menu item's context when "View" is tapped.
  - L177 `final VoidCallback onDelete`  — Called (after a zero-duration delay, so the menu can close) on "Delete".
  - L179 `const WorkspaceFileTile({ super.key, required this.file, required this.workspaceId, required this.displayColor, required this.isDark, required this.subtitle, required this.onView, required this.onDelete, })`
  - L191 `Widget build(BuildContext context)`
- L247 `class WorkspaceChatsTab extends StatelessWidget`  — The "Chats" tab shared by the workspace detail and management pages.
  - L248 `final List<StoredChat> chats`
  - L249 `final Color displayColor`
  - L250 `final VoidCallback onAddChat`
  - L251 `final void Function(String chatId) onRemoveChat`
  - L254 `final bool showChatDate`  — Appends the creation date to the "N messages" subtitle.
  - L257 `final double? removeIconSize`  — Size of the remove icon; `null` keeps the [IconButton] default.
  - L259 `const WorkspaceChatsTab({ super.key, required this.chats, required this.displayColor, required this.onAddChat, required this.onRemoveChat, this.showChatDate = false, this.removeIconSize, })`
  - L270 `Widget build(BuildContext context)`
