// lib/platform_specific/sidebar_mobile.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/widgets/accent_icon_button.dart';
import 'package:chuk_chat/widgets/update_banner.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart';

class SidebarMobile extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onWorkspacesTapped;
  final Function() onMediaTapped;
  final Function() onNewChatTapped;
  final Future<void> Function(String chatId)? onChatDeleted;
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

  @override
  Future<void> Function(String chatId)? get onChatDeletedCallback =>
      widget.onChatDeleted;

  @override
  String get sidebarLogTag => 'SIDEBAR-MOBILE';

  @override
  Future<void> applyChatFilter() => _filterRecentChats();

  @override
  void initState() {
    super.initState();
    // Chat loading handled by AppInitializationService and ChatSyncService
    searchController.addListener(_onSearchChanged);
    initSidebarCommon();
    unawaited(_filterRecentChats());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    searchController.removeListener(_onSearchChanged);
    disposeSidebarCommon();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    displayLimit = kSidebarPageSize;
    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      unawaited(_filterRecentChats());
    });
  }

  void _clearSearchQuery() {
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

  Future<void> _loadChatsAndRefresh() async {
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
      await _filterRecentChats();
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

  Future<void> _filterRecentChats() async {
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
    final l = AppLocalizations.of(context)!;
    final SidebarPalette palette = SidebarPalette.of(context);
    final Color iconColorDefault = palette.iconColor;
    final Color textColorDefault = palette.textColor;
    final Color accentColor = palette.accent;
    final Color sidebarBg = palette.background;

    final List<StoredChat> pinnedChats =
        filteredRecentChats.where((c) => c.isStarred).toList();
    final List<StoredChat> restChats =
        filteredRecentChats.where((c) => !c.isStarred).toList();

    // Use the real device safe-area inset instead of a magic 40.0 — a
    // fixed value puts the brand row under the dynamic island / camera
    // notch on devices with larger top insets. Add 8 px of breathing
    // room on top of the inset so the brand sits visually below the
    // status indicators, not flush against them.
    final double topStatusBarSpacing =
        MediaQuery.paddingOf(context).top + 8.0;
    final bool showSearchField = searchVisible || searchQuery.isNotEmpty;

    return Container(
      color: sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: topStatusBarSpacing),

          SbBrand(
            label: 'Chuk Chat',
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 12),
            trailing: AccentIconButton(
              icon: Icons.edit_square,
              onTap: widget.onNewChatTapped,
              accent: accentColor,
              tooltip: 'New Chat',
              semanticsId: 'sidebar_new_chat_button',
            ),
          ),

          // Match desktop ordering: Workspaces → Media → Search at the bottom.
          // The Search row morphs in-place into the input field when tapped
          // (search row disappears, input takes the same slot) so the text
          // field never pushes other rows out of place.
          if (kFeatureWorkspaces)
            SbNavItem(
              icon: Icons.folder_rounded,
              label: l.workspaces,
              onTap: widget.onWorkspacesTapped,
            ),
          if (kFeatureMediaManager)
            SbNavItem(
              icon: Icons.image_rounded,
              label: l.media,
              onTap: widget.onMediaTapped,
            ),
          if (!showSearchField)
            SbNavItem(
              icon: Icons.search_rounded,
              label: 'Search',
              onTap: toggleSearch,
            ),
          if (showSearchField)
            SidebarSearchField(
              controller: searchController,
              focusNode: searchFocus,
              textColor: textColorDefault,
              accent: accentColor,
              onClear: () {
                // Tapping the X always collapses the search row back —
                // mirrors desktop. The text is cleared on the way out so a
                // future re-open starts fresh.
                _clearSearchQuery();
                setState(() => searchVisible = false);
              },
            ),
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

          Expanded(
            child: Stack(
              children: [
                Column(
                  children: [
                    if (pinnedChats.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: SidebarPinnedSection(
                          accent: accentColor,
                          tiles: pinnedChats
                              .map((c) => _chatTile(c, palette))
                              .toList(),
                        ),
                      ),
                    Expanded(
                      child: Stack(
                        children: [
                          CustomScrollView(
                            controller: scrollController,
                            slivers: buildSidebarSlivers(
                              rest: restChats,
                              iconColor: iconColorDefault,
                              accent: accentColor,
                              tileBuilder: (c) => _chatTile(c, palette),
                            ),
                          ),
                          if (currentBucket.isNotEmpty)
                            buildStickyBucketHeader(
                              accent: accentColor,
                              sidebarBg: sidebarBg,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // No gradient scrim behind the footer any more. The
                      // top-to-bottom fade banded into visible lines on some
                      // screens and made the transparency crawl unevenly as
                      // the list scrolled under it. The blocks now carry their
                      // own uniform translucency (see SidebarFooterRow) and
                      // float over the list with nothing painted around them.
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 34),
                          const UpdateBanner(),
                          KeyedSubtree(
                            key: TourKeyRegistry.instance.keyFor(
                              TourSlots.settingsEntry,
                            ),
                            child: SidebarFooterRow(
                              name: sidebarDisplayNameFor(profile),
                              iconColor: iconColorDefault,
                              textColor: textColorDefault,
                              accent: accentColor,
                              sidebarBg: sidebarBg,
                              onSettingsTapped: widget.onSettingsTapped,
                            ),
                          ),
                        ],
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

  void _onChatTapped(StoredChat storedChat) {
    if (kDebugMode) {
      debugPrint(
        '👆 [SIDEBAR-MOBILE] User tapped recent chat ${storedChat.id}',
      );
    }
    widget.onChatSelected(storedChat.id);
  }

  /// One chat row. Long-press opens the options sheet; a locked chat
  /// explains itself instead of opening.
  Widget _chatTile(StoredChat chat, SidebarPalette palette) {
    final bool isLocked = chat.isLocked;
    final String title =
        isLocked ? 'Locked encrypted chat' : deriveSidebarChatTitle(chat);
    return SbChatTile(
      title: title,
      createdAt: chat.updatedAt ?? chat.createdAt,
      selected: chat.id == widget.selectedChatId,
      pinned: chat.isStarred,
      locked: isLocked,
      onTap: isLocked
          ? () => showLockedChatDialog(accentColor: palette.accent)
          : () => _onChatTapped(chat),
      onLongPress: isLocked
          ? null
          : () => _showChatOptionsBottomSheet(
                chat,
                onDelete: () => confirmAndDeleteChat(chat),
                accentColor: palette.accent,
                iconColor: palette.iconColor,
              ),
    );
  }

  void _showChatOptionsBottomSheet(
    StoredChat chat, {
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconColor,
  }) {
    final bool isPinned = chat.isStarred;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: isPinned ? accentColor : iconColor,
                ),
                title: Text(isPinned ? 'Unpin chat' : 'Pin chat'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  toggleStarred(chat);
                },
              ),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: iconColor),
                title: const Text('Rename'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  renameChatDialog(chat);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent.withValues(alpha: 0.8),
                ),
                title: Text(
                  'Delete',
                  style: TextStyle(
                    color: Colors.redAccent.withValues(alpha: 0.8),
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (onDelete != null) onDelete();
                },
              ),
            ],
          ),
        );
      },
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
