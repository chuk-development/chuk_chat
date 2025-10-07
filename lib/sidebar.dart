// sidebar.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions

final List<String> _starredChats = [
  'Book writing Per chapter',
]; // Kept local for now

class CustomSidebar extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function()
  onProjectsTapped; // Still passed, though Projects is now a top-level button
  final int selectedChatIndex;
  final bool isCompactMode;

  const CustomSidebar({
    Key? key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    required this.selectedChatIndex,
    required this.isCompactMode,
  }) : super(key: key);

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

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh();
    _loadProfile();
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
                    accentColor: accent,
                    iconFgColor: iconFg,
                  );
                }).toList(),
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

  Widget _buildStarredItem(String title, {required Color iconFg}) {
    return ListTile(
      leading: _leadingIconPlaceholder(
        Icons.star_border,
        iconFgColor: iconFg,
      ), // Using a placeholder for alignment
      title: Text(title),
      onTap: () {},
      dense: true,
      contentPadding: const EdgeInsets.only(
        left: _sidebarHorizontalPadding,
      ), // Only left padding as leading handles space
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
    );
  }
}
