// lib/platform_specific/sidebar_mobile.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions

final List<String> _starredChats = ['Book writing Per chapter']; // Kept local for now

class SidebarMobile extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
  final int selectedChatIndex;
  final bool isCompactMode;

  const SidebarMobile({
    Key? key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    required this.selectedChatIndex,
    required this.isCompactMode,
  }) : super(key: key);

  @override
  State<SidebarMobile> createState() => _SidebarMobileState();
}

class _SidebarMobileState extends State<SidebarMobile> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;
  static const double _iconLeadingWidth = 24.0; // Standard icon width for alignment
  static const double _iconTextSpacing = 16.0; // Spacing between icon and text

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh();
  }

  Future<void> _loadChatsAndRefresh() async {
    await ChatStorageService.loadSavedChatsForSidebar();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant SidebarMobile oldWidget) {
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
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03); // Slightly darker for sidebar itself

    // On mobile, the "New Chat" and "Projects" buttons are now part of the sidebar content.
    const double initialVerticalSpacing = 16.0;

    return Container(
      color: sidebarBg, // Use dynamically derived sidebar background
      child: Column(
        children: [
          SizedBox(height: initialVerticalSpacing), // Initial space at the very top

          // New Chat Button (now inside sidebar for mobile)
          _buildSidebarButton(
            icon: Icons.edit_square,
            label: 'New chat',
            onTap: () {
              widget.onChatItemTapped(-1); // Signal new chat
              if (widget.isCompactMode) {
                Navigator.of(context).pop(); // Close sidebar after action
              }
            },
            iconFgColor: iconFg,
            accentColor: accent,
          ),
          const SizedBox(height: kSpacingBetweenTopButtons),

          // Projects Button (now inside sidebar for mobile)
          _buildSidebarButton(
            icon: Icons.folder_open,
            label: 'Projects',
            onTap: widget.onProjectsTapped, // Call parent handler, which will navigate and close sidebar
            iconFgColor: iconFg,
            accentColor: accent,
          ),
          const SizedBox(height: 16), // Spacing before Starred section

          // Starred Section - Fixed
          _buildSectionHeader('Starred', iconFg: iconFg),
          ..._starredChats.map((title) => _buildStarredItem(title, iconFg: iconFg)).toList(),
          Divider(color: Theme.of(context).dividerColor, indent: _sidebarHorizontalPadding, endIndent: _sidebarHorizontalPadding),

          // Recents Section - Scrollable
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero, // Remove default ListView padding
              children: [
                _buildSectionHeader('Recents', iconFg: iconFg),
                if (ChatStorageService.savedChats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: _sidebarHorizontalPadding, vertical: 8.0),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                    ),
                  ),
                ...ChatStorageService.savedChats.asMap().entries.map((entry) {
                  int index = entry.key;
                  String title = ChatStorageService.savedChats[index].split('§').isNotEmpty
                      ? ChatStorageService.savedChats[index].split('§').first.split('|').last.trimLeft()
                      : 'Chat ${index + 1}'; // Get text from first message, or default
                  if (title.length > 25) title = '${title.substring(0, 22)}...'; // Truncate long titles

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
                _buildRecentItem('Herzrequenz vs. Puls', isLast: true, accentColor: accent, iconFgColor: iconFg), // Example static item
                const SizedBox(height: 10), // Small space at the end of scrollable content
              ],
            ),
          ),

          // User profile section at the bottom - Now a PopupMenuButton with precise control
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: PopupMenuButton<String>(
                tooltip: 'User options',
                // This child is what gets rendered, and its tap triggers the menu.
                // It should have the same appearance as the ListTile, but allow for proper tap handling
                // by the PopupMenuButton itself.
                child: InkWell( // Use InkWell here to ensure the ripple effect still works
                  borderRadius: BorderRadius.circular(8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: iconFg.withValues(alpha: 0.3),
                      child: Text('DM',
                          style: TextStyle(color: iconFg, fontSize: 16)),
                    ),
                    title: Text('User Name', style: TextStyle(color: iconFg)),
                    trailing: Icon(Icons.keyboard_arrow_up, color: iconFg), // Arrow pointing up
                    contentPadding: const EdgeInsets.symmetric(horizontal: _sidebarHorizontalPadding),
                  ),
                ),
                // Custom styling for the popup menu
                color: sidebarBg.lighten(0.05), // Slightly lighter than sidebar background for the menu card itself
                elevation: 8.0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
                ),
                // IMPORTANT: Precise positioning and width control
                // The offset moves the menu relative to the bottom-left corner of the `child`.
                // For a menu of 2 items (approx 40px each + padding), total height ~96px.
                // We want its bottom to be aligned just above the child's top.
                // ListTile height is about 56px.
                // So, offset.dy = -(Menu Height + small gap)
                offset: const Offset(0, -96), // Adjusted offset: 2*40 + 2*8 + 8(gap) = 96
                constraints: const BoxConstraints(
                  minWidth: 180, // Minimum width of the menu
                  maxWidth: 220, // Maximum width, prevents it from taking full sidebar width
                  minHeight: kButtonVisualHeight * 2 + 16, // Ensure it's tall enough for content
                ),
                onSelected: (value) {
                  if (value == 'settings') {
                    widget.onSettingsTapped(); // Call parent settings handler
                  } else if (value == 'logout') {
                    print('Logout pressed');
                    // TODO: Implement actual logout logic here
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'settings',
                    height: kButtonVisualHeight, // Consistent button height
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.settings, color: iconFg, size: 20),
                        const SizedBox(width: 12),
                        Text('Settings', style: TextStyle(color: iconFg, fontSize: 15)),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'logout',
                    height: kButtonVisualHeight, // Consistent button height
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.logout, color: iconFg, size: 20),
                        const SizedBox(width: 12),
                        Text('Logout', style: TextStyle(color: iconFg, fontSize: 15)),
                      ],
                    ),
                  ),
                ],
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
      width: _iconLeadingWidth + _iconTextSpacing, // Space for icon + its margin to text
      child: Align(
        alignment: Alignment.centerLeft,
        child: Icon(icon, color: iconFgColor),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {required Color iconFg}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_sidebarHorizontalPadding, 16.0, _sidebarHorizontalPadding, 8.0),
      child: Text(
        title,
        style: TextStyle(
            color: iconFg, fontSize: 14, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildStarredItem(String title, {required Color iconFg}) {
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star_border, iconFgColor: iconFg), // Using a placeholder for alignment
      title: Text(title),
      onTap: () {},
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding), // Only left padding as leading handles space
      iconColor: iconFg,
      textColor: iconFg,
    );
  }

  Widget _buildRecentItem(String title, {int? index, bool isLast = false, VoidCallback? onTap, required Color accentColor, required Color iconFgColor}) {
    bool isSelected = index != null && index == widget.selectedChatIndex;
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.chat_bubble_outline, iconFgColor: iconFgColor), // Placeholder for alignment
      title: Text(
        title,
        style: TextStyle(
          color: isLast ? iconFgColor.withValues(alpha: 0.38) : (isSelected ? accentColor : iconFgColor),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding), // Only left padding as leading handles space
      tileColor: isSelected ? accentColor.withValues(alpha: 0.1) : null,
      selectedTileColor: accentColor.withValues(alpha: 0.1),
      selectedColor: accentColor,
    );
  }

  // Helper widget for the New Chat and Projects buttons now embedded in the sidebar
  Widget _buildSidebarButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color iconFgColor,
    required Color accentColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: kButtonVisualHeight,
        padding: const EdgeInsets.symmetric(horizontal: _sidebarHorizontalPadding, vertical: 4),
        child: Row(
          children: [
            Icon(icon, color: iconFgColor),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(color: iconFgColor, fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}