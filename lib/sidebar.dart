// sidebars.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Import colors and other necessary data from main.dart
import 'main.dart'; // Assuming main.dart is in the same directory

// Dummy data for starred and recents (you'd load these from preferences/API)
final List<String> _starredChats = ['Book writing Per chapter'];
List<String> _savedChats = []; // This will be loaded from SharedPreferences

Future<void> loadSavedChatsForSidebar() async {
  final prefs = await SharedPreferences.getInstance();
  _savedChats = prefs.getStringList('savedChats') ?? [];
}

class CustomSidebar extends StatefulWidget {
  final Function() onNewChat;
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final int selectedChatIndex; // To highlight the selected chat

  const CustomSidebar({
    Key? key,
    required this.onNewChat,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.selectedChatIndex,
  }) : super(key: key);

  @override
  State<CustomSidebar> createState() => _CustomSidebarState();
}

class _CustomSidebarState extends State<CustomSidebar> {
  // We'll manage the selected index for the main nav items (Chats, Projects, Artifacts)
  // separately if you decide to add those. For now, we'll focus on the chat list.
  int _selectedPrimaryNavItem = -1; // -1 means no primary item is selected

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh(); // Load chats when the sidebar is initialized
  }

  Future<void> _loadChatsAndRefresh() async {
    await loadSavedChatsForSidebar();
    setState(() {
      // Rebuild the sidebar with loaded chats
    });
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: bg, // Use your defined background color
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                // ChukChat Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16.0, 48.0, 16.0, 20.0),
                  child: Row(
                    children: [
                      Icon(Icons.crop_square, color: iconFg), // Using iconFg
                      const SizedBox(width: 8),
                      Text(
                        'chuk.chat',
                        style: TextStyle(
                          color: iconFg, // Using iconFg for text
                          fontSize: 22,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                ),

                // New chat
                ListTile(
                  leading: const Icon(Icons.add_circle), // Default accent color for add
                  title: const Text('New chat'),
                  onTap: () {
                    widget.onNewChat();
                    Navigator.pop(context); // Close the drawer
                  },
                  tileColor: accent.withOpacity(.2), // Subtle background for new chat
                  selectedTileColor: accent.withOpacity(.4), // Highlight on selection
                  selectedColor: iconFg, // Text color when selected
                  iconColor: accent, // Icon color
                  textColor: accent, // Text color
                  // Override theme for this specific item if needed, but accent works
                ),

                const Divider(color: Colors.white12), // Use a subtle divider

                // Starred Section
                _buildSectionHeader('Starred'),
                ..._starredChats.map((title) => _buildStarredItem(title)).toList(),

                const Divider(color: Colors.white12),

                // Recents Section (using _savedChats)
                _buildSectionHeader('Recents'),
                if (_savedChats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(color: iconFg.withOpacity(0.5)),
                    ),
                  ),
                ..._savedChats.asMap().entries.map((entry) {
                  int index = entry.key;
                  String chatJson = entry.value;
                  // You might need to parse the chatJson to get a meaningful title
                  // For now, let's just use a generic title
                  String title = 'Chat ${index + 1}';
                  bool isSelected = index == widget.selectedChatIndex;
                  return _buildRecentItem(
                    title,
                    index: index,
                    isSelected: isSelected,
                    onTap: () {
                      widget.onChatItemTapped(index);
                      Navigator.pop(context); // Close the drawer
                    },
                  );
                }).toList(),
                // Add a blank item at the end if you want to mimic the image's fade effect
                _buildRecentItem('Herzrequenz vs. Puls', isLast: true, index: -1), // dummy last item

                // Padding to ensure the last recent item isn't too close to the bottom
                const SizedBox(height: 10),
              ],
            ),
          ),
          // User Profile Section at the bottom
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              children: [
                const Divider(color: Colors.white12),
                ListTile(
                  leading: const Icon(Icons.settings), // Use existing settings icon
                  title: const Text('Settings'),
                  onTap: () {
                    widget.onSettingsTapped();
                    Navigator.pop(context); // Close the drawer
                  },
                  // Use your app's default icon and text color
                  iconColor: iconFg,
                  textColor: iconFg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
                ),
                // Replace this with your actual user profile (Dietrich Munier) if needed
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: iconFg.withOpacity(0.3), // A subtle background
                      child: Text('DM',
                          style: TextStyle(color: iconFg, fontSize: 16)),
                    ),
                    title: Text('Dietrich Munier', style: TextStyle(color: iconFg)),
                    subtitle:
                        Text('Free plan', style: TextStyle(color: iconFg.withOpacity(0.7))),
                    trailing: Icon(Icons.keyboard_arrow_down, color: iconFg),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper function for section headers (Starred, Recents)
  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
      child: Text(
        title,
        style: TextStyle(
            color: iconFg, fontSize: 14, fontWeight: FontWeight.bold),
      ),
    );
  }

  // Helper function for starred items
  Widget _buildStarredItem(String title) {
    return ListTile(
      leading: const Icon(Icons.description),
      title: Text(title),
      onTap: () {
        // Handle tap for starred item
      },
      dense: true, // Make list tile a bit smaller
      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
      // Use your app's default icon and text color (iconFg)
      iconColor: iconFg,
      textColor: iconFg,
    );
  }

  // Helper function for recent items
  Widget _buildRecentItem(String title, {int? index, bool isLast = false, VoidCallback? onTap}) {
    bool isSelected = index != null && index == widget.selectedChatIndex;
    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: isLast ? iconFg.withOpacity(0.38) : (isSelected ? accent : iconFg),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
      // Apply background color if selected
      tileColor: isSelected ? accent.withOpacity(0.1) : null,
    );
  }
}