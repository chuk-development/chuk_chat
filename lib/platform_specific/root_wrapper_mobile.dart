// lib/platform_specific/root_wrapper_mobile.dart
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/pages/projects_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart'; // UPDATED: Use mobile sidebar
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/* ---------- ROOT WRAPPER MOBILE (for Phones) ---------- */
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
    super.key,
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
  });

  @override
  State<RootWrapperMobile> createState() => _RootWrapperMobileState();
}

class _RootWrapperMobileState extends State<RootWrapperMobile> {
  bool _isSidebarExpanded = false;
  final GlobalKey<ChukChatUIMobileState> _chatUIMobileKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ensureMicrophonePermission();
  }

  Future<void> _ensureMicrophonePermission() async {
    if (!Platform.isAndroid) {
      return;
    }

    final PermissionStatus status = await Permission.microphone.status;
    if (status.isGranted || status.isLimited) {
      return;
    }

    if (status.isDenied || status.isRestricted) {
      await Permission.microphone.request();
      return;
    }

    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  void _openSettingsPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    Navigator.of(context).push(
      MaterialPageRoute(
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
      ),
    );
  }

  void _openProjectsPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ProjectsPage()));
  }

  void _openAssistantsPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ComingSoonPage(
          title: 'Assistants',
          message: 'Assistants are coming soon.',
        ),
      ),
    );
  }

  void _handleChatTapped(int index) {
    setState(() {
      ChatStorageService.selectedChatIndex = index;
    });
    if (_isSidebarExpanded) _toggleSidebar();
  }

  Future<void> _handleChatDeleted(String _) async {
    setState(() {});
  }

  void _newChatFromAppBar() {
    _chatUIMobileKey.currentState?.newChat();
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    final double sidebarVisibleWidth = math.min(screenWidth * 0.7, 280.0);
    final double titleAvailableWidth =
        screenWidth -
        kFixedLeftPadding -
        kMenuButtonHeight -
        (3 * kFixedLeftPadding) -
        (ChatStorageService.savedChats.isNotEmpty ? kButtonVisualHeight : 0);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? sidebarVisibleWidth : 0,
            right: _isSidebarExpanded ? -sidebarVisibleWidth : 0,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              onTap: _isSidebarExpanded ? _toggleSidebar : null,
              onHorizontalDragEnd: (DragEndDetails details) {
                // Only handle swipe when sidebar is closed
                if (_isSidebarExpanded) return;

                // If the swipe velocity is positive (left to right) and significant
                if (details.primaryVelocity != null &&
                    details.primaryVelocity! > 500) {
                  _toggleSidebar();
                }
              },
              child: AbsorbPointer(
                absorbing: _isSidebarExpanded,
                child: Column(
                  children: [
                    AppBar(
                      backgroundColor: Theme.of(
                        context,
                      ).scaffoldBackgroundColor,
                      elevation: 0,
                      leading: IconButton(
                        icon: Icon(Icons.menu, color: iconFg, size: 24),
                        onPressed: _toggleSidebar,
                        tooltip: 'Open menu',
                      ),
                      title: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        width: _isSidebarExpanded ? 0 : titleAvailableWidth,
                        constraints: BoxConstraints(
                          minWidth: _isSidebarExpanded
                              ? 0
                              : math.min(100, titleAvailableWidth),
                        ),
                        child: ClipRect(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 4.0),
                            child: Text(
                              'chuk.chat',
                              style: TextStyle(color: iconFg, fontSize: 16),
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ),
                      actions: [
                        // The "New Chat" button is now always visible on mobile
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: IconButton(
                            icon: Icon(Icons.edit_square, color: iconFg),
                            onPressed: _newChatFromAppBar,
                            tooltip: 'New Chat',
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: ChukChatUIMobile(
                        key: _chatUIMobileKey,
                        onToggleSidebar: _toggleSidebar,
                        selectedChatIndex: ChatStorageService.selectedChatIndex,
                        isSidebarExpanded: _isSidebarExpanded,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? 0 : -sidebarVisibleWidth,
            top: 0,
            bottom: 0,
            width: sidebarVisibleWidth,
            child: SidebarMobile(
              // UPDATED: Use SidebarMobile
              onChatItemTapped: _handleChatTapped,
              onSettingsTapped: _openSettingsPage,
              onProjectsTapped: _openProjectsPage,
              onAssistantsTapped: _openAssistantsPage,
              onChatDeleted: _handleChatDeleted,
              selectedChatIndex: ChatStorageService.selectedChatIndex,
              isCompactMode: true,
            ),
          ),
        ],
      ),
    );
  }
}
