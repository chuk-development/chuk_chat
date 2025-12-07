// lib/platform_specific/root_wrapper_desktop.dart
import 'package:flutter/material.dart';
import 'dart:math' as math;

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
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
  final bool autoSendVoiceTranscription;
  final Function(bool) setAutoSendVoiceTranscription;

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
    required this.autoSendVoiceTranscription,
    required this.setAutoSendVoiceTranscription,
  });

  @override
  State<RootWrapperDesktop> createState() => _RootWrapperDesktopState();
}

class _RootWrapperDesktopState extends State<RootWrapperDesktop> {
  bool _isSidebarExpanded = false;
  String? _activeProjectId;

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
          autoSendVoiceTranscription: widget.autoSendVoiceTranscription,
          setAutoSendVoiceTranscription: widget.setAutoSendVoiceTranscription,
        ),
      ),
    );
  }

  void _openProjectsPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectsPage(
          onOpenProject: _openProject,
        ),
      ),
    );
  }

  void _openProject(String projectId) {
    // Close any open pages and go back to root
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _activeProjectId = projectId;
      // Start a new chat for this project
      _chatUIKey.currentState?.newChat();
    });
  }

  void _exitProject() {
    setState(() {
      _activeProjectId = null;
    });
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

  void _handleChatSelected(String? chatId) {
    // CRITICAL: Block rapid chat switching while another chat is loading
    // This is a second line of defense (sidebar also checks this)
    if (ChatStorageService.isLoadingChat) {
      debugPrint('');
      debugPrint('┌─────────────────────────────────────────────────────────────');
      debugPrint('│ 🚫 [ROOT-DESKTOP] BLOCKED - Chat is still loading');
      debugPrint('│ 🚫 [ROOT-DESKTOP] Ignoring selection: $chatId');
      debugPrint('└─────────────────────────────────────────────────────────────');
      return;
    }
    debugPrint('');
    debugPrint('┌─────────────────────────────────────────────────────────────');
    debugPrint('│ 📥 [ROOT-DESKTOP] _handleChatSelected called');
    debugPrint('│ 📥 [ROOT-DESKTOP] New chatId: $chatId');
    debugPrint('│ 📥 [ROOT-DESKTOP] Old selectedChatId: ${ChatStorageService.selectedChatId}');
    debugPrint('│ 📥 [ROOT-DESKTOP] Calling setState() to rebuild...');
    debugPrint('└─────────────────────────────────────────────────────────────');
    setState(() {
      ChatStorageService.selectedChatId = chatId;
    });
    // On desktop, the sidebar typically remains open after selecting a chat.
    // if (_isSidebarExpanded) _toggleSidebar();
  }

  void _toggleSidebar() {
    // Don't allow opening sidebar while streaming to prevent save conflicts
    if (!_isSidebarExpanded && StreamingManager().hasActiveStreams) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please wait for the AI response to finish or cancel it first'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
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
      selectedChatId: ChatStorageService.selectedChatId,
      onChatIdChanged: (newId) {
        // Update the global state when chat UI creates/changes a chat
        // Use setState to ensure parent rebuilds with new ID
        setState(() {
          ChatStorageService.selectedChatId = newId;
        });
      },
      isSidebarExpanded: _isSidebarExpanded,
      isCompactMode: isCompactMode,
      showReasoningTokens: widget.showReasoningTokens,
      showModelInfo: widget.showModelInfo,
      projectId: _activeProjectId,
      onExitProject: _exitProject,
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
                  onChatSelected: _handleChatSelected,
                  onSettingsTapped: _openSettingsPage,
                  onProjectsTapped: _openProjectsPage,
                  onChatDeleted: _handleChatDeleted,
                  selectedChatId: ChatStorageService.selectedChatId,
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
                  // Block new chat while another chat is loading
                  if (ChatStorageService.isLoadingChat) {
                    debugPrint('🚫 [ROOT-DESKTOP] BLOCKED newChat - Chat is still loading');
                    return;
                  }
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

          // Layer 6: Projects (External for Desktop) - Feature Flag
          if (kFeatureProjects && (!isCompactMode || _isSidebarExpanded))
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

          // Layer 7: Assistants (External for Desktop) - Feature Flag
          if (kFeatureAssistants && (!isCompactMode || _isSidebarExpanded))
            Positioned(
              top:
                  kTopInitialSpacing +
                  kMenuButtonHeight +
                  kSpacingBetweenTopButtons +
                  kButtonVisualHeight +
                  kSpacingBetweenTopButtons +
                  (kFeatureProjects ? kButtonVisualHeight + kSpacingBetweenTopButtons : 0),
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
