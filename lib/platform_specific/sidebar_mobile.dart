// lib/platform_specific/sidebar_mobile.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart'; // Assuming this exists
import 'package:chuk_chat/services/chat_storage_service.dart'; // Assuming this exists
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Assuming this exists

// Local list for starred chats, as per original snippet
final List<String> _starredChats = ['Book writing Per chapter'];

class SidebarMobile extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
  final Future<void> Function(String chatId)? onChatDeleted;
  final int selectedChatIndex;
  final bool isCompactMode; // Not directly used in the UI, but kept for context

  const SidebarMobile({
    Key? key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    this.onChatDeleted,
    required this.selectedChatIndex,
    required this.isCompactMode,
  }) : super(key: key);

  @override
  State<SidebarMobile> createState() => _SidebarMobileState();
}

class _SidebarMobileState extends State<SidebarMobile> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;
  // Standard icon width for alignment (originally in main.dart's Drawer)
  static const double _iconLeadingWidth = 24.0;
  // Spacing between icon and text (originally in main.dart's Drawer)
  static const double _iconTextSpacing = 16.0;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<StoredChat> _filteredRecentChats = [];
  ProfileRecord? _profile;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh();
    _startAutoRefresh();
    _searchController.addListener(_onSearchChanged);
    _loadProfile();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
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

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshChatsPeriodically(),
    );
  }

  Future<void> _refreshChatsPeriodically() async {
    try {
      await ChatStorageService.loadSavedChatsForSidebar();
      if (!mounted) return;
      setState(() {
        _filterRecentChats();
      });
    } catch (_) {
      // Ignore background sync errors; UI actions will surface them if needed.
    }
  }

  Future<void> _loadChatsAndRefresh() async {
    // This method interacts with ChatStorageService, assuming it's correctly set up.
    await ChatStorageService.loadSavedChatsForSidebar();
    if (mounted) {
      setState(() {
        _filterRecentChats(); // Filter after loading/refreshing chats
      });
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
      // Ignore profile load errors; fallback text is shown instead.
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

  Future<void> _confirmAndDeleteChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: const Text(
            'Deleting this chat removes it forever. This action cannot be undone.',
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

  void _filterRecentChats() {
    if (_searchQuery.isEmpty) {
      _filteredRecentChats = List<StoredChat>.from(
        ChatStorageService.savedChats,
      );
    } else {
      _filteredRecentChats = ChatStorageService.savedChats.where((chat) {
        final title = _deriveChatTitle(chat).toLowerCase();
        return title.contains(_searchQuery.toLowerCase());
      }).toList();
    }
  }

  @override
  void didUpdateWidget(covariant SidebarMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      if (mounted) setState(() {});
    }
    // Also refresh filtered chats if the underlying ChatStorageService.savedChats list changes
    if (ChatStorageService.savedChats.length != _filteredRecentChats.length &&
        _searchQuery.isEmpty) {
      _filterRecentChats();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color iconColorDefault = theme.iconTheme.color!.withValues(
      alpha: 0.7,
    );
    final Color textColorDefault =
        theme.textTheme.bodyMedium?.color ?? theme.colorScheme.onSurface;
    final Color accentColor = theme.colorScheme.primary;
    final Color sidebarBg = theme.cardColor.darken(0.02);
    final Color dividerColor = theme.dividerColor.withValues(alpha: 0.5);

    const double initialVerticalPadding =
        48.0; // From main.dart Drawer top padding

    return Container(
      color: sidebarBg,
      child: Column(
        children: [
          SizedBox(height: initialVerticalPadding),

          // Search Old Chats input field (styled from main.dart's InputDecorationTheme)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _sidebarHorizontalPadding,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Suchen',
                      prefixIcon: Icon(Icons.search, color: iconColorDefault),
                      filled: true,
                      fillColor: sidebarBg.lighten(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: dividerColor, width: 1),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: dividerColor, width: 1),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: accentColor, width: 1.3),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 0,
                      ),
                    ),
                    style: TextStyle(color: textColorDefault),
                    cursorColor: textColorDefault,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16), // Spacing after search bar
          // Projects entry as per main.dart's Drawer items
          _buildDrawerItem(
            Icons.folder_open_outlined,
            'Neues Projekt',
            widget.onProjectsTapped,
            iconColorDefault,
            textColorDefault,
            tileBg: sidebarBg.lighten(0.04),
            dividerColor: dividerColor,
            accentColor: accentColor,
          ),

          const SizedBox(height: 24.0), // Spacing between groups
          // Starred Section - Fixed
          _buildSectionHeader('Starred', textColor: textColorDefault),
          ..._starredChats
              .map(
                (title) => _buildStarredItem(
                  title,
                  iconColorDefault,
                  textColorDefault,
                ),
              )
              .toList(),
          Divider(
            color: dividerColor,
            indent: _sidebarHorizontalPadding,
            endIndent: _sidebarHorizontalPadding,
          ),

          // Recents Section - Scrollable
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildSectionHeader('Recents', textColor: textColorDefault),
                if (_filteredRecentChats.isEmpty && _searchQuery.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _sidebarHorizontalPadding,
                      vertical: 8.0,
                    ),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(
                        color: iconColorDefault.withValues(alpha: 0.4),
                      ),
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
                      'No chats found for "${_searchQuery}".',
                      style: TextStyle(
                        color: iconColorDefault.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ..._filteredRecentChats.asMap().entries.map((entry) {
                  final storedChat = entry.value;
                  final index = ChatStorageService.savedChats.indexOf(
                    storedChat,
                  );
                  if (index == -1) {
                    return const SizedBox.shrink();
                  }
                  String title = _deriveChatTitle(storedChat);
                  if (title.length > 25) {
                    title = '${title.substring(0, 22)}...';
                  }

                  return _buildRecentItem(
                    title,
                    index: index,
                    onTap: () {
                      widget.onChatItemTapped(index);
                    },
                    onDelete: () => _confirmAndDeleteChat(storedChat),
                    accentColor: accentColor,
                    iconColor: iconColorDefault,
                    textColor: textColorDefault,
                  );
                }).toList(),
                const SizedBox(height: 10),
              ],
            ),
          ),

          // User profile section at the bottom (styled from main.dart)
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
                      CircleAvatar(
                        backgroundColor: accentColor.withValues(alpha: 0.2),
                        child: Text(
                          _initialsFor(_profile),
                          style: TextStyle(
                            color: accentColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12.0),
                      Expanded(
                        child: Text(
                          _displayNameFor(_profile),
                          style: TextStyle(
                            color: textColorDefault,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(Icons.settings, color: iconColorDefault),
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
  Widget _leadingIconPlaceholder(IconData icon, {required Color iconColor}) {
    return SizedBox(
      width: _iconLeadingWidth + _iconTextSpacing,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Icon(icon, color: iconColor),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {required Color textColor}) {
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
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // Modified to use the common Drawer Item style from main.dart
  Widget _buildDrawerItem(
    IconData icon,
    String title,
    VoidCallback onTap,
    Color iconColor,
    Color textColor, {
    Color? tileBg,
    Color? dividerColor,
    Color? accentColor,
  }) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title, style: TextStyle(color: textColor)),
      onTap: onTap,
      tileColor: tileBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: dividerColor ?? Colors.transparent, width: 1),
      ),
      hoverColor: accentColor?.withValues(alpha: 0.08),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: _sidebarHorizontalPadding,
        vertical: 4,
      ),
      // dense and iconColor/textColor set by ListTileThemeData in main.dart
    );
  }

  Widget _buildStarredItem(String title, Color iconColor, Color textColor) {
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star_border, iconColor: iconColor),
      title: Text(title, style: TextStyle(color: textColor)),
      onTap: () {},
      dense: true,
      tileColor: Colors.transparent,
      contentPadding: const EdgeInsets.only(
        left: _sidebarHorizontalPadding,
        right: 16.0,
      ),
      iconColor: iconColor,
      textColor: textColor,
    );
  }

  Widget _buildRecentItem(
    String title, {
    int? index,
    bool isLast = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconColor,
    required Color textColor,
  }) {
    bool isSelected = index != null && index == widget.selectedChatIndex;
    return ListTile(
      leading: _leadingIconPlaceholder(
        Icons.chat_bubble_outline,
        iconColor: iconColor,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isLast
              ? textColor.withValues(alpha: 0.38)
              : (isSelected ? accentColor : textColor),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.only(
        left: _sidebarHorizontalPadding,
        right: 16.0,
      ),
      tileColor: isSelected ? accentColor.withValues(alpha: 0.1) : null,
      selectedTileColor: accentColor.withValues(alpha: 0.1),
      selectedColor: accentColor,
      iconColor: iconColor,
      textColor: textColor,
      trailing: onDelete == null
          ? null
          : IconButton(
              icon: Icon(
                Icons.delete_outline,
                color: iconColor.withValues(alpha: 0.7),
              ),
              tooltip: 'Delete chat',
              onPressed: onDelete,
            ),
    );
  }

  // The original _buildSidebarButton is replaced by _buildDrawerItem for consistency
  // as per the new styling. However, for "Projects" if it needs a distinct style,
  // we could re-introduce a version of it or define it directly.
  // For now, it uses _buildDrawerItem.
}
