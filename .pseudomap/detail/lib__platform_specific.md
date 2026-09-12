# lib/platform_specific · Signatures

## lib/platform_specific/root_wrapper.dart  (5 Z.)

- conditional export: 'root_wrapper_stub.dart' if (dart.library.io) 'root_wrapper_io.dart'

## lib/platform_specific/root_wrapper_desktop.dart  (781 Z.)

- L33 `class RootWrapperDesktop extends StatefulWidget`
  - L34 `final AppShellConfig config`
  - L36 `const RootWrapperDesktop({super.key, required this.config})`
  - L39 `State<RootWrapperDesktop> createState()`
- L42 `class _RootWrapperDesktopState extends State<RootWrapperDesktop>`
  - L43 `bool _isSidebarExpanded = false`
  - L44 `bool _hasOpenedSidebar = false`
  - L46 `String? _activeProjectId`
  - L47 `String? _activePanel`
  - L48 `ArtifactDocument? _activeArtifact`
  - L49 `bool _panelOpen = true`
  - L52 `double? _userArtifactPanelWidth`  — User-preferred artifact panel width. Null = default 50%.
  - L54 `final GlobalKey<ChukChatUIDesktopState> _chatUIKey = GlobalKey()`
  - L57 `void initState()`
  - L115 `void dispose()`
  - L133 `void _onArtifactChanged()`
  - L145 `void _onPanelOpenChanged()`
  - L152 `void _onArtifactOpenRequested()`
  - L159 `void _closeArtifactPanel()`
  - L166 `void _openSourceChatForArtifact(String chatId)`
  - L180 `void _openSettingsPage()`
  - L187 `void _openWorkspacesPage()`
  - L197 `void _openWorkspace(String workspaceId)`
  - L217 `void _startWorkspaceChat(String workspaceId)`
  - L228 `void _exitProject()`
  - L234 `void _closePanel()`
  - L240 `void _openMediaPage()`
  - L251 `void _handleChatSelected(String? chatId)`
  - L319 `void _toggleSidebar()`
  - L329 `void _copyDebugChat()`
  - L347 `List<Widget> _buildMiniRail(Color iconFg, AppLocalizations l)`
  - L411 `void _onTrayNewChat()`
  - L416 `void _handleNewChatFromSidebar()`
  - L437 `Future<void> _handleChatDeleted(String deletedChatId)`
  - L454 `Widget build(BuildContext context)`

## lib/platform_specific/root_wrapper_io.dart  (76 Z.)

- L30 `class RootWrapper extends StatelessWidget`
  - L31 `final AppShellConfig config`
  - L33 `const RootWrapper({super.key, required this.config})`
  - L36 `Widget build(BuildContext context)`
  - L57 `bool _isMobilePhone(BuildContext context)`

## lib/platform_specific/root_wrapper_mobile.dart  (769 Z.)

- L37 `class RootWrapperMobile extends StatefulWidget`
  - L38 `final AppShellConfig config`
  - L40 `const RootWrapperMobile({super.key, required this.config})`
  - L43 `State<RootWrapperMobile> createState()`
