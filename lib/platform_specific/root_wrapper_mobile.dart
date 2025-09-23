// lib/platform_specific/root_wrapper_mobile.dart
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/pages/projects_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart'; // NEW
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart'; // Reusing desktop sidebar structure
import 'package:chuk_chat/services/chat_storage_service.dart'; // For new chat

// Extension to add darken method to Color
extension ColorUtils on Color {
  Color darken([double amount = .1]) {
    assert(amount >= 0 && amount <= 1);
    final hsl = HSLColor.fromColor(this);
    final hslDark = hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0));
    return hslDark.toColor();
  }
}

class RootWrapperMobile extends StatefulWidget {
  // Theme properties passed down from ChukChatApp
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;
  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor;
  final bool grainEnabled;
  final Function(bool) setGrainEnabled;

  const RootWrapperMobile({
    Key? key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor,
    required this.grainEnabled,
    required this.setGrainEnabled,
  }) : super(key: key);

  @override
  State<RootWrapperMobile> createState() => _RootWrapperMobileState();
}

class _RootWrapperMobileState extends State<RootWrapperMobile> {
  bool _isSidebarExpanded = false; // Manages the sliding sidebar state
  final GlobalKey<ChukChatUIMobileState> _chatUIMobileKey = GlobalKey(); // Global key for chat UI methods

  void _toggleSidebar() {
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  void _openSettingsPage() {
    if (_isSidebarExpanded) _toggleSidebar(); // Close sidebar if open
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(
        currentThemeMode: widget.currentThemeMode,
        currentAccentColor: widget.currentAccentColor,
        currentIconFgColor: widget.currentIconFgColor,
        currentBgColor: widget.currentBgColor,
        setThemeMode: widget.setThemeMode,
        setAccentColor: widget.setAccentColor,
        setIconFgColor: widget.setIconFgColor,
        setBgColor: widget.setBgColor,
        grainEnabled: widget.grainEnabled,
        setGrainEnabled: widget.setGrainEnabled,
      ),
    ));
  }

  void _openProjectsPage() {
    if (_isSidebarExpanded) _toggleSidebar(); // Close sidebar if open
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProjectsPage()));
  }

  void _handleChatTapped(int index) {
    setState(() {
      ChatStorageService.selectedChatIndex = index;
    });
    if (_isSidebarExpanded) _toggleSidebar(); // Close sidebar after chat selected
  }

  // Mobile version of the 'New Chat' button action
  void _newChatFromSidebar() {
    _chatUIMobileKey.currentState?.newChat(); // Call newChat method on mobile chat UI
    if (_isSidebarExpanded) _toggleSidebar();
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03);

    // Sidebar width for mobile: 80% of screen width, clamped at a reasonable max (e.g., 320px)
    final double sidebarVisibleWidth = math.min(screenWidth * 0.8, 320.0);

    return Scaffold(
      backgroundColor: Colors.transparent, // Background handled by root MaterialApp
      body: Stack(
        children: [
          // Layer 1: Main Chat UI, which will be covered by the sidebar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? sidebarVisibleWidth : 0,
            right: _isSidebarExpanded ? -sidebarVisibleWidth : 0,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              onTap: _isSidebarExpanded ? _toggleSidebar : null, // Tap outside closes sidebar
              child: AbsorbPointer(
                absorbing: _isSidebarExpanded, // Absorb pointers on chat when sidebar is open
                child: Column(
                  children: [
                    // Custom AppBar for mobile
                    AppBar(
                      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                      elevation: 0,
                      leading: IconButton(
                        icon: Icon(Icons.menu, color: iconFg, size: 24),
                        onPressed: _toggleSidebar, // Opens sidebar
                      ),
                      title: Text(
                        ChatStorageService.selectedChatIndex == -1
                            ? 'New Chat'
                            : 'Chat ${ChatStorageService.selectedChatIndex + 1}',
                        style: Theme.of(context).appBarTheme.titleTextStyle,
                      ),
                      actions: [
                        // New Chat Button (replaces the one in sidebar for quick access)
                        IconButton(
                          icon: Icon(Icons.edit_square, color: iconFg),
                          onPressed: _newChatFromSidebar, // Mobile-specific new chat
                        ),
                        // Projects and Settings button (moved to AppBar for quick access)
                        IconButton(
                          icon: Icon(Icons.folder_open, color: iconFg),
                          onPressed: _openProjectsPage,
                        ),
                        IconButton(
                          icon: Icon(Icons.settings, color: iconFg),
                          onPressed: _openSettingsPage,
                        ),
                      ],
                    ),
                    Expanded(
                      child: ChukChatUIMobile( // Using the mobile-specific chat UI
                        key: _chatUIMobileKey,
                        onToggleSidebar: _toggleSidebar, // Pass callback
                        selectedChatIndex: ChatStorageService.selectedChatIndex,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Layer 2: Animierte Sidebar, die über die Chat-UI schiebt
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? 0 : -sidebarVisibleWidth,
            top: 0,
            bottom: 0,
            width: sidebarVisibleWidth,
            child: Container( // Wrap sidebar with a Container for specific background
              color: sidebarBg,
              child: SidebarDesktop( // Reusing the desktop sidebar content
                onChatItemTapped: _handleChatTapped,
                onSettingsTapped: _openSettingsPage, // These will close the sidebar first
                onProjectsTapped: _openProjectsPage, // These will close the sidebar first
                selectedChatIndex: ChatStorageService.selectedChatIndex,
                isCompactMode: true, // Sidebar itself will likely adapt to be more compact
              ),
            ),
          ),
        ],
      ),
    );
  }
}