// sidebar.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions

class CustomSidebar extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function()
  onProjectsTapped; // Still passed, though Projects is now a top-level button
  final Future<void> Function(String chatId)? onChatDeleted;
  final int selectedChatIndex;
  final bool isCompactMode;

  const CustomSidebar({
    super.key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    this.onChatDeleted,
    required this.selectedChatIndex,
    required this.isCompactMode,
  });

  @override
  State<CustomSidebar> createState() => _CustomSidebarState();
}

class _CustomSidebarState extends State<CustomSidebar> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;
  static const double _iconLeadingWidth =
      24.0; // Standard icon width for alignment
  static const double _iconTextSpacing = 16.0; // Spacing between icon and text
  ProfileRecord? _profile;
  StreamSubscription<void>? _chatUpdatesSub;

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh();
    _loadProfile();
    _chatUpdatesSub = ChatStorageService.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _chatUpdatesSub?.cancel();
    super.dispose();
  }

  Future<void> _loadChatsAndRefresh() async {
    await ChatStorageService.loadSavedChatsForSidebar();
    if (mounted) {
      setState(() {});
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
      // Ignore profile load errors; sidebar shows fallback label instead.
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
      setState(() {});
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
  void didUpdateWidget(covariant CustomSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access theme colors dynamically
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(
      context,
    ).cardColor.darken(0.03); // Slightly darker for sidebar itself
    final List<StoredChat> starredChats = ChatStorageService.savedChats
        .where((chat) => chat.isStarred)
        .toList();

    // The height of the top bar is calculated dynamically.
    // In compact mode, "New Chat" and "Projects" buttons are handled outside the sidebar
    // and only visible when the sidebar is open.
    // However, when open, they still need to occupy this space *within* the sidebar
    // so that "Starred" and "Recents" start correctly below them.
    // So, the "160.0" value is retained.
    final double topSpacingForSidebarContent =
        kTopInitialSpacing +
        kMenuButtonHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight +
        kSpacingBetweenTopButtons; // This is the 160.0 value from main.dart

    return Container(
      color: sidebarBg, // Use dynamically derived sidebar background
      child: Column(
        children: [
          SizedBox(
            height: topSpacingForSidebarContent,
          ), // Uses the calculated constant
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
              padding: EdgeInsets.zero, // Remove default ListView padding
              children: [
                _buildSectionHeader('Recents', iconFg: iconFg),
                if (ChatStorageService.savedChats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _sidebarHorizontalPadding,
                      vertical: 8.0,
                    ),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                    ),
                  ),
                ...ChatStorageService.savedChats.asMap().entries.map((entry) {
                  final index = entry.key;
                  final storedChat = entry.value;
                  if (index < 0 ||
                      index >= ChatStorageService.savedChats.length) {
                    return const SizedBox.shrink();
                  }
                  return _buildRecentItem(
                    storedChat,
                    index: index,
                    onTap: () {
                      widget.onChatItemTapped(index);
                    },
                    onDelete: () => _confirmAndDeleteChat(storedChat),
                    accentColor: accent,
                    iconFgColor: iconFg,
                  );
                }),
                const SizedBox(
                  height: 10,
                ), // Small space at the end of scrollable content
              ],
            ),
          ),

          // User profile section at the bottom - direct navigation to settings
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onSettingsTapped,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: iconFg.withValues(alpha: 0.3),
                    child: Text(
                      _initialsFor(_profile),
                      style: TextStyle(color: iconFg, fontSize: 16),
                    ),
                  ),
                  title: Text(
                    _displayNameFor(_profile),
                    style: TextStyle(color: iconFg),
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
      width:
          _iconLeadingWidth +
          _iconTextSpacing, // Space for icon + its margin to text
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
      ), // Placeholder for alignment
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
      contentPadding: const EdgeInsets.only(
        left: _sidebarHorizontalPadding,
      ), // Only left padding as leading handles space
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
            'Deleting this chat removes it forever. This cannot be undone.',
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
      setState(() {});
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
