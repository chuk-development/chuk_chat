// lib/platform_specific/sidebar_desktop.dart
//
// The desktop sidebar is laid out exactly like the phone one: a floating bar
// at the head carrying the app name and the new-chat button, a navigation
// block whose Search row turns into the field, one block of chats per time
// group under its own quiet header, and a floating account line at the foot.
// Both bars are cards over the list rather than bands boxing it in, so the
// chats keep the panel's full height and run past the chrome on every side.
// What differs from the phone is only what a mouse brings: hover actions, a
// right-click menu, and a synchronous filter.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart';
import 'package:chuk_chat/widgets/update_banner.dart';

class SidebarDesktop extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onWorkspacesTapped;
  final Function() onMediaTapped;
  final Function() onNewChatTapped;
  final Future<void> Function(String chatId)? onChatDeleted;

  final String? selectedChatId;
  final bool isCompactMode;
  final bool showWorkspacesButton;

  const SidebarDesktop({
    super.key,
    required this.onChatSelected,
    required this.onSettingsTapped,
    required this.onWorkspacesTapped,
    required this.onMediaTapped,
    required this.onNewChatTapped,
    this.onChatDeleted,
    required this.selectedChatId,
    required this.isCompactMode,
    required this.showWorkspacesButton,
  });

  @override
  State<SidebarDesktop> createState() => _SidebarDesktopState();
}

