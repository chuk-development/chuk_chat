// sidebar.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/constants.dart'; // Import der neuen Konstanten
import 'package:ui_elements_flutter/services/chat_storage_service.dart';

final List<String> _starredChats = ['Book writing Per chapter']; // Kept local for now

class CustomSidebar extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped; // Still passed, though Projects is now a top-level button
  final int selectedChatIndex;
  final bool isCompactMode; // NEU: Flag für den Kompaktmodus

  const CustomSidebar({
    Key? key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    required this.selectedChatIndex,
    required this.isCompactMode, // NEU
  }) : super(key: key);

  @override
  State<CustomSidebar> createState() => _CustomSidebarState();
}

class _CustomSidebarState extends State<CustomSidebar> {
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
  void didUpdateWidget(covariant CustomSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // Die Höhe der oberen Leiste wird dynamisch basierend auf isCompactMode berechnet.
    // Im Kompaktmodus werden die "New Chat"- und "Projects"-Buttons außerhalb der Sidebar gehandhabt
    // und nur sichtbar, wenn die Sidebar geöffnet ist. Daher benötigen wir nur den Platz
    // für das Hamburger-Menü und den Titel, sowie die beiden Buttons, die nun IN der Sidebar
    // sichtbar sind, aber eben den Platz in der Sidebar selbst einnehmen müssen.
    // Der Gesamtabstand, den die Sidebar am oberen Rand berücksichtigen muss:
    // kTopInitialSpacing (16) + kMenuButtonHeight (48) + kSpacingBetweenTopButtons (8) = 72.0
    // + kButtonVisualHeight (40, New Chat) + kSpacingBetweenTopButtons (8)
    // + kButtonVisualHeight (40, Projects) + kSpacingBetweenTopButtons (8)
    // = 72 + 40 + 8 + 40 + 8 = 168.0
    // ABER: Da New Chat und Projects nun Conditional sind, wenn sidebar offen, brauchen sie Platz.
    // Wenn NICHT kompakt, ist der Platz fix 160.0, da sie immer da sind.
    // Wenn kompakt und Sidebar offen, sind sie auch da, und nehmen den Platz von 160.0 ein.
    // Also bleibt der obere Platz 160.0, damit Starred und Recents unter diesen Buttons beginnen.
    final double topSpacingForSidebarContent = kTopInitialSpacing +
        kMenuButtonHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight +
        kSpacingBetweenTopButtons; // Das ist der 160.0 Wert aus main.dart

    return Container(
      color: const Color(0xFF1D1813), // Slightly darker background for the sidebar
      child: Column(
        children: [
          // Gebe initialen vertikalen Platz für die obere Symbolleistelemente außerhalb der Sidebar
          // Der New Chat und Projects Button sind auf Mobilgeräten *nur* sichtbar, wenn die Sidebar offen ist.
          // In diesem Fall müssen sie aber trotzdem diesen Platz _in_ der Sidebar einnehmen,
          // damit Starred und Recents korrekt darunter beginnen.
          // Daher wird der "160.0" Wert beibehalten.
          SizedBox(height: topSpacingForSidebarContent), // Verwendet die berechnete Konstante

          // Starred Section - Fixed
          _buildSectionHeader('Starred'),
          ..._starredChats.map((title) => _buildStarredItem(title)).toList(),
          const Divider(color: Colors.white12, indent: _sidebarHorizontalPadding, endIndent: _sidebarHorizontalPadding),

          // Recents Section - Scrollable
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero, // Remove default ListView padding
              children: [
                _buildSectionHeader('Recents'),
                if (ChatStorageService.savedChats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: _sidebarHorizontalPadding, vertical: 8.0),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(color: iconFg.withOpacity(0.5)),
                    ),
                  ),
                ...ChatStorageService.savedChats.asMap().entries.map((entry) {
                  int index = entry.key;
                  String title = 'Chat ${index + 1}'; // Placeholder
                  return _buildRecentItem(
                    title,
                    index: index,
                    onTap: () {
                      widget.onChatItemTapped(index);
                    },
                  );
                }).toList(),
                _buildRecentItem('Herzrequenz vs. Puls', isLast: true), // Example static item
                const SizedBox(height: 10), // Small space at the end of scrollable content
              ],
            ),
          ),

