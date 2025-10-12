// lib/platform_specific/sidebar_desktop.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions
import 'package:chuk_chat/widgets/credit_display.dart';

class SidebarDesktop extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
  final Future<void> Function(String chatId)? onChatDeleted;
  final int selectedChatIndex;
  final bool isCompactMode;
  final bool showAssistantsButton;

  const SidebarDesktop({
    super.key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    this.onChatDeleted,
    required this.selectedChatIndex,
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
  StreamSubscription<void>? _chatUpdatesSub;

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh(); // Initial load and filter
    _searchController.addListener(_onSearchChanged);
    _loadProfile();
    _chatUpdatesSub = ChatStorageService.changes.listen((_) {
      if (!mounted) return;
      setState(() {
        _filterRecentChats();
      });
    });
  }

  @override
  void dispose() {
    _chatUpdatesSub?.cancel();
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

  void _clearSearchQuery() {
    _searchController.clear();
  }

  // Refreshes chats from storage and re-filters
  Future<void> _loadChatsAndRefresh() async {
    await ChatStorageService.loadSavedChatsForSidebar();
    if (mounted) {
      setState(() {
        _filterRecentChats(); // Filter after loading/refreshing chats
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
        return chat.messages.any(
          (message) => message.text.toLowerCase().contains(lowerQuery),
        );
      }).toList();
    }
  }

  @override
  void didUpdateWidget(covariant SidebarDesktop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
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

  String _initialsFor(ProfileRecord? profile) {
    final source = profile?.displayName.isNotEmpty == true
        ? profile!.displayName
        : profile?.email ?? '';
    if (source.trim().isEmpty) return '?';

    final parts = source.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    final first = parts.first.substring(0, 1).toUpperCase();
    final last = parts.last.substring(0, 1).toUpperCase();
    return '$first$last';
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
    return chat.previewText;
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
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to update star: $error')),
      );
    }
  }

  void _openChat(StoredChat chat) {
    final index = ChatStorageService.savedChats.indexWhere(
      (stored) => stored.id == chat.id,
    );
    if (index != -1) {
      widget.onChatItemTapped(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03);
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
          const SizedBox(height: 16), // Spacing after search bar
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
            color: Theme.of(context).dividerColor,
            indent: _sidebarHorizontalPadding,
            endIndent: _sidebarHorizontalPadding,
          ),

          // Recents Section - Scrollable
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildSectionHeader('Recents', iconFg: iconFg),
                if (_filteredRecentChats.isEmpty && _searchQuery.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _sidebarHorizontalPadding,
                      vertical: 8.0,
                    ),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                    ),
                  )
                else if (_filteredRecentChats.isEmpty &&
                    _searchQuery.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _sidebarHorizontalPadding,
                      vertical: 8.0,
                    ),
                    child: Text(
                      'No chats found for "$_searchQuery".',
                      style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                    ),
                  ),
                ..._filteredRecentChats.asMap().entries.map((entry) {
                  final storedChat = entry.value;
                  final originalIndex = ChatStorageService.savedChats.indexOf(
                    storedChat,
                  );
                  if (originalIndex == -1) {
                    return const SizedBox.shrink();
                  }
                  return _buildRecentItem(
                    storedChat,
                    index: originalIndex,
                    onTap: () {
                      widget.onChatItemTapped(originalIndex);
                    },
                    onDelete: () => _confirmAndDeleteChat(storedChat),
                    accentColor: accent,
                    iconFgColor: iconFg,
                  );
                }),
                const SizedBox(height: 10),
              ],
            ),
          ),

          // User profile section at the bottom
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onSettingsTapped,
                child: ListTile(
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _displayNameFor(_profile),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: iconFg),
                        ),
                      ),
                      const SizedBox(width: 12),
                      CreditBadge(
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
                    ],
                  ),
                  trailing: Icon(Icons.settings, color: iconFg),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: _sidebarHorizontalPadding,
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
    String title = _deriveChatTitle(chat);
    if (title.length > 25) {
      title = '${title.substring(0, 22)}...';
    }
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star, iconFgColor: accent),
      title: Text(title, style: TextStyle(color: iconFg)),
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
    );
  }

  Widget _buildRecentItem(
    StoredChat chat, {
    required int index,
    bool isLast = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconFgColor,
  }) {
    bool isSelected = index == widget.selectedChatIndex;
    bool isStarred = chat.isStarred;
    String title = _deriveChatTitle(chat);
    if (title.length > 25) {
      title = '${title.substring(0, 22)}...';
    }
    return ListTile(
      leading: _leadingIconPlaceholder(
        Icons.chat_bubble_outline,
        iconFgColor: iconFgColor,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isLast
              ? iconFgColor.withValues(alpha: 0.38)
              : (isSelected ? accentColor : iconFgColor),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding),
      tileColor: isSelected ? accentColor.withValues(alpha: 0.1) : null,
      selectedTileColor: accentColor.withValues(alpha: 0.1),
      selectedColor: accentColor,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              isStarred ? Icons.star : Icons.star_border,
              color: isStarred
                  ? accentColor
                  : iconFgColor.withValues(alpha: 0.7),
            ),
            tooltip: isStarred ? 'Remove from starred' : 'Add to starred',
            onPressed: () => _toggleStarred(chat),
          ),
          if (onDelete != null)
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                color: iconFgColor.withValues(alpha: 0.7),
              ),
              tooltip: 'Delete chat',
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }

  Future<void> _confirmAndDeleteChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: const Text(
            'This will remove the chat forever. Once deleted, it cannot be recovered.',
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
      await ChatStorageService.loadSavedChatsForSidebar();
      if (!mounted) return;
      setState(() {
        _filterRecentChats();
      });
      if (widget.onChatDeleted != null) {
        await widget.onChatDeleted!(chat.id);
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('Chat deleted permanently.')),
      );
    } on StateError catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to delete chat: $error')),
      );
    }
  }
}
