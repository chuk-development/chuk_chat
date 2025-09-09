// main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Still needed for LogicalKeyboardKey if not moved
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';
import 'package:ui_elements_flutter/chat/chat_ui.dart';
import 'package:ui_elements_flutter/sidebar.dart';
import 'package:ui_elements_flutter/pages/projects_page.dart';
import 'package:ui_elements_flutter/pages/settings_page.dart';


/* ---------- MAIN ---------- */
void main() => runApp(const ChukChatApp());

class ChukChatApp extends StatelessWidget {
  const ChukChatApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) => MaterialApp(title: 'chuk.chat', debugShowCheckedModeBanner: false, theme: appTheme, home: const RootWrapper());
}

/* ---------- ROOT WRAPPER ---------- */
class RootWrapper extends StatefulWidget {
  const RootWrapper({Key? key}) : super(key: key);
  @override
  State<RootWrapper> createState() => _RootWrapperState();
}

class _RootWrapperState extends State<RootWrapper> {
  // Sidebar is now closed by default
  bool _isSidebarExpanded = false;

  final GlobalKey<ChukChatUIState> _chatUIKey = GlobalKey();

  // Constants for positioning
  static const double _fixedLeftPadding = 8.0; // Left padding for top-left elements
  static const double _topInitialSpacing = 16.0; // Initial vertical spacing from top edge of screen
  static const double _menuButtonHeight = 48.0; // IconButton default height (including implicit padding for touch target)
  static const double _buttonVisualHeight = 40.0; // Height of New Chat/Projects InkWell containers
  static const double _spacingBetweenTopButtons = 8.0; // Vertical/Horizontal spacing between top buttons

  @override
  void initState() {
    super.initState();
    ChatStorageService.loadChats();
    ChatStorageService.loadSavedChatsForSidebar();
  }

  void _openSettingsPage() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  void _openProjectsPage() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProjectsPage()));
  }

  void _handleChatTapped(int index) {
    setState(() {
      ChatStorageService.selectedChatIndex = index;
    });
    print('Loading chat at index: $index');
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    const double sidebarVisibleWidth = 280.0; // Reduced sidebar width

    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: Main Chat UI wrapper (now moves to the right)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? sidebarVisibleWidth : 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: ChukChatUI(
              key: _chatUIKey,
              onToggleSidebar: () {}, // Dummy, as button is handled here
              selectedChatIndex: ChatStorageService.selectedChatIndex,
              isSidebarExpanded: _isSidebarExpanded,
            ),
          ),

          // Layer 2: The Animated Sidebar that slides over the chat UI
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? 0 : -sidebarVisibleWidth, // Slide in from the left
            top: 0,
            bottom: 0,
            width: sidebarVisibleWidth,
            child: CustomSidebar(
              onChatItemTapped: _handleChatTapped,
              onSettingsTapped: _openSettingsPage,
              onProjectsTapped: _openProjectsPage,
              selectedChatIndex: ChatStorageService.selectedChatIndex,
            ),
          ),

          // Layer 3: The Menu button (always top-left)
          Positioned(
            top: _topInitialSpacing,
            left: _fixedLeftPadding,
            child: IconButton(
              icon: const Icon(Icons.menu),
              onPressed: _toggleSidebar,
              color: iconFg,
              iconSize: 24, // Explicit size
              padding: EdgeInsets.zero, // Remove default padding for precise height control
              constraints: BoxConstraints.tightFor(width: _menuButtonHeight, height: _menuButtonHeight), // Make it a square of its height
            ),
          ),

          // Layer 4: The "chuk.chat" title next to the menu (animates text width)
          Positioned(
            top: _topInitialSpacing, // Same top as menu
            left: _fixedLeftPadding + _menuButtonHeight + _spacingBetweenTopButtons, // To the right of menu
            child: InkWell( // Use InkWell for consistent behavior/look with other animated buttons
              onTap: () {}, // No action, just a title
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: _buttonVisualHeight, // Match height of other buttons
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.chat_bubble_outline, color: iconFg), // Example icon for chuk.chat
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      width: _isSidebarExpanded ? 0 : 100, // Text hides when sidebar is open, shows when closed
                      constraints: BoxConstraints(
                        minWidth: _isSidebarExpanded ? 0 : 100,
                      ),
                      child: ClipRect(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            'chuk.chat',
                            style: TextStyle(color: iconFg, fontSize: 16),
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),


          // Layer 5: The "New Chat" button (always below the menu/title row)
          Positioned(
            top: _topInitialSpacing + _menuButtonHeight + _spacingBetweenTopButtons,
            left: _fixedLeftPadding,
            child: InkWell(
              onTap: () {
                _chatUIKey.currentState?.newChat(); // Using the new public method
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: _buttonVisualHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.edit_square, color: iconFg),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      width: _isSidebarExpanded ? 100 : 0, // Text expands with sidebar
                      constraints: BoxConstraints(
                        minWidth: _isSidebarExpanded ? 100 : 0,
                      ),
                      child: ClipRect(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            'New chat',
                            style: TextStyle(color: iconFg, fontSize: 16),
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Layer 6: The "Projects" button (now a top-level button, below New Chat)
          Positioned(
            top: _topInitialSpacing + _menuButtonHeight + _spacingBetweenTopButtons + _buttonVisualHeight + _spacingBetweenTopButtons,
            left: _fixedLeftPadding,
            child: InkWell(
              onTap: _openProjectsPage,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: _buttonVisualHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_open, color: iconFg),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      width: _isSidebarExpanded ? 100 : 0, // Text expands with sidebar
                      constraints: BoxConstraints(
                        minWidth: _isSidebarExpanded ? 100 : 0,
                      ),
                      child: ClipRect(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            'Projects',
                            style: TextStyle(color: iconFg, fontSize: 16),
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}