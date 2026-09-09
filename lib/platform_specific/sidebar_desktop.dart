// lib/platform_specific/sidebar_desktop.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/widgets/update_banner.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:flutter/foundation.dart';

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
  @override
  Future<void> Function(String chatId)? get onChatDeletedCallback =>
      widget.onChatDeleted;

  @override
  String get sidebarLogTag => 'SIDEBAR-DESKTOP';

  @override
  Future<void> applyChatFilter() async {
    if (!mounted) return;
    setState(_filterRecentChats);
  }

  @override
  void initState() {
    super.initState();
    _filterRecentChats(); // Filter cached chats immediately for instant UI
    // Chat loading handled by main.dart - we only listen to changes stream
    searchController.addListener(_onSearchChanged);
    searchFocus.addListener(_onSearchFocusChanged);
    initSidebarCommon();
  }

  @override
  void dispose() {
    searchController.removeListener(_onSearchChanged);
    searchFocus.removeListener(_onSearchFocusChanged);
    disposeSidebarCommon();
    super.dispose();
  }

  // Collapse the morphing search field back to the plain "Search" nav row
  // when the user clicks away and there is nothing to keep open. Anything
  // in the query is preserved — the row stays expanded so the filter view
  // sticks around until the user explicitly clears it.
  void _onSearchFocusChanged() {
    if (!mounted) return;
    if (searchFocus.hasFocus) return;
    if (searchQuery.isNotEmpty) return;
    if (!searchVisible) return;
    setState(() => searchVisible = false);
  }

  void _onSearchChanged() {
    setState(() {
      searchQuery = searchController.text;
      displayLimit = kSidebarPageSize;
      _filterRecentChats();
    });
  }

  void _clearSearchQuery() {
    searchController.clear();
  }

  // Refreshes chats from network via ChatSyncService and re-filters.
  // Uses syncNow() instead of loadSavedChatsForSidebar() to avoid
  // redundant local-cache reloads — the sync service fetches from the
  // server and updates local state, which triggers the changes stream.
  Future<void> _loadChatsAndRefresh() async {
    await ChatSyncService.syncNow();
    if (mounted) {
      setState(() {
        _filterRecentChats();
        isOfflineMode = !NetworkStatusService.isOnline;
      });
    }
  }

  // Filters ChatStorageService.savedChats based on searchQuery
  void _filterRecentChats() {
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
    // An active search re-filters through _onSearchChanged instead.
    handleSidebarWidgetUpdate(
      selectedChatChanged: widget.selectedChatId != oldWidget.selectedChatId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final SidebarPalette palette = SidebarPalette.of(context);
    final Color iconFg = palette.iconColor;
    final Color textColor = palette.textColor;
    final Color accent = palette.accent;
    final Color sidebarBg = palette.background;

    // Pinned chats live in their own bento card; rest go in a flat list.
    final List<StoredChat> pinnedChats =
        filteredRecentChats.where((c) => c.isStarred).toList();
    final List<StoredChat> restChats =
        filteredRecentChats.where((c) => !c.isStarred).toList();

    // Hamburger stays anchored to the top-left always — brand text starts
    // just to the right of it so the two share the same baseline.
    final double brandLeftPadding =
        kFixedLeftPadding + kMenuButtonHeight + 4;

    return Container(
      color: sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top spacer matches the hamburger's `top` offset.
          SizedBox(height: kTopInitialSpacing),

          // Brand row is exactly kMenuButtonHeight tall and vertically centred
          // — that puts "Chuk Chat" on the same baseline as the hamburger.
          SizedBox(
            height: kMenuButtonHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(brandLeftPadding, 0, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: BrandWordmark(color: palette.iconStrong),
              ),
            ),
          ),

          // The rail rows share a uniform pill width = the widest child's
          // intrinsic width. IntrinsicWidth measures the longest child,
          // then Column(stretch) forces every row to that width so the
          // hover pills look consistent rather than ragged.
          Align(
            alignment: Alignment.centerLeft,
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SbRailRow(
                    icon: Icons.edit_square,
                    label: 'New chat',
                    onTap: widget.onNewChatTapped,
                  ),
                  if (kFeatureWorkspaces && widget.showWorkspacesButton)
                    SbRailRow(
                      icon: Icons.folder_rounded,
                      label: 'Workspaces',
                      onTap: widget.onWorkspacesTapped,
                    ),
                  if (kFeatureMediaManager)
                    SbRailRow(
                      icon: Icons.image_rounded,
                      label: 'Media',
                      onTap: widget.onMediaTapped,
                    ),
                  if (!(searchVisible || searchQuery.isNotEmpty))
                    SbRailRow(
                      icon: Icons.search_rounded,
                      label: 'Search',
                      onTap: toggleSearch,
                    ),
                ],
              ),
            ),
          ),

          // Active search field sits below the rail rows so it can use the
          // full sidebar width — the inline morph happens in the same slot
          // visually because the inactive Search rail row above is removed
          // when active.
          if (searchVisible || searchQuery.isNotEmpty)
            _buildSearchRailRow(textColor, accent),

          const SizedBox(height: 10),

          if (isOfflineMode)
            SidebarOfflineBanner(
              onRetry: () async {
                final isOnline = await NetworkStatusService.quickCheck();
                if (isOnline && mounted) {
                  await _loadChatsAndRefresh();
                }
              },
            ),

          // Sticky pinned block above the scrolling time-bucketed list.
          // Capped height + internal scroll so many pinned chats don't push
          // the recent list offscreen.
          if (pinnedChats.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SidebarPinnedSection(
                accent: accent,
                tiles:
                    pinnedChats.map((c) => _chatTile(c, palette)).toList(),
              ),
            ),

          Expanded(
            child: Stack(
              children: [
                CustomScrollView(
                  controller: scrollController,
                  slivers: buildSidebarSlivers(
                    rest: restChats,
                    iconColor: iconFg,
                    accent: accent,
                    tileBuilder: (c) => _chatTile(c, palette),
                  ),
                ),
                // Sticky overlay header — exactly one bucket label visible
                // at the top at any time, swapped as the user scrolls past
                // each bucket boundary.
                if (currentBucket.isNotEmpty)
                  buildStickyBucketHeader(
                    accent: accent,
                    sidebarBg: sidebarBg,
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // No gradient scrim behind the footer. The fade banded
                      // into visible lines on some screens and made the
                      // transparency crawl unevenly as the list scrolled
                      // under it. The blocks carry their own uniform
                      // translucency (see SidebarFooterRow) and float over
                      // the list with nothing painted around them.
                      const SizedBox(height: 34),
                      const UpdateBanner(),
                      KeyedSubtree(
                        key: TourKeyRegistry.instance.keyFor(
                          TourSlots.settingsEntry,
                        ),
                        child: SidebarFooterRow(
                          name: sidebarDisplayNameFor(profile),
                          iconColor: iconFg,
                          textColor: textColor,
                          accent: accent,
                          sidebarBg: sidebarBg,
                          onSettingsTapped: widget.onSettingsTapped,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Inline search slot: SbRailRow until the user taps it, then morphs into
  // the original soft-rounded search field (same hint/prefix/suffix styling
  // as before — only the host position changed). Tapping the trailing X
  // collapses it back to the nav row.
  Widget _buildSearchRailRow(Color textColor, Color accent) {
    final bool active = searchVisible || searchQuery.isNotEmpty;
    if (!active) {
      return SbRailRow(
        icon: Icons.search_rounded,
        label: 'Search',
        onTap: toggleSearch,
      );
    }
    return SidebarSearchField(
      controller: searchController,
      focusNode: searchFocus,
      textColor: textColor,
      accent: accent,
      autofocus: true,
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      onClear: () {
        // Clearing a live query keeps the field open; a second tap on the
        // empty field collapses it back to the nav row.
        if (searchQuery.isNotEmpty) {
          _clearSearchQuery();
        } else {
          setState(() => searchVisible = false);
        }
      },
    );
  }

  void _onChatTapped(StoredChat storedChat) {
    if (ChatStorageService.isLoadingChat) {
      if (kDebugMode) {
        debugPrint(
          '🚫 [SIDEBAR-DESKTOP] BLOCKED - Chat is still loading',
        );
      }
      return;
    }
    if (kDebugMode) {
      debugPrint('👆 [SIDEBAR-DESKTOP] User tapped recent chat ${storedChat.id}');
    }
    widget.onChatSelected(storedChat.id);
  }

  /// One chat row. Desktop layers its own chrome on the shared tile: pin
  /// and options buttons that appear on hover, plus a right-click menu.
  Widget _chatTile(StoredChat chat, SidebarPalette palette) {
    final Color accentColor = palette.accent;
    final Color iconColor = palette.iconColor;
    final bool isLocked = chat.isLocked;
    final bool isPinned = chat.isStarred;
    final String title =
        isLocked ? 'Locked encrypted chat' : deriveSidebarChatTitle(chat);
    return SbChatTile(
      title: title,
      createdAt: chat.updatedAt ?? chat.createdAt,
      selected: chat.id == widget.selectedChatId,
      pinned: isPinned,
      locked: isLocked,
      streaming: StreamingManager().isStreaming(chat.id),
      onTap: isLocked
          ? () => showLockedChatDialog(accentColor: accentColor)
          : () => _onChatTapped(chat),
      onSecondaryTap: isLocked
          ? null
          : (pos) => _showChatContextMenu(
                context,
                pos,
                chat,
                accentColor: accentColor,
                iconFgColor: iconColor,
                onDelete: () => confirmAndDeleteChat(chat),
              ),
      trailingOnHover: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: IconButton(
              icon: Icon(
                isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 15,
                color:
                    isPinned ? accentColor : iconColor.withValues(alpha: 0.75),
              ),
              padding: EdgeInsets.zero,
              splashRadius: 14,
              visualDensity: VisualDensity.compact,
              tooltip: isPinned ? 'Unpin chat' : 'Pin chat',
              constraints:
                  const BoxConstraints.tightFor(width: 24, height: 24),
              onPressed: () => toggleStarred(chat),
            ),
          ),
          Builder(builder: (btnContext) {
            return SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 17,
                  color: iconColor.withValues(alpha: 0.75),
                ),
                padding: EdgeInsets.zero,
                splashRadius: 14,
                visualDensity: VisualDensity.compact,
                tooltip: 'Chat options',
                constraints:
                    const BoxConstraints.tightFor(width: 24, height: 24),
                onPressed: () => _openChatActionsMenu(
                  btnContext,
                  chat,
                  accentColor: accentColor,
                  iconFgColor: iconColor,
                  onDelete: () => confirmAndDeleteChat(chat),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // Opens the rename/pin/delete menu anchored to the three-dot button.
  // Uses the button's render box so the menu lands right beside the icon,
  // not at some far-off origin where it would be clipped or invisible.
  void _openChatActionsMenu(
    BuildContext btnContext,
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
    VoidCallback? onDelete,
  }) {
    final overlayState = Overlay.of(btnContext);
    final box = btnContext.findRenderObject() as RenderBox?;
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;
    final Offset topLeft =
        box.localToGlobal(Offset.zero, ancestor: overlayBox);
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
      items: _buildMenuItems(
        chat,
        accentColor: accentColor,
        iconFgColor: iconFgColor,
      ),
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
      case 'edit':
        renameChatDialog(chat);
        break;
      case 'delete':
        if (onDelete != null) onDelete();
        break;
    }
  }

  // Build menu items for both PopupMenuButton and context menu.
  // Pin/unpin is exposed as a dedicated hover button next to the three-dots
  // — keeping it out of the menu makes the common toggle a single click.
  List<PopupMenuEntry<String>> _buildMenuItems(
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
  }) {
    return [
      PopupMenuItem(
        value: 'edit',
        child: Row(
          children: [
            Icon(Icons.edit_outlined, color: iconFgColor, size: 20),
            const SizedBox(width: 12),
            const Text('Rename'),
          ],
        ),
      ),
      PopupMenuItem(
        value: 'delete',
        child: Row(
          children: [
            Icon(
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
    required Color accentColor,
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
      items: _buildMenuItems(
        chat,
        accentColor: accentColor,
        iconFgColor: iconFgColor,
      ),
    ).then((value) {
      if (value != null) {
        _handleMenuSelection(value, chat, onDelete);
      }
    });
  }
}
