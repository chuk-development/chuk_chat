// lib/platform_specific/sidebar_desktop.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions

final List<String> _starredChats = [
  'Book writing Per chapter',
]; // Kept local for now

class SidebarDesktop extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
  final int selectedChatIndex;
  final bool isCompactMode;

  const SidebarDesktop({
    Key? key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    required this.selectedChatIndex,
    required this.isCompactMode,
  }) : super(key: key);

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

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh(); // Initial load and filter
    _searchController.addListener(_onSearchChanged);
    _loadProfile();
  }

  @override
  void dispose() {
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
      _filteredRecentChats = ChatStorageService.savedChats.where((chat) {
        final title = _deriveChatTitle(chat).toLowerCase();
        return title.contains(_searchQuery.toLowerCase());
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
    final segments = chat.content.split('§');
    if (segments.isEmpty || segments.first.isEmpty) {
      return 'Chat';
    }
    final parts = segments.first.split('|');
    if (parts.length < 2) {
      return 'Chat';
    }
    final text = parts[1].trim();
    return text.isEmpty ? 'Chat' : text;
  }

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03);

    // The height of the top bar is calculated dynamically for desktop.
    // "New Chat" and "Projects" buttons are positioned *outside* this sidebar widget
    // in `root_wrapper_desktop.dart`. This spacing accounts for them so sidebar
    // content doesn't overlap those fixed overlay buttons.
    final double topSpacingForSidebarContent =
        kTopInitialSpacing +
        kMenuButtonHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight + // New Chat button
        kSpacingBetweenTopButtons +
        kButtonVisualHeight + // Projects button
        kSpacingBetweenTopButtons;

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
              ),
              style: TextStyle(color: iconFg),
              cursorColor: accent,
            ),
          ),
          const SizedBox(height: 16), // Spacing after search bar
          // Starred Section - Fixed
          _buildSectionHeader('Starred', iconFg: iconFg),
          ..._starredChats
              .map((title) => _buildStarredItem(title, iconFg: iconFg))
              .toList(),
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
                      'No chats found for "${_searchQuery}".',
                      style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                    ),
                  ),
                ..._filteredRecentChats.asMap().entries.map((entry) {
                  final storedChat = entry.value;
                  final originalIndex = ChatStorageService.savedChats.indexOf(
                    storedChat,
                  );
                  String title = _deriveChatTitle(storedChat);
                  if (title.length > 25) {
                    title = '${title.substring(0, 22)}...';
                  }

                  return _buildRecentItem(
                    title,
                    index: originalIndex,
                    onTap: () {
                      widget.onChatItemTapped(originalIndex);
                    },
                    accentColor: accent,
                    iconFgColor: iconFg,
                  );
                }).toList(),
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

  Widget _buildStarredItem(String title, {required Color iconFg}) {
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star_border, iconFgColor: iconFg),
      title: Text(title),
      onTap: () {},
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding),
      iconColor: iconFg,
      textColor: iconFg,
    );
  }

  Widget _buildRecentItem(
    String title, {
    int? index,
    bool isLast = false,
    VoidCallback? onTap,
    required Color accentColor,
    required Color iconFgColor,
  }) {
    bool isSelected = index != null && index == widget.selectedChatIndex;
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
    );
  }
}
