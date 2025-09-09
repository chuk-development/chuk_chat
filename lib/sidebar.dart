// sidebars.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';

final List<String> _starredChats = ['Book writing Per chapter'];
List<String> _savedChats = [];

Future<void> loadSavedChatsForSidebar() async {
  final prefs = await SharedPreferences.getInstance();
  _savedChats = prefs.getStringList('savedChats') ?? [];
}

class CustomSidebar extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
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
  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh();
  }

  Future<void> _loadChatsAndRefresh() async {
    await loadSavedChatsForSidebar();
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
    return Container(
      color: bg,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                const SizedBox(height: 100.0),

                _buildNavItem(
                  icon: Icons.folder_open,
                  title: 'Projects',
                  onTap: widget.onProjectsTapped,
                ),

                // "Settings" is now here
                _buildNavItem(
                  icon: Icons.settings,
                  title: 'Settings',
                  onTap: widget.onSettingsTapped,
                ),

                const Divider(color: Colors.white12),

                _buildSectionHeader('Starred'),
                ..._starredChats.map((title) => _buildStarredItem(title)).toList(),

                const Divider(color: Colors.white12),

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
                  String title = 'Chat ${index + 1}';
                  return _buildRecentItem(
                    title,
                    index: index,
                    onTap: () {
                      widget.onChatItemTapped(index);
                    },
                  );
                }).toList(),
                _buildRecentItem('Herzrequenz vs. Puls', isLast: true),
                const SizedBox(height: 10),
              ],
            ),
          ),
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
                title: Text('Dietrich Munier', style: TextStyle(color: iconFg)),
                // REMOVED: "Free plan" subtitle
                trailing: Icon(Icons.keyboard_arrow_down, color: iconFg),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem({required IconData icon, required String title, required VoidCallback onTap}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      onTap: onTap,
      dense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 4.0),
    );
  }

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

  Widget _buildStarredItem(String title) {
    return ListTile(
      leading: const Icon(Icons.description),
      title: Text(title),
      onTap: () {},
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
      iconColor: iconFg,
      textColor: iconFg,
    );
  }

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
      tileColor: isSelected ? accent.withOpacity(0.1) : null,
      selectedTileColor: accent.withOpacity(0.1),
      selectedColor: accent,
    );
  }
}