// lib/platform_specific/sidebar_desktop.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';

class SidebarDesktop extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
  final Function() onMediaTapped;
  final Future<void> Function(String chatId)? onChatDeleted;
  final String? selectedChatId;
  final bool isCompactMode;
  final bool showAssistantsButton;

  const SidebarDesktop({
    super.key,
    required this.onChatSelected,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    required this.onMediaTapped,
    this.onChatDeleted,
    required this.selectedChatId,
    required this.isCompactMode,
    required this.showAssistantsButton,
  });

  @override
  State<SidebarDesktop> createState() => _SidebarDesktopState();
}

class _SidebarDesktopState extends State<SidebarDesktop> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;
  static const double _iconLeadingWidth =
      24.0; // Standard icon width for alignment
  static const double _iconTextSpacing = 16.0; // Spacing between icon and text

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<StoredChat> _filteredRecentChats = [];
  ProfileRecord? _profile;
  StreamSubscription<String?>? _chatUpdatesSub;
  Timer? _deleteNotificationTimer;
  String? _lastDeletedChatTitle;
  bool _isOfflineMode = false;

  @override
  void initState() {
    super.initState();
    _filterRecentChats(); // Filter cached chats immediately for instant UI
    // Chat loading handled by main.dart - we only listen to changes stream
    _searchController.addListener(_onSearchChanged);
    unawaited(_loadProfile()); // Don't block on profile load
    _chatUpdatesSub = ChatStorageService.changes.listen((changedChatId) {
      if (!mounted) return;
      if (changedChatId == null) {
        // Bulk change (initial load, sync) - refilter everything
        setState(() {
          _filterRecentChats();
        });
      } else {
        // Single chat changed - just trigger rebuild without refiltering
        // The chat data is already updated in ChatStorageService
        setState(() {});
      }
    });
    // Monitor network status for offline indicators
    NetworkStatusService.isOnlineListenable.addListener(
      _onNetworkStatusChanged,
    );
  }

  @override
  void dispose() {
    _chatUpdatesSub?.cancel();
    _deleteNotificationTimer?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      _onNetworkStatusChanged,
    );
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
      _filterRecentChats();
    });
  }

  void _onNetworkStatusChanged() {
    if (!mounted) return;
    setState(() {
      // Update offline status when network changes
      _isOfflineMode = !NetworkStatusService.isOnline;
    });
  }

  void _clearSearchQuery() {
    _searchController.clear();
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
        _isOfflineMode = !NetworkStatusService.isOnline;
      });
    }
  }

  // Filters ChatStorageService.savedChats based on _searchQuery
  void _filterRecentChats() {
    if (_searchQuery.isEmpty) {
      _filteredRecentChats = List<StoredChat>.from(
        ChatStorageService.savedChats,
      ); // Use List.from to create a mutable copy
    } else {
      final lowerQuery = _searchQuery.toLowerCase();
      _filteredRecentChats = ChatStorageService.savedChats.where((chat) {
        final titleMatches = _deriveChatTitle(
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
    if (widget.selectedChatId != oldWidget.selectedChatId) {
      if (mounted) setState(() {});
    }
    // Check if the underlying saved chats list has changed (e.g., new chat added)
    // and refresh the filtered list if search query is empty (showing all).
    // If _searchQuery is not empty, _onSearchChanged will handle re-filtering.
    if (ChatStorageService.savedChats.length != _filteredRecentChats.length &&
        _searchQuery.isEmpty) {
      _filterRecentChats();
    }
  }

  Future<void> _loadProfile() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    try {
      final record = await const ProfileService().loadOrCreateProfile();
      if (!mounted) return;
      setState(() {
        _profile = record;
      });
    } catch (_) {
      // Silently ignore profile load errors; sidebar will show fallback label.
    }
  }

  String _displayNameFor(ProfileRecord? profile) {
    if (profile == null) return 'Account';
    if (profile.displayName.trim().isNotEmpty) {
      return profile.displayName.trim();
    }
    if (profile.email.trim().isNotEmpty) {
      return profile.email.trim();
    }
    return 'Account';
  }

  String _deriveChatTitle(StoredChat chat) {
    // Priority: customName > title (from encrypted_title) > previewText
    // customName: User-renamed or AI-generated title stored in payload
    // title: Fast-loaded decrypted title for sidebar
    // previewText: Fallback derived from first user message
    return chat.customName ?? chat.title ?? chat.previewText;
  }

  Future<void> _toggleStarred(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChatStorageService.setChatStarred(chat.id, !chat.isStarred);
      if (!mounted) return;
      setState(() {
        _filterRecentChats();
      });
    } on StateError catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to update star: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    }
  }

  void _openChat(StoredChat chat) {
    // CRITICAL: Block rapid chat switching while another chat is loading
    // This prevents race conditions that cause data corruption
    if (ChatStorageService.isLoadingChat) {
      if (kDebugMode) {
        debugPrint('');
      }
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }
      if (kDebugMode) {
        debugPrint('🚫 [SIDEBAR] BLOCKED - Chat is still loading');
      }
      if (kDebugMode) {
        debugPrint(
          '🚫 [SIDEBAR] User tried to click: "${chat.previewText.substring(0, chat.previewText.length > 30 ? 30 : chat.previewText.length)}..."',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
      }
      return;
    }
    if (kDebugMode) {
      debugPrint('');
    }
    if (kDebugMode) {
      debugPrint('═══════════════════════════════════════════════════════════');
    }
    if (kDebugMode) {
      debugPrint(
        '👆 [SIDEBAR] User clicked chat: "${chat.previewText.substring(0, chat.previewText.length > 30 ? 30 : chat.previewText.length)}..."',
      );
    }
    if (kDebugMode) {
      debugPrint('👆 [SIDEBAR] Chat ID: ${chat.id}');
    }
    if (kDebugMode) {
      debugPrint('👆 [SIDEBAR] Calling onChatSelected(${chat.id})');
    }
    if (kDebugMode) {
      debugPrint('═══════════════════════════════════════════════════════════');
    }
    widget.onChatSelected(chat.id);
  }

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03);
    final Color dividerColor = Theme.of(
      context,
    ).dividerColor.withValues(alpha: 0.5);
    final List<StoredChat> starredChats = ChatStorageService.savedChats
        .where((chat) => chat.isStarred)
        .toList();

    // The height of the top bar is calculated dynamically for desktop.
    // "New Chat" and "Projects" buttons are positioned *outside* this sidebar widget
    // in `root_wrapper_desktop.dart`. This spacing accounts for them so sidebar
    // content doesn't overlap those fixed overlay buttons.
    double topSpacingForSidebarContent =
        kTopInitialSpacing +
        kMenuButtonHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight + // New Chat button
        kSpacingBetweenTopButtons +
        kButtonVisualHeight + // Projects button
        kSpacingBetweenTopButtons;

    if (widget.showAssistantsButton) {
      topSpacingForSidebarContent +=
          kButtonVisualHeight + // Assistants button
          kSpacingBetweenTopButtons;
    }

    return Container(
      color: sidebarBg,
      child: Column(
        children: [
          // This SizedBox creates space for the overlayed buttons from RootWrapperDesktop
          SizedBox(height: topSpacingForSidebarContent),

          // Search Old Chats input field
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _sidebarHorizontalPadding,
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search old chats...',
                hintStyle: TextStyle(color: iconFg.withValues(alpha: 0.6)),
                prefixIcon: Icon(
                  Icons.search,
                  color: iconFg.withValues(alpha: 0.7),
                ),
                filled: true,
                fillColor: sidebarBg.lighten(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: iconFg.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: iconFg.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: accent, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 12,
                ),
                isDense: true,
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        splashRadius: 18,
                        icon: Icon(
                          Icons.clear,
                          color: iconFg.withValues(alpha: 0.7),
                        ),
                        onPressed: _clearSearchQuery,
                      ),
              ),
              style: TextStyle(color: iconFg),
              cursorColor: accent,
            ),
          ),

          // Offline indicator
          if (_isOfflineMode)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _sidebarHorizontalPadding,
                vertical: 8,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 14, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Offline - Showing cached chats',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: Icon(Icons.refresh, size: 14, color: Colors.orange),
                      tooltip: 'Check for updates',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 20,
                        height: 20,
                      ),
                      onPressed: () async {
                        // Quick network check and refresh if online
                        final isOnline =
                            await NetworkStatusService.quickCheck();
                        if (isOnline && mounted) {
                          await _loadChatsAndRefresh();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(
            height: 8,
          ), // Spacing after search bar or offline indicator
          // Starred Section - Fixed
          _buildSectionHeader('Starred', iconFg: iconFg),
          if (starredChats.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _sidebarHorizontalPadding,
                vertical: 8.0,
              ),
              child: Text(
                'No starred chats yet.',
                style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
              ),
            )
          else
            ...starredChats.map(
              (chat) => _buildStarredItem(chat, iconFg: iconFg, accent: accent),
            ),
          Divider(
            color: dividerColor,
            indent: _sidebarHorizontalPadding,
            endIndent: _sidebarHorizontalPadding,
          ),

          // Recents Section - Scrollable
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: false,
              cacheExtent: 200.0,
              itemCount: _filteredRecentChats.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildSectionHeader('Recents', iconFg: iconFg);
                }
                if (index == 1) {
                  if (_filteredRecentChats.isEmpty && _searchQuery.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _sidebarHorizontalPadding,
                        vertical: 8.0,
                      ),
                      child: Text(
                        'No recent chats yet.',
                        style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                      ),
                    );
                  } else if (_filteredRecentChats.isEmpty &&
                      _searchQuery.isNotEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _sidebarHorizontalPadding,
                        vertical: 8.0,
                      ),
                      child: Text(
                        'No chats found for "$_searchQuery".',
                        style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                      ),
                    );
                  }
                }
                final chatIndex = index - 1;
                if (chatIndex < 0 || chatIndex >= _filteredRecentChats.length) {
                  return const SizedBox(height: 10);
                }
                final storedChat = _filteredRecentChats[chatIndex];
                return _buildRecentItem(
                  storedChat,
                  onTap: () {
                    // CRITICAL: Block rapid chat switching while another chat is loading
                    if (ChatStorageService.isLoadingChat) {
                      if (kDebugMode) {
                        debugPrint('');
                      }
                      if (kDebugMode) {
                        debugPrint(
                          '═══════════════════════════════════════════════════════════',
                        );
                      }
                      if (kDebugMode) {
                        debugPrint(
                          '🚫 [SIDEBAR-DESKTOP] BLOCKED - Chat is still loading',
                        );
                      }
                      if (kDebugMode) {
                        debugPrint(
                          '═══════════════════════════════════════════════════════════',
                        );
                      }
                      return;
                    }
                    if (kDebugMode) {
                      debugPrint('');
                    }
                    if (kDebugMode) {
                      debugPrint(
                        '═══════════════════════════════════════════════════════════',
                      );
                    }
                    if (kDebugMode) {
                      debugPrint(
                        '👆 [SIDEBAR-DESKTOP] User tapped recent chat',
                      );
                    }
                    if (kDebugMode) {
                      debugPrint(
                        '👆 [SIDEBAR-DESKTOP] Chat ID: ${storedChat.id}',
                      );
                    }
                    if (kDebugMode) {
                      debugPrint(
                        '👆 [SIDEBAR-DESKTOP] Preview: "${storedChat.previewText.substring(0, storedChat.previewText.length > 40 ? 40 : storedChat.previewText.length)}..."',
                      );
                    }
                    if (kDebugMode) {
                      debugPrint(
                        '═══════════════════════════════════════════════════════════',
                      );
                    }
                    widget.onChatSelected(storedChat.id);
                  },
                  onDelete: () => _confirmAndDeleteChat(storedChat),
                  accentColor: accent,
                  iconFgColor: iconFg,
                );
              },
            ),
          ),

          // User profile section at the bottom
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 24.0),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: widget.onSettingsTapped,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: sidebarBg.lighten(0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: dividerColor, width: 1),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _displayNameFor(_profile),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: iconFg,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      BalanceBadge(
                        textStyle: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w600,
                        ),
                        placeholderStyle: TextStyle(
                          color: iconFg.withValues(alpha: 0.6),
                          fontWeight: FontWeight.w600,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(Icons.settings, color: iconFg),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper for consistent leading alignment in ListTiles
  Widget _leadingIconPlaceholder(IconData icon, {required Color iconFgColor}) {
    return SizedBox(
      width: _iconLeadingWidth + _iconTextSpacing,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Icon(icon, color: iconFgColor),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {required Color iconFg}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _sidebarHorizontalPadding,
        16.0,
        _sidebarHorizontalPadding,
        8.0,
      ),
      child: Text(
        title,
        style: TextStyle(
          color: iconFg,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildStarredItem(
    StoredChat chat, {
    required Color iconFg,
    required Color accent,
  }) {
    final String title = _deriveChatTitle(chat);
    return RepaintBoundary(
      child: GestureDetector(
        onSecondaryTapDown: (details) {
          _showChatContextMenu(
            context,
            details.globalPosition,
            chat,
            accentColor: accent,
            iconFgColor: iconFg,
            onDelete: () => _confirmAndDeleteChat(chat),
          );
        },
        child: ListTile(
          leading: _leadingIconPlaceholder(Icons.star, iconFgColor: accent),
          title: Text(
            title,
            style: TextStyle(color: iconFg),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _openChat(chat),
          dense: true,
          contentPadding: const EdgeInsets.only(
            left: _sidebarHorizontalPadding,
            right: 8.0,
          ),
          iconColor: accent,
          textColor: iconFg,
          trailing: IconButton(
            icon: Icon(Icons.star, color: accent),
            tooltip: 'Remove from starred',
            onPressed: () => _toggleStarred(chat),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentItem(
    StoredChat chat, {
    bool isLast = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconFgColor,
  }) {
    final bool isSelected = chat.id == widget.selectedChatId;
    final bool isStreaming = StreamingManager().isStreaming(chat.id);
    final String title = _deriveChatTitle(chat);
    return RepaintBoundary(
      child: GestureDetector(
        onSecondaryTapDown: (details) {
          _showChatContextMenu(
            context,
            details.globalPosition,
            chat,
            accentColor: accentColor,
            iconFgColor: iconFgColor,
            onDelete: onDelete,
          );
        },
        child: ListTile(
          title: Text(
            title,
            style: TextStyle(
              color: isLast
                  ? iconFgColor.withValues(alpha: 0.38)
                  : (isSelected ? accentColor : iconFgColor),
              fontSize: 15,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: onTap,
          dense: true,
          contentPadding: const EdgeInsets.only(
            left: _sidebarHorizontalPadding,
            right: 8.0,
          ),
          tileColor: isSelected ? accentColor.withValues(alpha: 0.1) : null,
          selectedTileColor: accentColor.withValues(alpha: 0.1),
          selectedColor: accentColor,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Streaming indicator - small pulsing dot
              if (isStreaming)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withValues(alpha: 0.5),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_horiz,
                  color: iconFgColor.withValues(alpha: 0.7),
                ),
                tooltip: 'Chat options',
                onSelected: (value) {
                  _handleMenuSelection(value, chat, onDelete);
                },
                itemBuilder: (context) => _buildMenuItems(
                  chat,
                  accentColor: accentColor,
                  iconFgColor: iconFgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Handle menu item selection
  void _handleMenuSelection(
    String value,
    StoredChat chat,
    VoidCallback? onDelete,
  ) {
    switch (value) {
      case 'star':
        _toggleStarred(chat);
        break;
      case 'edit':
        _renameChatDialog(chat);
        break;
      case 'delete':
        if (onDelete != null) onDelete();
        break;
    }
  }

  // Build menu items for both PopupMenuButton and context menu
  List<PopupMenuEntry<String>> _buildMenuItems(
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
  }) {
    final bool isStarred = chat.isStarred;
    return [
      PopupMenuItem(
        value: 'star',
        child: Row(
          children: [
            Icon(
              isStarred ? Icons.star : Icons.star_border,
              color: isStarred ? accentColor : iconFgColor,
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(isStarred ? 'Remove from starred' : 'Add to starred'),
          ],
        ),
      ),
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

  Future<void> _renameChatDialog(StoredChat chat) async {
    final controller = TextEditingController(text: _deriveChatTitle(chat));
    final messenger = ScaffoldMessenger.of(context);

    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Chat name',
              hintText: 'Enter new name',
            ),
            onSubmitted: (value) {
              Navigator.of(dialogContext).pop(value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (newName == null ||
        newName.isEmpty ||
        newName == _deriveChatTitle(chat)) {
      return;
    }

    try {
      await ChatStorageService.renameChat(chat.id, newName);
      if (!mounted) return;
      setState(() {
        _filterRecentChats();
      });
    } on StateError catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to rename chat: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    }
  }

  void _showDebouncedDeleteNotification(String chatTitle) {
    _lastDeletedChatTitle = chatTitle;
    _deleteNotificationTimer?.cancel();
    _deleteNotificationTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final title = _lastDeletedChatTitle;
      _lastDeletedChatTitle = null;

      final messenger = ScaffoldMessenger.of(context);
      final displayTitle = title != null && title.length > 30
          ? '${title.substring(0, 30)}...'
          : title;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '"$displayTitle" deleted',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    });
  }

  Future<void> _confirmAndDeleteChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    // Get chat title for display
    final chatTitle =
        chat.customName ??
        (chat.previewText.length > 40
            ? '${chat.previewText.substring(0, 40)}...'
            : chat.previewText);

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            '"$chatTitle"\n\nThis will be removed forever. Once deleted, it cannot be recovered.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) return;

    try {
      await ChatStorageService.deleteChat(chat.id);
      // No need to reload — deleteChat() updates local state and fires notifyChanges().
      // The changes stream listener in initState handles the UI rebuild.
      if (!mounted) return;
      if (widget.onChatDeleted != null) {
        await widget.onChatDeleted!(chat.id);
      }
      _showDebouncedDeleteNotification(chatTitle);
    } on StateError catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to delete chat: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    }
  }
}
