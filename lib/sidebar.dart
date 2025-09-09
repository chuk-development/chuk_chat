// sidebar.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';

final List<String> _starredChats = ['Book writing Per chapter']; // Kept local for now

class CustomSidebar extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped; // Still passed, though Projects is now a top-level button
  final int selectedChatIndex;

  const CustomSidebar({
    Key? key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    required this.selectedChatIndex,
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
    // Wenn sich der ausgewählte Chat-Index ändert, lösen wir einen Rebuild aus,
    // um die neue Auswahl hervorzuheben.
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      if (mounted) setState(() {});
    }
    // Die vorherige Zeile, die 'oldWidget.savedChats.length' zu vergleichen versuchte,
    // war ein Kompilierungsfehler, da CustomSidebar keine 'savedChats'-Eigenschaft besitzt.
    // ChatStorageService ist ein statischer Dienst. Wenn sich dessen Daten ändern (z.B. über saveChat),
    // ruft es selbst loadSavedChatsForSidebar() auf.
    // Damit die UI diese Änderungen widerspiegelt, muss CustomSidebar neu aufgebaut werden.
    // Aktuell werden Rebuilds ausgelöst durch:
    // 1. Initialer Zustand (initState ruft _loadChatsAndRefresh auf)
    // 2. Änderungen des selectedChatIndex (dieser didUpdateWidget-Block)
    // 3. Erstellung eines neuen Chats (main.darts newChat ruft ChatStorageService.loadSavedChatsForSidebar() auf
    //    und setzt selectedChatIndex, was dann Punkt 2 auslöst, wenn die Seitenleiste aktiv ist)
    // Ein zusätzliches explizites Aktualisieren basierend auf der Länge von 'savedChats' in didUpdateWidget
    // ist weder notwendig noch ohne die Umwandlung von ChatStorageService in einen Observable
    // ordnungsgemäß implementierbar.
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: bg,
      child: Column(
        children: [
          // Give initial vertical space for the top toolbar elements outside the sidebar
          // (Menu button, chuk.chat title, New Chat button, Projects button)
          const SizedBox(height: 160.0), // ~ (16 top padding + 48 menu + 8 spacing + 40 new chat + 8 spacing + 40 projects) = 160


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
                  // Attempt to get a more meaningful title from the first message, if available.
                  // For now, it's still a placeholder.
                  String title = 'Chat ${index + 1}';
                  // if (ChatStorageService.savedChats[index].isNotEmpty) {
                  //   final messageParts = ChatStorageService.savedChats[index].split('§');
                  //   if (messageParts.isNotEmpty) {
                  //     final firstMessage = messageParts.first.split('|');
                  //     if (firstMessage.length == 2 && firstMessage[0] == 'user') {
                  //       title = firstMessage[1].substring(0, math.min(firstMessage[1].length, 30)) + (firstMessage[1].length > 30 ? '...' : '');
                  //     }
                  //   }
                  // }

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