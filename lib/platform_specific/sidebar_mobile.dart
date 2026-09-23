// lib/platform_specific/sidebar_mobile.dart
//
// Same structure as the desktop sidebar, and deliberately so: an account
// card, a navigation block, one block of chats per time group under its own
// header, and a bar at the foot with the search field and the two round
// actions. What differs here is only what the phone needs — a debounced,
// off-thread search and a bottom sheet instead of a right-click menu.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart';
import 'package:chuk_chat/widgets/update_banner.dart';

class SidebarMobile extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onWorkspacesTapped;
  final Function() onMediaTapped;
  final Function() onNewChatTapped;
  final Future<void> Function(String chatId)? onChatDeleted;

  /// Slides the drawer shut. Null hides the profile card's collapse button.
  final VoidCallback? onCollapseTapped;
  final String? selectedChatId;
  final bool isCompactMode; // Not directly used in the UI, but kept for context

  const SidebarMobile({
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
  });

  @override
  State<SidebarMobile> createState() => _SidebarMobileState();
}

class _SidebarMobileState extends State<SidebarMobile>
    with SidebarStateCommon<SidebarMobile> {
  static const Duration _searchDebounceDuration = Duration(milliseconds: 300);
  static const int _searchMessageLimit = 50;
  Future<void>? _refreshInFlight;
  bool _refreshPending = false;
  Timer? _searchDebounce;
  int _filterGeneration = 0;

  /// True while the search row shows the field instead of the nav card.
  bool _searchActive = false;

  @override
  Future<void> Function(String chatId)? get onChatDeletedCallback =>
      widget.onChatDeleted;

  @override
  Future<void> applyChatFilter() => _filterMobileChats();

  @override
  void initState() {
    super.initState();
    // Chat loading handled by AppInitializationService and ChatSyncService
    searchController.addListener(_onMobileSearchChanged);
    searchFocus.addListener(_onSearchFocusChanged);
    initSidebarCommon();
    unawaited(_filterMobileChats());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    searchFocus.removeListener(_onSearchFocusChanged);
    searchController.removeListener(_onMobileSearchChanged);
    disposeSidebarCommon();
    super.dispose();
  }

  // The Search nav card doesn't open a second field — it hands the caret to
  // the one already sitting in the bottom bar.
  /// Opens the search row and puts the caret in it. The row folds back into
  /// the plain nav card once the field is empty and no longer focused, so an
  /// abandoned search does not sit there forever.
  void _focusMobileSearch() {
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

  void _onMobileSearchChanged() {
    _searchDebounce?.cancel();
    displayLimit = kSidebarPageSize;
    // Repaint now so the field's own clear button appears with the first
    // keystroke; the expensive filtering still waits for the debounce.
    if (mounted) setState(() {});
    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      unawaited(_filterMobileChats());
    });
  }

  void _clearMobileSearch() {
    _searchDebounce?.cancel();
    _filterGeneration++;
    searchController.clear();
    if (!mounted) return;
    setState(() {
      searchQuery = '';
      filteredRecentChats = List<StoredChat>.from(
        ChatStorageService.savedChats,
      );
    });
  }

  Future<void> _refreshMobileChatsFromGesture() async {
    await _refreshChats();
  }

  Future<void> _refreshChats() {
    if (_refreshInFlight != null) {
      _refreshPending = true;
      return _refreshInFlight!;
    }

    final future = _performRefresh().whenComplete(() {
      final shouldRepeat = _refreshPending;
      _refreshInFlight = null;
      _refreshPending = false;
      if (shouldRepeat) {
        unawaited(_refreshChats());
      }
    });
    _refreshInFlight = future;
    return future;
  }

  Future<void> _performRefresh() async {
    try {
      // Use syncNow() instead of loadSavedChatsForSidebar() to fetch
      // from the server rather than redundantly reloading the local cache.
      // The sync service updates local state and fires notifyChanges().
      await ChatSyncService.syncNow();
      if (!mounted) return;
      await _filterMobileChats();
      setState(() {
        isOfflineMode = !NetworkStatusService.isOnline;
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('SidebarMobile chat sync failed: $error');
      }
      if (kDebugMode) {
        debugPrint('$stackTrace');
      }
    }
  }

  Future<void> _filterMobileChats() async {
    final String query = searchController.text.trim();
    final List<StoredChat> savedChats = ChatStorageService.savedChats;
    final int currentGeneration = ++_filterGeneration;

    if (query.isEmpty) {
      if (!mounted || currentGeneration != _filterGeneration) return;
      setState(() {
        searchQuery = '';
        filteredRecentChats = List<StoredChat>.from(savedChats);
      });
      return;
    }

    if (savedChats.isEmpty) {
      if (!mounted || currentGeneration != _filterGeneration) return;
      setState(() {
        searchQuery = query;
        filteredRecentChats = const <StoredChat>[];
      });
      return;
    }

    final String lowerQuery = query.toLowerCase();

    if (kIsWeb) {
      final List<StoredChat> filtered = _filterChatsLocally(
        savedChats,
        lowerQuery,
      );
      if (!mounted || currentGeneration != _filterGeneration) return;
      setState(() {
        searchQuery = query;
        filteredRecentChats = filtered;
      });
      return;
    }

    final List<Map<String, Object?>> payload = savedChats
        .map(
          (chat) => {
            'id': chat.id,
            'preview': deriveSidebarChatTitle(chat).toLowerCase(),
            'messages': (chat.messagesOrNull ?? const [])
                .take(_searchMessageLimit)
                .map((message) => message.text.toLowerCase())
                .toList(growable: false),
          },
        )
        .toList(growable: false);

    try {
      final List<String> matchIds = await compute(_filterChatsIsolate, {
        'chats': payload,
        'query': lowerQuery,
      });
      if (!mounted || currentGeneration != _filterGeneration) return;
      final Set<String> matchIdSet = matchIds.toSet();
      final List<StoredChat> latestChats = ChatStorageService.savedChats;
      final List<StoredChat> filtered = latestChats
          .where((chat) => matchIdSet.contains(chat.id))
          .toList(growable: false);
      setState(() {
        searchQuery = query;
        filteredRecentChats = filtered;
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('SidebarMobile filtering failed: $error');
      }
      if (kDebugMode) {
        debugPrint('$stackTrace');
      }
      if (!mounted || currentGeneration != _filterGeneration) return;
      final List<StoredChat> fallback = _filterChatsLocally(
        savedChats,
        lowerQuery,
      );
      setState(() {
        searchQuery = query;
        filteredRecentChats = fallback;
      });
    }
  }

  List<StoredChat> _filterChatsLocally(
    List<StoredChat> chats,
    String lowerQuery,
  ) {
    return chats
        .where((chat) {
          final bool titleMatches = deriveSidebarChatTitle(
            chat,
          ).toLowerCase().contains(lowerQuery);
          if (titleMatches) return true;
          return (chat.messagesOrNull ?? const [])
              .take(_searchMessageLimit)
              .any(
                (message) => message.text.toLowerCase().contains(lowerQuery),
              );
        })
        .toList(growable: false);
  }

  @override
  void didUpdateWidget(covariant SidebarMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    handleSidebarWidgetUpdate(
      selectedChatChanged: widget.selectedChatId != oldWidget.selectedChatId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color accentColor = theme.colorScheme.primary;
    final Color sidebarBg = sbPanelBackground(context);

    // Use the real device safe-area inset instead of a magic 40.0 — a fixed
    // value puts the first block under the dynamic island / camera notch on
    // devices with larger top insets.
    final EdgeInsets viewPadding = MediaQuery.paddingOf(context);

    // Both bars are cards that float over the list, not bands that box it
    // in: the chats run past them on every side, and the panel keeps its
    // full height for content.
    const double topChromeHeight = 58.0;
    const double bottomChromeHeight = 54.0;
    final double topInset = viewPadding.top + 8.0;
    final double bottomInset = 10.0 + viewPadding.bottom;

    // The navigation block is pinned under the head bar, as on the desktop:
    // three destinations that stay put while the chats pass behind them.
    final List<Widget> navCards = _buildMobileNavigationCards();
    final double navBlockTop = topInset + topChromeHeight;
    final double navBlockBottom =
        navBlockTop + navCards.length * kSbNavRowStep - kSbCardGap;

    return Container(
      color: sidebarBg,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              controller: scrollController,
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: SizedBox(height: navBlockBottom + 6),
                ),
                ..._buildMobileSlivers(accentColor),
                SliverToBoxAdapter(
                  child: SizedBox(height: bottomChromeHeight + bottomInset),
                ),
              ],
            ),
          ),

          Positioned(
            top: navBlockTop,
            left: 4,
            right: 4,
            child: SbBlock(joinTop: true, children: navCards),
          ),

          // The top of the sidebar names the app, not the person using it.
          // New chat is the first card of the block below, where the desktop
          // rail keeps it, so both sidebars read the same.
          Positioned(
            top: topInset,
            left: kSbBlockInset + 4,
            right: kSbBlockInset + 4,
            child: SbFloatingBar(
              // The block below joins it, so the corners tighten at the seam.
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(kSbCardRadius),
                topRight: Radius.circular(kSbCardRadius),
                bottomLeft: Radius.circular(kSbCardJointRadius),
                bottomRight: Radius.circular(kSbCardJointRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: SizedBox(
                  height: topChromeHeight - 12,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: BrandWordmark(color: theme.resolvedIconColor),
                        ),
                      ),
                      if (widget.onCollapseTapped != null) ...[
                        SbRoundAction(
                          icon: Icons.keyboard_double_arrow_left_rounded,
                          tooltip:
                              AppLocalizations.of(context)?.hideSidebar ??
                              'Hide sidebar',
                          diameter: 42,
                          iconSize: 22,
                          onTap: widget.onCollapseTapped!,
                        ),
                        const SizedBox(width: 6),
                      ],
                      // The one accent action of the panel sits at the very
                      // right, the outermost thing in the bar.
                      SbRoundAction(
                        icon: Icons.edit_square,
                        tooltip:
                            AppLocalizations.of(context)?.newChat ?? 'New chat',
                        diameter: 42,
                        iconSize: 22,
                        fill: theme.colorScheme.primary,
                        onTap: widget.onNewChatTapped,
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
                    // The home indicator sits below the box, so it keeps its
                    // own 6 px and adds what the device reserves.
                    padding: EdgeInsets.fromLTRB(
                      kSbBlockInset + 4,
                      6,
                      kSbBlockInset + 4,
                      bottomInset,
                    ),
                    child: SbAccountLine(
                      name: sidebarDisplayName(profile),
                      onTap: widget.onSettingsTapped,
                      onSettings: widget.onSettingsTapped,
                      balance: BalanceBadge(
                        textStyle: TextStyle(
                          color: accentColor,
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
  List<Widget> _buildMobileSlivers(Color accent) {
    final theme = Theme.of(context);
    return buildSidebarChatSlivers(
      leadingSlivers: <Widget>[
        if (isOfflineMode)
          SliverToBoxAdapter(
            child: SbOfflineNotice(
              label: 'Offline - cached chats',
              onRetry: () async {
                final isOnline = await NetworkStatusService.quickCheck();
                if (isOnline && mounted) {
                  await _refreshMobileChatsFromGesture();
                }
              },
            ),
          ),
      ],
      accent: accent,
      emptyTextColor: theme.m3.onSurfaceVariant,
      itemBuilder: (chat, index, length) => Padding(
        padding: const EdgeInsets.fromLTRB(
          kSbBlockInset,
          kSbCardGap,
          kSbBlockInset,
          0,
        ),
        child: SbCardShape(
          radius: sbBlockRadiusFor(index: index + 1, length: length + 1),
          child: _buildMobileChatItem(
            chat,
            onTap: () => _selectMobileChat(chat),
            onDelete: () => confirmAndDeleteSidebarChat(chat),
            accentColor: accent,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMobileNavigationCards() {
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
              onClear: _clearMobileSearch,
            ),
          )
        : SbNavCard(
            icon: Icons.search_rounded,
            label: AppLocalizations.of(context)?.search ?? 'Search',
            onTap: _focusMobileSearch,
          );
    return buildSidebarNavigationCards(
      context: context,
      showWorkspaces: true,
      onWorkspacesTapped: widget.onWorkspacesTapped,
      onMediaTapped: widget.onMediaTapped,
      onNewChatTapped: widget.onNewChatTapped,
      showNewChat: false,
      searchEntry: searchEntry,
    );
  }

  void _selectMobileChat(StoredChat storedChat) {
    if (kDebugMode) {
      debugPrint(
        '👆 [SIDEBAR-MOBILE] User tapped recent chat ${storedChat.id}',
      );
    }
    widget.onChatSelected(storedChat.id);
  }

  Widget _buildMobileChatItem(
    StoredChat chat, {
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
  }) {
    final theme = Theme.of(context);
    final bool isSelected = chat.id == widget.selectedChatId;
    final bool isLocked = chat.isLocked;
    final bool isStreaming = StreamingManager().isStreaming(chat.id);
    final String title = isLocked
        ? 'Locked encrypted chat'
        : deriveSidebarChatTitle(chat);
    void openMenu([Offset? at]) => _showChatOptionsMenu(
      chat,
      at: at,
      onDelete: onDelete,
      accentColor: accentColor,
      iconColor: theme.m3.onSurfaceVariant,
    );
    return SbChatTile(
      title: title,
      dateLine: sbChatDateLine(context, chat.updatedAt ?? chat.createdAt),
      selected: isSelected,
      locked: isLocked,
      streaming: isStreaming,
      onTap: isLocked
          ? () => showLockedSidebarChatDialog(accentColor: accentColor)
          : onTap,
      // The menu opens under the finger, not at the bottom of the screen.
      // The three-dot button is the second, visible way into the same menu.
      onLongPressAt: isLocked ? null : openMenu,
      trailing: isLocked
          ? null
          // The glyph stays small, but the box around it is Material's 48 px
          // minimum: it sits right beside the tile's own tap area, and a
          // near miss on a smaller target opens the chat instead of the
          // sheet.
          : SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                icon: AppIcon(
                  Icons.more_horiz_rounded,
                  size: 18,
                  color: theme.m3.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                splashRadius: 24,
                tooltip: 'Chat options',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: () => openMenu(),
              ),
            ),
    );
  }

  /// The chat menu, opened where the finger was.
  ///
  /// A bottom sheet put it at the far end of the screen from the row it
  /// belongs to; anchored, the menu comes out of the chat the user pressed.
  void _showChatOptionsMenu(
    StoredChat chat, {
    Offset? at,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconColor,
  }) {
    final bool isPinned = chat.isStarred;
    final theme = Theme.of(context);

    unawaited(
      showAnchoredMenu<void>(
        context,
        anchorPoint: at,
        color: theme.m3.surfaceContainerHigh,
        borderColor: Colors.transparent,
        minWidth: 216,
        items: [
          _chatOptionRow(
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            iconColor: isPinned ? accentColor : iconColor,
            label: isPinned ? 'Unpin chat' : 'Pin chat',
            onTap: () {
              Navigator.of(context).pop();
              unawaited(toggleSidebarChatStarred(chat));
            },
          ),
          _chatOptionRow(
            icon: Icons.edit_outlined,
            iconColor: iconColor,
            label: 'Rename',
            onTap: () {
              Navigator.of(context).pop();
              unawaited(renameSidebarChat(chat));
            },
          ),
          const Divider(height: 0),
          _chatOptionRow(
            icon: Icons.delete_outline,
            iconColor: Colors.redAccent.withValues(alpha: 0.8),
            label: 'Delete',
            labelColor: Colors.redAccent.withValues(alpha: 0.8),
            onTap: () {
              Navigator.of(context).pop();
              if (onDelete != null) onDelete();
            },
          ),
        ],
      ),
    );
  }

  /// One row of the chat menu. A plain [InkWell] — the tile around it carries
  /// the fill and the shape.
  Widget _chatOptionRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
    Color? labelColor,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 18),
            AppIcon(icon, color: iconColor, size: 21),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: labelColor ?? theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

List<String> _filterChatsIsolate(Map<String, dynamic> params) {
  final List<dynamic> chats = params['chats'] as List<dynamic>? ?? const [];
  final String query = params['query'] as String? ?? '';
  if (query.isEmpty || chats.isEmpty) {
    return const <String>[];
  }

  final List<String> matches = <String>[];
  for (final dynamic entry in chats) {
    final Map<dynamic, dynamic> chat = entry as Map<dynamic, dynamic>;
    final String? id = chat['id'] as String?;
    if (id == null) {
      continue;
    }

    final String preview = (chat['preview'] as String?) ?? '';
    if (preview.contains(query)) {
      matches.add(id);
      continue;
    }

    final List<dynamic> messages =
        chat['messages'] as List<dynamic>? ?? const [];
    final bool hasMatch = messages.any(
      (dynamic message) => (message as String).contains(query),
    );
    if (hasMatch) {
      matches.add(id);
    }
  }

  return matches;
}
