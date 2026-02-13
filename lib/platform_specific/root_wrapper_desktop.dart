// lib/platform_specific/root_wrapper_desktop.dart
import 'package:flutter/material.dart';
import 'dart:math' as math;

import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart'; // UPDATED
import 'package:chuk_chat/pages/projects_page.dart';
import 'package:chuk_chat/pages/media_manager_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';

/* ---------- ROOT WRAPPER DESKTOP (for Desktop, Web, and Tablets) ---------- */
class RootWrapperDesktop extends StatefulWidget {
  final AppShellConfig config;

  const RootWrapperDesktop({super.key, required this.config});

  @override
  State<RootWrapperDesktop> createState() => _RootWrapperDesktopState();
}

class _RootWrapperDesktopState extends State<RootWrapperDesktop> {
  bool _isSidebarExpanded = false;
  String? _activeProjectId;
  String? _activePanel; // 'projects', 'media', or null

  final GlobalKey<ChukChatUIDesktopState> _chatUIKey = GlobalKey();

  void _openSettingsPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(config: widget.config)),
    );
  }

  void _openProjectsPage() {
    // Toggle projects panel - don't close sidebar
    setState(() {
      if (_activePanel == 'projects') {
        _activePanel = null;
      } else {
        _activePanel = 'projects';
      }
    });
  }

  void _openProject(String projectId) {
    setState(() {
      _activeProjectId = projectId;
      _activePanel = null; // Close projects panel
      // Start a new chat for this project
      _chatUIKey.currentState?.newChat();
    });
  }

  void _exitProject() {
    setState(() {
      _activeProjectId = null;
    });
  }

  void _closePanel() {
    setState(() {
      _activePanel = null;
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

  void _openMediaPage() {
    // Toggle media panel - don't close sidebar
    setState(() {
      if (_activePanel == 'media') {
        _activePanel = null;
      } else {
        _activePanel = 'media';
      }
    });
  }

  void _handleChatSelected(String? chatId) {
    // CRITICAL: Block rapid chat switching while another chat is loading
    // This is a second line of defense (sidebar also checks this)
    if (ChatStorageService.isLoadingChat) {
      if (kDebugMode) {
        debugPrint('');
      }
      if (kDebugMode) {
        debugPrint(
          '┌─────────────────────────────────────────────────────────────',
        );
      }
      if (kDebugMode) {
        debugPrint('│ 🚫 [ROOT-DESKTOP] BLOCKED - Chat is still loading');
      }
      if (kDebugMode) {
        debugPrint('│ 🚫 [ROOT-DESKTOP] Ignoring selection: $chatId');
      }
      if (kDebugMode) {
        debugPrint(
          '└─────────────────────────────────────────────────────────────',
        );
      }
      return;
    }
    if (kDebugMode) {
      debugPrint('');
    }
    if (kDebugMode) {
      debugPrint(
        '┌─────────────────────────────────────────────────────────────',
      );
    }
    if (kDebugMode) {
      debugPrint('│ 📥 [ROOT-DESKTOP] _handleChatSelected called');
    }
    if (kDebugMode) {
      debugPrint('│ 📥 [ROOT-DESKTOP] New chatId: $chatId');
    }
    if (kDebugMode) {
      debugPrint(
        '│ 📥 [ROOT-DESKTOP] Old selectedChatId: ${ChatStorageService.selectedChatId}',
      );
    }
    if (kDebugMode) {
      debugPrint('│ 📥 [ROOT-DESKTOP] Calling setState() to rebuild...');
    }
    if (kDebugMode) {
      debugPrint(
        '└─────────────────────────────────────────────────────────────',
      );
    }
    setState(() {
      ChatStorageService.selectedChatId = chatId;
    });
    // On desktop, the sidebar typically remains open after selecting a chat.
    // if (_isSidebarExpanded) _toggleSidebar();
  }

  void _toggleSidebar() {
    // Allow opening sidebar even while streaming - streams continue in background
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  Future<void> _handleChatDeleted(String deletedChatId) async {
    // If the deleted chat is the one currently displayed, start a new chat
    if (ChatStorageService.selectedChatId == deletedChatId) {
      _activeProjectId = null; // Clear project context
      _chatUIKey.currentState?.newChat();
    }
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
      showReasoningTokens: widget.config.showReasoningTokens,
      showModelInfo: widget.config.showModelInfo,
      showTps: widget.config.showTps,
      projectId: _activeProjectId,
      onExitProject: _exitProject,
      // Image generation settings
      imageGenEnabled: widget.config.imageGenEnabled,
      imageGenDefaultSize: widget.config.imageGenDefaultSize,
      imageGenCustomWidth: widget.config.imageGenCustomWidth,
      imageGenCustomHeight: widget.config.imageGenCustomHeight,
      imageGenUseCustomSize: widget.config.imageGenUseCustomSize,
      includeRecentImagesInHistory: widget.config.includeRecentImagesInHistory,
      includeAllImagesInHistory: widget.config.includeAllImagesInHistory,
      includeReasoningInHistory: widget.config.includeReasoningInHistory,
    );

    // Panel width for Projects/Media - responsive based on screen width
    // Minimum chat width of 300px required to show panel
    const double minChatWidth = 300.0;
    const double minPanelWidth = 320.0;
    final double sidebarWidth = _isSidebarExpanded ? effectiveSidebarWidth : 0;
    final double availableForPanel = screenWidth - sidebarWidth - minChatWidth;
    final double panelWidth = availableForPanel >= minPanelWidth
        ? math.min(400.0, availableForPanel)
        : 0;
    final bool showPanel =
        _activePanel != null && !isCompactMode && panelWidth > 0;

    // Debug: Log panel state when active
    if (_activePanel != null) {
      if (kDebugMode) {
        debugPrint(
          '📐 Panel: screen=$screenWidth, sidebar=$sidebarWidth, available=$availableForPanel, panelWidth=$panelWidth, showPanel=$showPanel',
        );
      }
    }

    return Scaffold(
      body: Stack(
        children: [
          if (showContent)
            Positioned.fill(
              left: (!isCompactMode && _isSidebarExpanded)
                  ? effectiveSidebarWidth
                  : 0,
              right: showPanel ? panelWidth : 0,
              child: chatArea,
            ),

          // Projects/Media Panel (right side)
          if (showPanel)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: panelWidth,
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(
                    left: BorderSide(color: iconFg.withValues(alpha: 0.2)),
                  ),
                ),
                child: Column(
                  children: [
                    // Panel header with close button
                    Container(
                      height: 56,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: iconFg.withValues(alpha: 0.1),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _activePanel == 'projects'
                                ? Icons.folder_open
                                : Icons.photo_library_outlined,
                            color: iconFg,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _activePanel == 'projects' ? 'Projects' : 'Media',
                            style: TextStyle(
                              color: iconFg,
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(Icons.close, color: iconFg),
                            onPressed: _closePanel,
                            tooltip: 'Close',
                          ),
                        ],
                      ),
                    ),
                    // Panel content
                    Expanded(
                      child: _activePanel == 'projects'
                          ? ProjectsPage(
                              onOpenProject: _openProject,
                              embedded: true,
                            )
                          : const MediaManagerPage(embedded: true),
                    ),
                  ],
                ),
              ),
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
                  onMediaTapped: _openMediaPage,
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
                              'Chuk Chat',
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
                    if (kDebugMode) {
                      debugPrint(
                        '🚫 [ROOT-DESKTOP] BLOCKED newChat - Chat is still loading',
                      );
                    }
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
                  (kFeatureProjects
                      ? kButtonVisualHeight + kSpacingBetweenTopButtons
                      : 0),
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

          // Layer 8: Media Manager (External for Desktop) - Feature Flag
          if (kFeatureMediaManager && (!isCompactMode || _isSidebarExpanded))
            Positioned(
              top:
                  kTopInitialSpacing +
                  kMenuButtonHeight +
                  kSpacingBetweenTopButtons +
                  kButtonVisualHeight +
                  kSpacingBetweenTopButtons +
                  (kFeatureProjects
                      ? kButtonVisualHeight + kSpacingBetweenTopButtons
                      : 0) +
                  (kFeatureAssistants
                      ? kButtonVisualHeight + kSpacingBetweenTopButtons
                      : 0),
              left: kFixedLeftPadding,
              child: InkWell(
                onTap: _openMediaPage,
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
                      Icon(Icons.photo_library_outlined, color: iconFg),
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
                              'Media',
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