class _SidebarDesktopState extends State<SidebarDesktop>
    with SidebarStateCommon<SidebarDesktop> {
  /// True while the Search row shows the field instead of the nav card.
  bool _searchActive = false;

  @override
  Future<void> Function(String chatId)? get onChatDeletedCallback =>
      widget.onChatDeleted;

  @override
  Future<void> applyChatFilter() async {
    if (!mounted) return;
    setState(_filterDesktopChats);
  }

  @override
  void initState() {
    super.initState();
    _filterDesktopChats(); // Filter cached chats immediately for instant UI
    // Chat loading handled by main.dart - we only listen to changes stream
    searchController.addListener(_onDesktopSearchChanged);
    searchFocus.addListener(_onSearchFocusChanged);
    initSidebarCommon();
  }

  @override
  void dispose() {
    searchFocus.removeListener(_onSearchFocusChanged);
    searchController.removeListener(_onDesktopSearchChanged);
    disposeSidebarCommon();
    super.dispose();
  }

  /// Opens the search row and puts the caret in it. The row folds back into
  /// the plain nav card once the field is empty and no longer focused, so an
  /// abandoned search does not sit there forever.
  void _focusDesktopSearch() {
    setState(() => _searchActive = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) searchFocus.requestFocus();
    });
  }

  void _onSearchFocusChanged() {
    if (searchFocus.hasFocus) return;
    if (searchController.text.isNotEmpty) return;
    if (!mounted) return;
    setState(() => _searchActive = false);
  }

  void _onDesktopSearchChanged() {
    setState(() {
      searchQuery = searchController.text;
      displayLimit = kSidebarPageSize;
      _filterDesktopChats();
    });
  }

  void _clearDesktopSearch() {
    searchController.clear();
  }

  // Refreshes chats from network via ChatSyncService and re-filters.
  // Uses syncNow() instead of loadSavedChatsForSidebar() to avoid
  // redundant local-cache reloads — the sync service fetches from the
  // server and updates local state, which triggers the changes stream.
  Future<void> _refreshDesktopChats() async {
    await ChatSyncService.syncNow();
    if (mounted) {
      setState(() {
        _filterDesktopChats();
        isOfflineMode = !NetworkStatusService.isOnline;
      });
    }
  }

  // Filters ChatStorageService.savedChats based on _searchQuery
  void _filterDesktopChats() {
    if (searchQuery.isEmpty) {
      filteredRecentChats = List<StoredChat>.from(
        ChatStorageService.savedChats,
      ); // Use List.from to create a mutable copy
    } else {
      final lowerQuery = searchQuery.toLowerCase();
      filteredRecentChats = ChatStorageService.savedChats.where((chat) {
        final titleMatches = deriveSidebarChatTitle(
          chat,
        ).toLowerCase().contains(lowerQuery);
        if (titleMatches) return true;
        return (chat.messagesOrNull ?? const []).any(
          (message) => message.text.toLowerCase().contains(lowerQuery),
        );
      }).toList();
    }
  }

  @override
  void didUpdateWidget(covariant SidebarDesktop oldWidget) {
    super.didUpdateWidget(oldWidget);
    handleSidebarWidgetUpdate(
      selectedChatChanged: widget.selectedChatId != oldWidget.selectedChatId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    final Color accent = theme.colorScheme.primary;
    final Color sidebarBg = sbPanelBackground(context);

    // Hamburger stays anchored to the top-left of the window, on top of this
    // panel — the brand text starts just right of it, and the head bar is as
    // tall as the hamburger's box so the two share one centre line.
    final double brandLeftPadding = kFixedLeftPadding + kMenuButtonHeight + 4;

    // The pinned block: its rows are known before the list is built, so the
    // list can leave exactly their height free at the top.
    final List<Widget> navCards = _buildDesktopNavigationCards();
    final double navBlockBottom =
        kSbNavBlockTop + navCards.length * kSbNavRowStep - kSbCardGap;
    const double topChromeHeight = kMenuButtonHeight;
    const double bottomChromeHeight = 54.0;
    const double topInset = kTopInitialSpacing;
    const double bottomInset = 10.0;

    return Container(
      color: sidebarBg,
      child: Stack(
        children: [
          Positioned.fill(
            // No scrollbar: the desktop default draws one over the cards,
            // and the list already says where it stands through its group
            // headers.
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: CustomScrollView(
                controller: scrollController,
                slivers: <Widget>[
                  SliverToBoxAdapter(
                    // Room for the head bar and the pinned navigation block,
                    // both of which float over this list rather than scroll
                    // with it. The chats start under them and run behind
                    // them on the way up.
                    child: SizedBox(height: navBlockBottom + 6),
                  ),
                  ..._buildDesktopSlivers(iconFg, accent),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: bottomChromeHeight + bottomInset),
                  ),
                ],
              ),
            ),
          ),

          // The navigation block is chrome, not a list item: the three
          // destinations stay where they are and the chats disappear under
          // them, the way the head bar above already works.
          Positioned(
            top: kSbNavBlockTop,
            left: 0,
            right: 0,
            child: SbBlock(joinTop: true, children: navCards),
          ),

          // The head of the sidebar names the app, and nothing else: the
          // one action that starts something, a new chat, is the first card
          // of the block below — the row the collapsed rail keeps it on.
          Positioned(
            top: topInset,
            left: kSbBlockInset,
            right: kSbBlockInset,
            child: SbFloatingBar(
              // The block below starts flush against this bar, so the two
              // read as one run: round on top, tight at the joint.
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(kSbCardRadius),
                topRight: Radius.circular(kSbCardRadius),
                bottomLeft: Radius.circular(kSbCardJointRadius),
                bottomRight: Radius.circular(kSbCardJointRadius),
              ),
              child: SizedBox(
                height: topChromeHeight,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(brandLeftPadding - 8, 0, 6, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: BrandWordmark(color: iconFg),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const UpdateBanner(),
                KeyedSubtree(
                  key: TourKeyRegistry.instance.keyFor(TourSlots.settingsEntry),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      kSbBlockInset,
                      6,
                      kSbBlockInset,
                      bottomInset,
                    ),
                    child: SbAccountLine(
                      name: sidebarDisplayName(profile),
                      onTap: widget.onSettingsTapped,
                      onSettings: widget.onSettingsTapped,
                      balance: BalanceBadge(
                        textStyle: TextStyle(
                          color: accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        placeholderStyle: TextStyle(
                          color: theme.m3.onSurfaceVariant,
                          fontSize: 13,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The whole scrolling column, top to bottom: account, navigation, the
  // offline notice, then one header + block per time group.
  List<Widget> _buildDesktopSlivers(Color iconFg, Color accent) {
    return buildSidebarChatSlivers(
      leadingSlivers: <Widget>[
        if (isOfflineMode)
          SliverToBoxAdapter(
            child: SbOfflineNotice(
              label: 'Offline - showing cached chats',
              onRetry: () async {
                final isOnline = await NetworkStatusService.quickCheck();
                if (isOnline && mounted) await _refreshDesktopChats();
              },
            ),
          ),
      ],
      accent: accent,
      emptyTextColor: iconFg.withValues(alpha: 0.5),
      itemBuilder: (chat, index, length) => Padding(
        padding: const EdgeInsets.fromLTRB(
          kSbBlockInset,
          kSbCardGap,
          kSbBlockInset,
          0,
        ),
        child: SbCardShape(
          radius: sbBlockRadiusFor(index: index + 1, length: length + 1),
          child: _buildDesktopChatItem(
            chat,
            onTap: () => _selectDesktopChat(chat),
            onDelete: () => confirmAndDeleteSidebarChat(chat),
            accentColor: accent,
            iconFgColor: iconFg,
          ),
        ),
      ),
    );
  }

  /// The navigation block. The Search row is the field itself once it is
  /// open, so the sidebar never holds two places to type a query.
  List<Widget> _buildDesktopNavigationCards() {
    final Widget searchEntry = _searchActive
        ? SbCard(
            // Its own, even corners rather than the block's: a ring that
            // runs round two tight joints and two wide corners reads as a
            // drawing mistake, not as a field.
            outlined: true,
            radius: kSbCardRadius,
            padding: EdgeInsets.zero,
            minHeight: kSbNavCardHeight,
            child: SbSearchField(
              controller: searchController,
              focusNode: searchFocus,
              transparent: true,
              onClear: _clearDesktopSearch,
            ),
          )
        : SbNavCard(
            icon: Icons.search_rounded,
            label: AppLocalizations.of(context)?.search ?? 'Search',
            onTap: _focusDesktopSearch,
          );
    return buildSidebarNavigationCards(
      context: context,
      showWorkspaces: widget.showWorkspacesButton,
      onWorkspacesTapped: widget.onWorkspacesTapped,
      onMediaTapped: widget.onMediaTapped,
      onNewChatTapped: widget.onNewChatTapped,
      searchEntry: searchEntry,
    );
  }

  void _selectDesktopChat(StoredChat storedChat) {
    if (ChatStorageService.isLoadingChat) {
      if (kDebugMode) {
        debugPrint('🚫 [SIDEBAR-DESKTOP] BLOCKED - Chat is still loading');
      }
      return;
    }
    if (kDebugMode) {
      debugPrint(
        '👆 [SIDEBAR-DESKTOP] User tapped recent chat ${storedChat.id}',
      );
    }
    widget.onChatSelected(storedChat.id);
  }

  Widget _buildDesktopChatItem(
    StoredChat chat, {
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconFgColor,
  }) {
    final bool isSelected = chat.id == widget.selectedChatId;
    final bool isStreaming = StreamingManager().isStreaming(chat.id);
    final String title = chat.isLocked
        ? 'Locked encrypted chat'
        : deriveSidebarChatTitle(chat);
    final bool isLocked = chat.isLocked;
    final bool isPinned = chat.isStarred;
    return SbChatTile(
      title: title,
      dateLine: sbChatDateLine(context, chat.updatedAt ?? chat.createdAt),
      selected: isSelected,
      locked: isLocked,
      streaming: isStreaming,
      onTap: isLocked
          ? () => showLockedSidebarChatDialog(accentColor: accentColor)
          : onTap,
      onSecondaryTap: isLocked
          ? null
          : (pos) => _showChatContextMenu(
              context,
              pos,
              chat,
              iconFgColor: iconFgColor,
              onDelete: onDelete,
            ),
      // Pin stays a one-click toggle on hover; the same action is in the
      // menu for anyone who never hovers.
      hoverTrailing: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          icon: AppIcon(
            isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            size: 16,
            color: isPinned ? accentColor : iconFgColor.withValues(alpha: 0.75),
          ),
          padding: EdgeInsets.zero,
          splashRadius: 16,
          visualDensity: VisualDensity.compact,
          tooltip: isPinned ? 'Unpin chat' : 'Pin chat',
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          onPressed: () => toggleSidebarChatStarred(chat),
        ),
      ),
      trailing: Builder(
        builder: (btnContext) {
          return SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              icon: AppIcon(
                Icons.more_horiz_rounded,
                size: 18,
                color: iconFgColor.withValues(alpha: 0.75),
              ),
              padding: EdgeInsets.zero,
              splashRadius: 16,
              visualDensity: VisualDensity.compact,
              tooltip: 'Chat options',
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: () => _openChatActionsMenu(
                btnContext,
                chat,
                iconFgColor: iconFgColor,
                onDelete: onDelete,
              ),
            ),
          );
        },
      ),
    );
  }

  // Opens the rename/pin/delete menu anchored to the three-dot button.
  // Uses the button's render box so the menu lands right beside the icon,
  // not at some far-off origin where it would be clipped or invisible.
  void _openChatActionsMenu(
    BuildContext btnContext,
    StoredChat chat, {
    required Color iconFgColor,
    VoidCallback? onDelete,
  }) {
    final overlayState = Overlay.of(btnContext);
    final box = btnContext.findRenderObject() as RenderBox?;
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;
    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final Offset bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlayBox,
    );
    showMenu<String>(
      context: btnContext,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        bottomRight.dy,
        overlayBox.size.width - bottomRight.dx,
        overlayBox.size.height - bottomRight.dy,
      ),
      items: _buildMenuItems(iconFgColor: iconFgColor),
    ).then((value) {
      if (value != null) {
        _handleMenuSelection(value, chat, onDelete);
      }
    });
  }

  // Handle menu item selection
  void _handleMenuSelection(
    String value,
    StoredChat chat,
    VoidCallback? onDelete,
  ) {
    switch (value) {
      case 'pin':
        unawaited(toggleSidebarChatStarred(chat));
        break;
      case 'edit':
        unawaited(renameSidebarChat(chat));
        break;
      case 'delete':
        if (onDelete != null) onDelete();
        break;
    }
  }

  // Build menu items for both the three-dot button and the right-click menu.
  List<PopupMenuEntry<String>> _buildMenuItems({required Color iconFgColor}) {
    // No pin entry here: the tile carries the pin as a one-click toggle on
    // hover, and the same action twice in one row is one too many.
    return [
      PopupMenuItem(
        value: 'edit',
        child: Row(
          children: [
            AppIcon(Icons.edit_outlined, color: iconFgColor, size: 20),
            const SizedBox(width: 12),
            const Text('Rename'),
          ],
        ),
      ),
      PopupMenuItem(
        value: 'delete',
        child: Row(
          children: [
            AppIcon(
              Icons.delete_outline,
              color: Colors.redAccent.withValues(alpha: 0.8),
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    ];
  }

  // Show context menu on right-click
  void _showChatContextMenu(
    BuildContext context,
    Offset position,
    StoredChat chat, {
    required Color iconFgColor,
    VoidCallback? onDelete,
  }) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: _buildMenuItems(iconFgColor: iconFgColor),
    ).then((value) {
      if (value != null) {
        _handleMenuSelection(value, chat, onDelete);
      }
    });
  }
}
