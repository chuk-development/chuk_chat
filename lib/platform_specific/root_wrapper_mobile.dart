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
import 'package:chuk_chat/services/supabase_service.dart';
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

class _RootWrapperMobileState extends State<RootWrapperMobile>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _isSidebarExpanded = false;
  final GlobalKey<ChukChatUIMobileState> _chatUIMobileKey = GlobalKey();
  late AnimationController _sidebarAnimController;
  late Animation<double> _sidebarAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Initialize smooth sidebar animation
    _sidebarAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250), // Smooth 250ms animation
    );
    _sidebarAnimation = CurvedAnimation(
      parent: _sidebarAnimController,
      curve: Curves.easeInOut, // Smooth easing curve
    );

    // Don't block UI startup - check permission after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureMicrophonePermission();
    });
  }

  @override
  void dispose() {
    _sidebarAnimController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // When app comes back to foreground, refresh the session
    if (state == AppLifecycleState.resumed) {
      _refreshSessionOnResume();
    }
  }

  Future<void> _refreshSessionOnResume() async {
    try {
      debugPrint('App resumed - refreshing session...');
      final session = await SupabaseService.refreshSession();

      if (session == null) {
        // Session couldn't be refreshed - user needs to sign in again
        debugPrint('Session expired - user needs to sign in again');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Session expired. Please sign in again.',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 3),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        // Sign out to force re-authentication
        await SupabaseService.signOut();
      } else {
        debugPrint('Session refreshed successfully');
      }
    } catch (e) {
      debugPrint('Error refreshing session on resume: $e');
    }
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
    // Hide keyboard when opening sidebar
    if (!_isSidebarExpanded) {
      FocusScope.of(context).unfocus();
    }
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
      if (_isSidebarExpanded) {
        _sidebarAnimController.forward(); // Animate in
      } else {
        _sidebarAnimController.reverse(); // Animate out
      }
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
    // Hide keyboard when switching chats
    FocusScope.of(context).unfocus();

    // Update chat index immediately
    ChatStorageService.selectedChatIndex = index;

    // Close the sidebar and trigger rebuild
    setState(() {
      if (_isSidebarExpanded) {
        _isSidebarExpanded = false;
        _sidebarAnimController.reverse();
      }
    });
  }

  Future<void> _handleChatDeleted(String _) async {
    setState(() {});
  }

  void _newChatFromAppBar() {
    // Hide keyboard when creating new chat
    FocusScope.of(context).unfocus();
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

    final Widget mainContent = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _isSidebarExpanded ? _toggleSidebar : null,
      onHorizontalDragEnd: (DragEndDetails details) {
        if (details.primaryVelocity == null) return;

        // Swipe right to open (when closed)
        if (!_isSidebarExpanded && details.primaryVelocity! > 500) {
          _toggleSidebar();
        }
        // Swipe left to close (when open)
        else if (_isSidebarExpanded && details.primaryVelocity! < -500) {
          _toggleSidebar();
        }
      },
      child: IgnorePointer(
        ignoring: _isSidebarExpanded,
        child: Column(
          children: [
            AppBar(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              elevation: 0,
              leading: IconButton(
                icon: Icon(Icons.menu, color: iconFg, size: 24),
                onPressed: _toggleSidebar,
                tooltip: 'Open menu',
              ),
              title: SizedBox(
                width: _isSidebarExpanded ? 0 : titleAvailableWidth,
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
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: AnimatedBuilder(
        animation: _sidebarAnimation,
        builder: (context, child) {
          final animValue = _sidebarAnimation.value;
          final sidebarOffset = -sidebarVisibleWidth + (sidebarVisibleWidth * animValue);

          return Stack(
            children: [
              // Main content that slides right (rebuilds on chat change)
              Positioned.fill(
                left: sidebarVisibleWidth * animValue,
                child: mainContent,
              ),
              // Sidebar that slides in from left
              Positioned(
                left: sidebarOffset,
                top: 0,
                bottom: 0,
                width: sidebarVisibleWidth,
                child: GestureDetector(
                  onHorizontalDragEnd: (DragEndDetails details) {
                    // Swipe left on sidebar to close it
                    if (_isSidebarExpanded &&
                        details.primaryVelocity != null &&
                        details.primaryVelocity! < -500) {
                      _toggleSidebar();
                    }
                  },
                  child: Opacity(
                    opacity: animValue,
                    child: SidebarMobile(
                      onChatItemTapped: _handleChatTapped,
                      onSettingsTapped: _openSettingsPage,
                      onProjectsTapped: _openProjectsPage,
                      onAssistantsTapped: _openAssistantsPage,
                      onChatDeleted: _handleChatDeleted,
                      selectedChatIndex: ChatStorageService.selectedChatIndex,
                      isCompactMode: true,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