          // User profile section at the bottom - Fixed
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: iconFg.withOpacity(0.3),
                  child: Text('DM',
                      style: TextStyle(color: iconFg, fontSize: 16)),
                ),
                title: Text('User Name', style: TextStyle(color: iconFg)),
                trailing: Icon(Icons.keyboard_arrow_down, color: iconFg),
                contentPadding: const EdgeInsets.symmetric(horizontal: _sidebarHorizontalPadding),
                onTap: () {
                  _showUserOptions(context); // Show user options menu
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper for consistent leading alignment in ListTiles
  Widget _leadingIconPlaceholder(IconData icon) {
    return SizedBox(
      width: _iconLeadingWidth + _iconTextSpacing, // Space for icon + its margin to text
      child: Align(
        alignment: Alignment.centerLeft,
        child: Icon(icon, color: iconFg),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_sidebarHorizontalPadding, 16.0, _sidebarHorizontalPadding, 8.0),
      child: Text(
        title,
        style: TextStyle(
            color: iconFg, fontSize: 14, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildStarredItem(String title) {
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star_border), // Using a placeholder for alignment
      title: Text(title),
      onTap: () {},
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding), // Only left padding as leading handles space
      iconColor: iconFg,
      textColor: iconFg,
    );
  }

  Widget _buildRecentItem(String title, {int? index, bool isLast = false, VoidCallback? onTap}) {
    bool isSelected = index != null && index == widget.selectedChatIndex;
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.chat_bubble_outline), // Placeholder for alignment
      title: Text(
        title,
        style: TextStyle(
          color: isLast ? iconFg.withOpacity(0.38) : (isSelected ? accent : iconFg),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding), // Only left padding as leading handles space
      tileColor: isSelected ? accent.withOpacity(0.1) : null,
      selectedTileColor: accent.withOpacity(0.1),
      selectedColor: accent,
    );
  }

  // New method to show user options menu
  void _showUserOptions(BuildContext context) {
    // Get the render box of the ListTile to position the menu accurately
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;
    final double screenHeight = MediaQuery.of(context).size.height;
    final double screenWidth = MediaQuery.of(context).size.width;

    // The 'bottom' property of RelativeRect.fromLTRB defines the distance from
    // the bottom of the *stack* (the entire screen) to the bottom of the *anchor area*.
    // To make the menu open *above* the ListTile, we want the bottom of its anchor
    // area to be at the *top* of the ListTile.
    final double menuAnchorBottom = screenHeight - offset.dy; // Distance from screen bottom to ListTile's top

    showMenu<String>(
      context: context,
      // Define the anchor area. The menu will try to open above this area if possible.
      position: RelativeRect.fromLTRB(
        offset.dx, // Left edge of the menu anchor aligns with left of ListTile
        0,         // Top can be 0, as showMenu will determine actual top position
        screenWidth - (offset.dx + size.width), // Right edge of the menu anchor aligns with right of ListTile
        menuAnchorBottom, // Bottom of the menu anchor aligns with top of ListTile
      ),
      color: bg, // Match app background
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withOpacity(.3)),
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'settings',
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.settings, color: iconFg, size: 20),
              const SizedBox(width: 12),
              Text('Settings', style: TextStyle(color: iconFg)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'logout',
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.logout, color: iconFg, size: 20),
              const SizedBox(width: 12),
              Text('Logout', style: TextStyle(color: iconFg)),
            ],
          ),
        ),
      ],
      elevation: 8.0,
    ).then((value) {
      if (value == 'settings') {
        widget.onSettingsTapped(); // Use the existing callback for settings
      } else if (value == 'logout') {
        print('Logout pressed');
        // TODO: Implement actual logout logic here
      }
    });
  }
}