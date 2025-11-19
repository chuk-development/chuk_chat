// lib/platform_specific/root_wrapper_desktop.dart
import 'package:flutter/material.dart';
import 'dart:math' as math;

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart'; // UPDATED
import 'package:chuk_chat/pages/projects_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/* ---------- ROOT WRAPPER DESKTOP (for Desktop, Web, and Tablets) ---------- */
class RootWrapperDesktop extends StatefulWidget {
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

  final bool showReasoningTokens;
  final Function(bool) setShowReasoningTokens;
  final bool showModelInfo;
  final Function(bool) setShowModelInfo;

  const RootWrapperDesktop({
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
    required this.showReasoningTokens,
    required this.setShowReasoningTokens,
    required this.showModelInfo,
    required this.setShowModelInfo,
  });

  @override
  State<RootWrapperDesktop> createState() => _RootWrapperDesktopState();
}

class _RootWrapperDesktopState extends State<RootWrapperDesktop> {
  bool _isSidebarExpanded = false;

  final GlobalKey<ChukChatUIDesktopState> _chatUIKey = GlobalKey();

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
          showReasoningTokens: widget.showReasoningTokens,
          setShowReasoningTokens: widget.setShowReasoningTokens,
          showModelInfo: widget.showModelInfo,
          setShowModelInfo: widget.setShowModelInfo,
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
    // On desktop, the sidebar typically remains open after selecting a chat.
    // if (_isSidebarExpanded) _toggleSidebar();
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  Future<void> _handleChatDeleted(String _) async {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    final bool isCompactMode = screenWidth < kCompactModeBreakpoint;

    final double sidebarVisibleWidth = isCompactMode
        ? screenWidth * 0.8
        : 280.0;
    final double effectiveSidebarWidth = math.min(
      screenWidth,
      sidebarVisibleWidth,
    );

    final bool showContent = !isCompactMode || !_isSidebarExpanded;
    final Widget chatArea = ChukChatUIDesktop(
      key: _chatUIKey,
      onToggleSidebar: _toggleSidebar,
      selectedChatIndex: ChatStorageService.selectedChatIndex,
      isSidebarExpanded: _isSidebarExpanded,
      isCompactMode: isCompactMode,
      showReasoningTokens: widget.showReasoningTokens,
      showModelInfo: widget.showModelInfo,
    );

    return Scaffold(
      body: Stack(
        children: [
          if (showContent)
            Positioned.fill(
              left: (!isCompactMode && _isSidebarExpanded)
                  ? effectiveSidebarWidth
                  : 0,
              child: chatArea,
            ),

          // Always build sidebar to preserve state, but hide it when collapsed
          Positioned(
            left: _isSidebarExpanded ? 0 : -effectiveSidebarWidth,
            top: 0,
            bottom: 0,
            width: effectiveSidebarWidth,
            child: AnimatedOpacity(
              opacity: _isSidebarExpanded ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_isSidebarExpanded,
                child: SidebarDesktop(
                  onChatItemTapped: _handleChatTapped,
                  onSettingsTapped: _openSettingsPage,
                  onProjectsTapped: _openProjectsPage,
                  onChatDeleted: _handleChatDeleted,
                  selectedChatIndex: ChatStorageService.selectedChatIndex,
                  isCompactMode: isCompactMode,
                  showAssistantsButton: !isCompactMode || _isSidebarExpanded,
                ),
              ),
            ),
          ),

          // Layer 3: Hamburger-Menü
          Positioned(
            top: kTopInitialSpacing,
            left: kFixedLeftPadding,
            child: IconButton(
              icon: Icon(Icons.menu, color: iconFg, size: 24),
              onPressed: _toggleSidebar,
            ),
          ),

          // Layer 4: Title
          Positioned(
            top:
                kTopInitialSpacing +
                (kMenuButtonHeight - kButtonVisualHeight) / 2,
            left: kFixedLeftPadding + kMenuButtonHeight + 16,
            child: InkWell(
              onTap: () {},
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: kButtonVisualHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isSidebarExpanded)
                      SizedBox(
                        width: 100,
                        child: ClipRect(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 10.0),
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

          // Layer 5: New Chat (External for Desktop)
          if (!isCompactMode || _isSidebarExpanded)
            Positioned(
              top:
                  kTopInitialSpacing +
                  kMenuButtonHeight +
                  kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: InkWell(
                onTap: () {
                  _chatUIKey.currentState?.newChat();
                  if (_isSidebarExpanded) _toggleSidebar();
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: kButtonVisualHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_square, color: iconFg),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: _isSidebarExpanded ? 100 : 0,
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

          // Layer 6: Projects (External for Desktop)
          if (!isCompactMode || _isSidebarExpanded)
            Positioned(
              top:
                  kTopInitialSpacing +
                  kMenuButtonHeight +
                  kSpacingBetweenTopButtons +
                  kButtonVisualHeight +
                  kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: InkWell(
                onTap: _openProjectsPage,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: kButtonVisualHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_open, color: iconFg),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: _isSidebarExpanded ? 100 : 0,
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

          // Layer 7: Assistants (External for Desktop)
          if (!isCompactMode || _isSidebarExpanded)
            Positioned(
              top:
                  kTopInitialSpacing +
                  kMenuButtonHeight +
                  kSpacingBetweenTopButtons +
                  kButtonVisualHeight +
                  kSpacingBetweenTopButtons +
                  kButtonVisualHeight +
                  kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: InkWell(
                onTap: _openAssistantsPage,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: kButtonVisualHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, color: iconFg),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: _isSidebarExpanded ? 100 : 0,
                        constraints: BoxConstraints(
                          minWidth: _isSidebarExpanded ? 100 : 0,
                        ),
                        child: ClipRect(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12.0),
                            child: Text(
                              'Assistants',
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
