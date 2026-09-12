// lib/platform_specific/sidebar_desktop.dart
//
// The desktop sidebar reads as a stack of blocks in the app's settings
// language: an account card, a navigation block, then one block of chats per
// time group under its own quiet header, and a bar at the foot carrying the
// search field and the two round actions. Everything above the foot scrolls
// as one column, so a short window spends its height on chats rather than on
// fixed chrome.
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
import 'package:chuk_chat/utils/color_extensions.dart';
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

  /// Folds the sidebar back to the mini rail. Null hides the profile card's
  /// collapse button, for a host that has no such state.
  final VoidCallback? onCollapseTapped;
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
    this.onCollapseTapped,
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
    initSidebarCommon();
  }

  @override
  void dispose() {
    searchController.removeListener(_onDesktopSearchChanged);
    disposeSidebarCommon();
    super.dispose();
  }

  // The Search nav card doesn't open a second field — it hands the caret to
  // the one already sitting in the bottom bar.
  void _focusDesktopSearch() {
    searchFocus.requestFocus();
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
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03);

    // Hamburger stays anchored to the top-left always — brand text starts
    // just to the right of it so the two share the same baseline.
    final double brandLeftPadding = kFixedLeftPadding + kMenuButtonHeight + 4;

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
                child: BrandWordmark(color: iconFg),
              ),
            ),
          ),

          Expanded(
            child: CustomScrollView(
              controller: scrollController,
              slivers: _buildDesktopSlivers(iconFg, accent),
            ),
          ),

          const UpdateBanner(),

          KeyedSubtree(
            key: TourKeyRegistry.instance.keyFor(TourSlots.settingsEntry),
            child: SbBottomBar(
              leading: SbSearchField(
                controller: searchController,
                focusNode: searchFocus,
                onClear: _clearDesktopSearch,
              ),
              onSettings: widget.onSettingsTapped,
              onNewChat: widget.onNewChatTapped,
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
        const SliverToBoxAdapter(child: SizedBox(height: 6)),
        SliverToBoxAdapter(
          child: SbBlock(
            children: [
              SbProfileCard(
                name: sidebarDisplayName(profile),
                onTap: widget.onSettingsTapped,
                onCollapse: widget.onCollapseTapped,
                subtitle: BalanceBadge(
                  textStyle: TextStyle(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  placeholderStyle: TextStyle(
                    color: Theme.of(context).m3.onSurfaceVariant,
                    fontSize: 13,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: SbBlock(
            children: buildSidebarNavigationCards(
              context: context,
              showWorkspaces: widget.showWorkspacesButton,
              onWorkspacesTapped: widget.onWorkspacesTapped,
              onMediaTapped: widget.onMediaTapped,
              searchEntry: SbNavCard(
                icon: Icons.search_rounded,
                label: AppLocalizations.of(context)?.search ?? 'Search',
                onTap: _focusDesktopSearch,
              ),
            ),
          ),
        ),
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
        padding: EdgeInsets.fromLTRB(
          kSbBlockInset,
          0,
          kSbBlockInset,
          index == length - 1 ? 0 : kSbCardGap,
        ),
        child: _buildDesktopChatItem(
          chat,
          onTap: () => _selectDesktopChat(chat),
          onDelete: () => confirmAndDeleteSidebarChat(chat),
          accentColor: accent,
          iconFgColor: iconFg,
        ),
      ),
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
              accentColor: accentColor,
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
                accentColor: accentColor,
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
    required Color accentColor,
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
  List<PopupMenuEntry<String>> _buildMenuItems(
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
  }) {
    final bool isPinned = chat.isStarred;
    return [
      PopupMenuItem(
        value: 'pin',
        child: Row(
          children: [
            AppIcon(
              isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              color: isPinned ? accentColor : iconFgColor,
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(isPinned ? 'Unpin' : 'Pin'),
          ],
        ),
      ),
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