- L46 `class _RootWrapperMobileState extends State<RootWrapperMobile> with WidgetsBindingObserver, SingleTickerProviderStateMixin`
  - L51 `static bool _batteryPromptedThisLaunch = false`  — Guards the battery-optimization prompt to once per app process so the
  - L53 `bool _isSidebarExpanded = false`
  - L54 `bool _artifactSheetOpen = false`
  - L56 `final GlobalKey<ChukChatUIMobileState> _chatUIMobileKey = GlobalKey()`
  - L57 `late AnimationController _sidebarAnimController`
  - L58 `late Animation<double> _sidebarAnimation`
  - L61 `void initState()`
  - L131 `void dispose()`
  - L145 `void _onPanelOpenRequested()`
  - L150 `void _onArtifactChanged()`
  - L156 `void _maybeOpenArtifactSheet()`
  - L165 `void didChangeAppLifecycleState(AppLifecycleState state)`
  - L182 `Future<void> _refreshSessionOnResume()`
  - L205 `Future<void> _ensurePermissions()`  — Re-check and request runtime permissions.
  - L234 `Future<void> _ensureBatteryOptimizationDisabled()`  — Ask the user to exempt the app from battery optimization.
  - L274 `void _showPermissionBlockedSnackBar(String permissionName)`
  - L285 `void _toggleSidebar()`
  - L300 `void _openSettingsPage()`
  - L310 `void _openWorkspacesPage()`
  - L343 `void _openMediaPage()`
  - L350 `void _handleChatSelected(String? chatId)`
  - L404 `Future<void> _handleChatDeleted(String deletedChatId)`
  - L422 `void _newChatFromAppBar()`
  - L432 `String? _currentChatTitle()`  — Title of the chat in view, or null for a fresh/unsaved chat.
  - L448 `Widget _buildFloatingTopBar(Color iconFg)`  — The composer's top row, rebuilt as free-floating blocks: a round menu
  - L531 `Widget _floatIconChip({ required IconData icon, required VoidCallback onTap, required Color iconFg, required String tooltip, required String semanticsId, })`  — One round, frosted icon chip for the floating top bar.
  - L561 `void _newChatFromSidebar()`
  - L570 `void _openArtifactSheet()`
  - L594 `void _copyDebugChat()`
  - L609 `Widget build(BuildContext context)`

## lib/platform_specific/root_wrapper_stub.dart  (19 Z.)

- L8 `class RootWrapper extends StatelessWidget`  — Web wrapper - renders desktop UI since web is a desktop-like environment
  - L9 `final AppShellConfig config`
  - L11 `const RootWrapper({super.key, required this.config})`
  - L14 `Widget build(BuildContext context)`

## lib/platform_specific/sidebar_desktop.dart  (520 Z.)

- L30 `class SidebarDesktop extends StatefulWidget`
  - L31 `final Function(String? chatId) onChatSelected`
  - L32 `final Function() onSettingsTapped`
  - L33 `final Function() onWorkspacesTapped`
  - L34 `final Function() onMediaTapped`
  - L35 `final Function() onNewChatTapped`
  - L36 `final Future<void> Function(String chatId)? onChatDeleted`
  - L40 `final VoidCallback? onCollapseTapped`  — Folds the sidebar back to the mini rail. Null hides the profile card's
  - L41 `final String? selectedChatId`
  - L42 `final bool isCompactMode`
  - L43 `final bool showWorkspacesButton`
  - L45 `const SidebarDesktop({ super.key, required this.onChatSelected, required this.onSettingsTapped, required this.onWorkspacesTapped, required this.onMediaTapped, required this.onNewChatTapped, this.onChatDeleted, this.onCollapseTapped, required this.selectedChatId, required this.isCompactMode, required this.showWorkspacesButton, })`
  - L60 `State<SidebarDesktop> createState()`
- L63 `class _SidebarDesktopState extends State<SidebarDesktop> with SidebarStateCommon<SidebarDesktop>`
  - L66 `Future<void> Function(String chatId)? get onChatDeletedCallback`
  - L70 `Future<void> applyChatFilter()`
  - L76 `void initState()`
  - L85 `void dispose()`
  - L93 `void _focusDesktopSearch()`
  - L97 `void _onDesktopSearchChanged()`
  - L105 `void _clearDesktopSearch()`
  - L113 `Future<void> _refreshDesktopChats()`
  - L124 `void _filterDesktopChats()`
  - L144 `void didUpdateWidget(covariant SidebarDesktop oldWidget)`
  - L152 `Widget build(BuildContext context)`
  - L210 `List<Widget> _buildDesktopSlivers(Color iconFg, Color accent)`
  - L284 `void _selectDesktopChat(StoredChat storedChat)`
  - L299 `Widget _buildDesktopChatItem( StoredChat chat, { VoidCallback? onTap, VoidCallback? onDelete, required Color accentColor, required Color iconFgColor, })`
  - L384 `void _openChatActionsMenu( BuildContext btnContext, StoredChat chat, { required Color accentColor, required Color iconFgColor, VoidCallback? onDelete, })`
  - L421 `void _handleMenuSelection( String value, StoredChat chat, VoidCallback? onDelete, )`
  - L440 `List<PopupMenuEntry<String>> _buildMenuItems( StoredChat chat, { required Color accentColor, required Color iconFgColor, })`
  - L492 `void _showChatContextMenu( BuildContext context, Offset position, StoredChat chat, { required Color accentColor, required Color iconFgColor, VoidCallback? onDelete, })`

