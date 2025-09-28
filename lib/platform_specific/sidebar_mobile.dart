// lib/platform_specific/sidebar_mobile.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart'; // Assuming this exists
import 'package:chuk_chat/services/chat_storage_service.dart'; // Assuming this exists
import 'package:chuk_chat/utils/color_extensions.dart'; // Assuming this exists

// Local list for starred chats, as per original snippet
final List<String> _starredChats = ['Book writing Per chapter'];

class SidebarMobile extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
  final int selectedChatIndex;
  final bool isCompactMode; // Not directly used in the UI, but kept for context

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
  // Standard icon width for alignment (originally in main.dart's Drawer)
  static const double _iconLeadingWidth = 24.0;
  // Spacing between icon and text (originally in main.dart's Drawer)
  static const double _iconTextSpacing = 16.0;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<String> _filteredRecentChats = [];

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh();
    _searchController.addListener(_onSearchChanged);
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

  Future<void> _loadChatsAndRefresh() async {
    // This method interacts with ChatStorageService, assuming it's correctly set up.
    await ChatStorageService.loadSavedChatsForSidebar();
    if (mounted) {
      setState(() {
        _filterRecentChats(); // Filter after loading/refreshing chats
      });
    }
  }

  void _filterRecentChats() {
    if (_searchQuery.isEmpty) {
      _filteredRecentChats = ChatStorageService.savedChats;
    } else {
      _filteredRecentChats = ChatStorageService.savedChats.where((chatJson) {
        String title = chatJson.split('§').isNotEmpty
            ? chatJson.split('§').first.split('|').last.trimLeft()
            : ''; // Get text from first message, or empty
        return title.toLowerCase().contains(_searchQuery.toLowerCase());
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
    // Using Colors directly from the main.dart theme for consistency
    final Color iconColorDefault = Colors.white70; // From ListTileThemeData
    final Color textColorDefault = Colors.white; // From TextTheme bodyLarge/titleMedium
    final Color accentColor = Theme.of(context).colorScheme.primary; // Assuming a primary accent

    // Drawer background color from main.dart
    const Color sidebarBg = Colors.black;

    const double initialVerticalPadding = 48.0; // From main.dart Drawer top padding

    return Container(
      color: sidebarBg, // Set drawer background to black
      child: Column(
        children: [
          SizedBox(
              height:
                  initialVerticalPadding), // Initial space for status bar area

          // Search Old Chats input field (styled from main.dart's InputDecorationTheme)
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: _sidebarHorizontalPadding),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Suchen', // Matching the hint text from main.dart
                      prefixIcon: Icon(
                        Icons.search,
                        color: Colors.grey.shade500,
                      ),
                      // The rest of the styling comes from ThemeData.inputDecorationTheme
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
              Icons.folder_open_outlined, 'Neues Projekt', widget.onProjectsTapped,
              iconColorDefault, textColorDefault),

          const SizedBox(height: 24.0), // Spacing between groups

          // Starred Section - Fixed
          _buildSectionHeader('Starred', textColor: textColorDefault),
          ..._starredChats.map(
              (title) => _buildStarredItem(title, iconColorDefault, textColorDefault)).toList(),
          Divider(
              color: Theme.of(context).dividerColor,
              indent: _sidebarHorizontalPadding,
              endIndent: _sidebarHorizontalPadding),

          // Recents Section - Scrollable
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildSectionHeader('Recents', textColor: textColorDefault),
                if (_filteredRecentChats.isEmpty && _searchQuery.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: _sidebarHorizontalPadding, vertical: 8.0),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(color: iconColorDefault.withOpacity(0.5)),
                    ),
                  )
                else if (_filteredRecentChats.isEmpty && _searchQuery.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: _sidebarHorizontalPadding, vertical: 8.0),
                    child: Text(
                      'No chats found for "${_searchQuery}".',
                      style: TextStyle(color: iconColorDefault.withOpacity(0.5)),
                    ),
                  ),
                ..._filteredRecentChats.asMap().entries.map((entry) {
                  int index = ChatStorageService.savedChats
                      .indexOf(entry.value); // Get original index
                  String title = entry.value.split('§').isNotEmpty
                      ? entry.value.split('§').first.split('|').last.trimLeft()
                      : 'Chat ${index != -1 ? index + 1 : 'New'}';
                  if (title.length > 25) title = '${title.substring(0, 22)}...';

                  return _buildRecentItem(
                    title,
                    index: index,
                    onTap: () {
                      widget.onChatItemTapped(index);
                      Navigator.of(context)
                          .pop(); // Close sidebar after selecting chat on mobile
                    },
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
              child: PopupMenuButton<String>(
                tooltip: 'User options',
                // Mimicking the structure from main.dart's Drawer user info
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.amber.shade700,
                      child: Text('CH',
                          style: TextStyle(
                              color: textColorDefault,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 12.0),
                    Expanded(
                      child: Text(
                        'Chuk', // User Name from main.dart
                        style: TextStyle(
                          color: textColorDefault,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down,
                        color: Colors.grey.shade500),
                  ],
                ),
                color: sidebarBg.lighten(
                    0.05), // Using a slightly lighter black for the popup
                elevation: 8.0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: iconColorDefault.withOpacity(0.3), width: 1),
                ),
                offset: const Offset(0, -96), // Position above the button
                constraints: const BoxConstraints(
                  minWidth: 180,
                  maxWidth: 220,
                  minHeight: kButtonVisualHeight * 2 + 16,
                ),
                onSelected: (value) {
                  if (value == 'settings') {
                    widget.onSettingsTapped();
                  } else if (value == 'logout') {
                    print('Logout pressed');
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'settings',
                    height: kButtonVisualHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.settings, color: iconColorDefault, size: 20),
                        const SizedBox(width: 12),
                        Text('Settings',
                            style: TextStyle(
                                color: textColorDefault, fontSize: 15)),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'logout',
                    height: kButtonVisualHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.logout, color: iconColorDefault, size: 20),
                        const SizedBox(width: 12),
                        Text('Logout',
                            style: TextStyle(
                                color: textColorDefault, fontSize: 15)),
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
          _sidebarHorizontalPadding, 16.0, _sidebarHorizontalPadding, 8.0),
      child: Text(
        title,
        style: TextStyle(
            color: textColor, fontSize: 14, fontWeight: FontWeight.bold),
      ),
    );
  }

  // Modified to use the common Drawer Item style from main.dart
  Widget _buildDrawerItem(IconData icon, String title, VoidCallback onTap,
      Color iconColor, Color textColor) {
    return ListTile(
      leading: Icon(icon, color: iconColor), // Use the provided iconColor
      title: Text(title, style: TextStyle(color: textColor)), // Use provided textColor
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: _sidebarHorizontalPadding, vertical: 0),
      // dense and iconColor/textColor set by ListTileThemeData in main.dart
    );
  }

  Widget _buildStarredItem(String title, Color iconColor, Color textColor) {
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star_border, iconColor: iconColor),
      title: Text(title, style: TextStyle(color: textColor)),
      onTap: () {},
      dense: true,
      contentPadding:
          const EdgeInsets.only(left: _sidebarHorizontalPadding, right: 16.0),
      iconColor: iconColor,
      textColor: textColor,
    );
  }

  Widget _buildRecentItem(String title,
      {int? index,
      bool isLast = false,
      VoidCallback? onTap,
      required Color accentColor,
      required Color iconColor,
      required Color textColor}) {
    bool isSelected = index != null && index == widget.selectedChatIndex;
    return ListTile(
      leading:
          _leadingIconPlaceholder(Icons.chat_bubble_outline, iconColor: iconColor),
      title: Text(
        title,
        style: TextStyle(
          color: isLast
              ? textColor.withOpacity(0.38)
              : (isSelected ? accentColor : textColor),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding:
          const EdgeInsets.only(left: _sidebarHorizontalPadding, right: 16.0),
      tileColor: isSelected ? accentColor.withOpacity(0.1) : null,
      selectedTileColor: accentColor.withOpacity(0.1),
      selectedColor: accentColor,
      iconColor: iconColor,
      textColor: textColor,
    );
  }

  // The original _buildSidebarButton is replaced by _buildDrawerItem for consistency
  // as per the new styling. However, for "Projects" if it needs a distinct style,
  // we could re-introduce a version of it or define it directly.
  // For now, it uses _buildDrawerItem.
}