## lib/platform_specific/sidebar_mobile.dart  (694 Z.)

- L29 `class SidebarMobile extends StatefulWidget`
  - L30 `final Function(String? chatId) onChatSelected`
  - L31 `final Function() onSettingsTapped`
  - L32 `final Function() onWorkspacesTapped`
  - L33 `final Function() onMediaTapped`
  - L34 `final Function() onNewChatTapped`
  - L35 `final Future<void> Function(String chatId)? onChatDeleted`
  - L38 `final VoidCallback? onCollapseTapped`  — Slides the drawer shut. Null hides the profile card's collapse button.
  - L39 `final String? selectedChatId`
  - L40 `final bool isCompactMode`
  - L42 `const SidebarMobile({ super.key, required this.onChatSelected, required this.onSettingsTapped, required this.onWorkspacesTapped, required this.onMediaTapped, required this.onNewChatTapped, this.onChatDeleted, this.onCollapseTapped, required this.selectedChatId, required this.isCompactMode, })`
  - L56 `State<SidebarMobile> createState()`
- L59 `class _SidebarMobileState extends State<SidebarMobile> with SidebarStateCommon<SidebarMobile>`
  - L61 `static const Duration _searchDebounceDuration = Duration(milliseconds: 300)`
  - L62 `static const int _searchMessageLimit = 50`
  - L63 `Future<void>? _refreshInFlight`
  - L64 `bool _refreshPending = false`
  - L65 `Timer? _searchDebounce`
  - L66 `int _filterGeneration = 0`
  - L69 `bool _searchActive = false`  — True while the search row shows the field instead of the nav card.
  - L72 `Future<void> Function(String chatId)? get onChatDeletedCallback`
  - L76 `Future<void> applyChatFilter()`
  - L79 `void initState()`
  - L89 `void dispose()`
  - L102 `void _focusMobileSearch()`  — Opens the search row and puts the caret in it. The row folds back into
  - L109 `void _onSearchFocusChanged()`
  - L116 `void _onMobileSearchChanged()`
  - L128 `void _clearMobileSearch()`
  - L141 `Future<void> _refreshMobileChatsFromGesture()`
  - L145 `Future<void> _refreshChats()`
  - L163 `Future<void> _performRefresh()`
  - L184 `Future<void> _filterMobileChats()`
  - L269 `List<StoredChat> _filterChatsLocally( List<StoredChat> chats, String lowerQuery, )`
  - L289 `void didUpdateWidget(covariant SidebarMobile oldWidget)`
  - L297 `Widget build(BuildContext context)`
  - L429 `List<Widget> _buildMobileSlivers(Color accent)`
  - L471 `List<Widget> _buildMobileNavigationCards()`
  - L500 `void _selectMobileChat(StoredChat storedChat)`
  - L509 `Widget _buildMobileChatItem( StoredChat chat, { VoidCallback? onTap, VoidCallback? onDelete, required Color accentColor, })`
  - L573 `void _showChatOptionsMenu( StoredChat chat, { Offset? at, VoidCallback? onDelete, required Color accentColor, required Color iconColor, })`  — The chat menu, opened where the finger was.
  - L627 `Widget _chatOptionRow({ required IconData icon, required Color iconColor, required String label, required VoidCallback onTap, Color? labelColor, })`  — One row of the chat menu. A plain [InkWell] — the tile around it carries
- L661 `List<String> _filterChatsIsolate(Map<String, dynamic> params)`
