// lib/platform_specific/root_wrapper_desktop.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'dart:math' as math;

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_mode.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/platform_specific/cowork/cowork_surface.dart';
import 'package:chuk_chat/widgets/cowork_mode_switcher.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart';
import 'package:chuk_chat/pages/workspace_detail_page.dart';
import 'package:chuk_chat/pages/workspaces_page.dart';
import 'package:chuk_chat/pages/media_manager_page.dart';
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/widgets/artifact_panel.dart';
import 'package:chuk_chat/utils/debug_chat_formatter.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/* ---------- ROOT WRAPPER DESKTOP (for Desktop, Web, and Tablets) ---------- */
class RootWrapperDesktop extends StatefulWidget {
  final AppShellConfig config;

  const RootWrapperDesktop({super.key, required this.config});

  @override
  State<RootWrapperDesktop> createState() => _RootWrapperDesktopState();
}

class _RootWrapperDesktopState extends State<RootWrapperDesktop> {
  bool _isSidebarExpanded = false;
  bool _hasOpenedSidebar = false;
  AppMode _mode = AppMode.chat;

  /// Switch mode. Mirrors the choice into [appModeNotifier] so the far-away
  /// readers (connectors page, model-awareness prompt) see it too.
  void _setMode(AppMode m) {
    setState(() => _mode = m);
    appModeNotifier.value = m;
  }

  String? _activeProjectId;
  String? _activePanel; // 'projects', 'media', or null
  ArtifactDocument? _activeArtifact;
  bool _panelOpen = true;

  /// User-preferred artifact panel width. Null = default 50%.
  double? _userArtifactPanelWidth;

  final GlobalKey<ChukChatUIDesktopState> _chatUIKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (kFeatureArtifacts) {
      _activeArtifact = ArtifactStorageService.activeArtifactNotifier.value;
      _panelOpen = ArtifactStorageService.panelOpenNotifier.value;
      ArtifactStorageService.activeArtifactNotifier.addListener(
        _onArtifactChanged,
      );
      ArtifactStorageService.panelOpenNotifier.addListener(_onPanelOpenChanged);
      // When the user explicitly requests to open an artifact (inline chat
      // card or media manager tap), yield the side panel slot to the
      // artifact panel — otherwise an open media/projects panel would hide
      // it because `_activePanel` wins over `hasArtifact` in `effectivePanel`.
      ArtifactStorageService.openRequestNotifier.addListener(
        _onArtifactOpenRequested,
      );
    }
    // Defer non-critical startup work to keep first interactions responsive.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 8), () async {
        if (!mounted) return;
        try {
          await DeveloperOptionsService.initialize();
          await DeveloperOptionsService.syncFromSupabase(forceRefresh: false);
        } catch (error) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [RootDesktop] Deferred dev options init failed: $error',
            );
          }
        }
      }),
    );
    if (kFeatureArtifacts) {
      unawaited(
        Future<void>.delayed(const Duration(seconds: 2), () async {
          if (!mounted) return;
          try {
            await ArtifactStorageService.setActiveChat(
              ChatStorageService.selectedChatId,
              forceRefresh: false,
            );
          } catch (error) {
            if (kDebugMode) {
              debugPrint(
                '⚠️ [RootDesktop] Deferred artifact activation failed: $error',
              );
            }
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    if (kFeatureArtifacts) {
      ArtifactStorageService.activeArtifactNotifier.removeListener(
        _onArtifactChanged,
      );
      ArtifactStorageService.panelOpenNotifier.removeListener(
        _onPanelOpenChanged,
      );
      ArtifactStorageService.openRequestNotifier.removeListener(
        _onArtifactOpenRequested,
      );
    }
    super.dispose();
  }

  void _onArtifactChanged() {
    if (!mounted) return;
    final newArtifact = ArtifactStorageService.activeArtifactNotifier.value;
    setState(() {
      _activeArtifact = newArtifact;
    });
    // Do NOT auto-open the panel on every notifier change. Opening a chat
    // that already has artifacts would otherwise force the panel open without
    // the user asking for it. The panel opens explicitly via requestOpen()
    // (inline-card taps) and from create/rewrite flows (new AI artifacts).
  }

  void _onPanelOpenChanged() {
    if (!mounted) return;
    setState(() {
      _panelOpen = ArtifactStorageService.panelOpenNotifier.value;
    });
  }

  void _onArtifactOpenRequested() {
    if (!mounted) return;
    if (_activePanel != null) {
      setState(() => _activePanel = null);
    }
  }

  void _closeArtifactPanel() {
    ArtifactStorageService.panelOpenNotifier.value = false;
  }

  // Jump to the chat that produced the currently shown artifact. We close
  // any side panel (media/workspaces) so the chat area becomes visible, and
  // also exit any active workspace scope so the chat lands in its real home.
  void _openSourceChatForArtifact(String chatId) {
    if (ChatStorageService.isLoadingChat) return;
    setState(() {
      _activePanel = null;
      _activeProjectId = null;
      ChatStorageService.selectedChatId = chatId;
    });
    if (kFeatureArtifacts) {
      unawaited(
        ArtifactStorageService.setActiveChat(chatId, forceRefresh: false),
      );
    }
  }

  void _openSettingsPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    // Desktop shows settings as a modal popup over the chat UI (left rail +
    // content pane) instead of a full-screen route. See desktop_settings_modal.
    unawaited(showDesktopSettingsModal(context, config: widget.config));
  }

  void _openWorkspacesPage() {
    setState(() {
      if (_activePanel == 'workspaces') {
        _activePanel = null;
      } else {
        _activePanel = 'workspaces';
      }
    });
  }

  void _openWorkspace(String workspaceId) {
    // Open the workspace edit/settings page first; from there the user
    // can launch a new chat via the FAB. Previous behaviour skipped the
    // detail view and jumped straight into a fresh chat.
    setState(() {
      _activePanel = null; // Close workspace list/panel
    });
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkspaceDetailPage(
          workspaceId: workspaceId,
          onStartNewChat: (id) {
            Navigator.of(context).pop();
            _startWorkspaceChat(id ?? workspaceId);
          },
        ),
      ),
    );
  }

  void _startWorkspaceChat(String workspaceId) {
    setState(() {
      _activeProjectId = workspaceId;
      _activePanel = null;
      _chatUIKey.currentState?.newChat();
    });
    if (kFeatureArtifacts) {
      unawaited(ArtifactStorageService.setActiveChat(null, forceRefresh: true));
    }
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
      // Close workspaces full-page view when a chat is selected
      if (_activePanel == 'workspaces') {
        _activePanel = null;
      }
    });
    if (kFeatureArtifacts) {
      unawaited(
        ArtifactStorageService.setActiveChat(chatId, forceRefresh: false),
      );
    }
    // On desktop, the sidebar typically remains open after selecting a chat.
    // if (_isSidebarExpanded) _toggleSidebar();
  }

  void _toggleSidebar() {
    // Allow opening sidebar even while streaming - streams continue in background
    setState(() {
      if (!_isSidebarExpanded) {
        _hasOpenedSidebar = true;
      }
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  void _copyDebugChat() {
    final state = _chatUIKey.currentState;
    final messages = state?.debugMessages;
    if (messages == null || messages.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No messages to copy')));
      return;
    }
    final text = DebugChatFormatter.format(
      messages,
      context: _debugContext(state),
    );
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Copied ${messages.length} messages (debug, images redacted)',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Map<String, String> _debugContext(ChukChatUIDesktopState? state) {
    if (state == null) return const {};
    final chatId = state.debugActiveChatId;
    final chat = chatId == null ? null : ChatStorageState.chatsById[chatId];
    final lastSync = ChatSyncService.lastSyncAt;
    return {
      'Model': state.debugModelId,
      'Provider': state.debugProviderSlug ?? '',
      'Workspace': state.debugWorkspaceId ?? '',
      'Reasoning': state.debugReasoningEffort,
      'Platform': 'desktop',
      'Chat ID': chatId ?? '',
      'Chat UpdatedAt (local)': chat?.updatedAt?.toIso8601String() ?? '',
      'Chat Fully Loaded': (chat?.isFullyLoaded ?? false).toString(),
      'Chat Pending Save':
          chatId != null && ChatStorageState.pendingSaves.containsKey(chatId)
          ? 'true'
          : 'false',
      'Chat Saving':
          chatId != null && ChatStorageState.savingChats.contains(chatId)
          ? 'true'
          : 'false',
      'Sync Enabled': ChatSyncService.isEnabled.toString(),
      'Sync In Progress': ChatSyncService.isSyncing.toString(),
      'Sync First Done': ChatSyncService.hasCompletedFirstSync.toString(),
      'Sync Last At': lastSync?.toIso8601String() ?? 'never',
      'Sync Last Result': ChatSyncService.lastSyncOutcome ?? '',
    };
  }

  // Mini-rail icons. Visible only when sidebar is collapsed. Each row is
  // kButtonVisualHeight tall and sits flush under the brand area so the
  // icon centres line up perfectly with the SbRailRow icons inside the
  // expanded sidebar.
  List<Widget> _buildMiniRail(Color iconFg, AppLocalizations l) {
    final List<Widget> items = [];
    int rowIndex = 0;
    Widget railIcon({
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
    }) {
      final double top =
          kTopInitialSpacing +
          kMenuButtonHeight +
          rowIndex * kButtonVisualHeight;
      rowIndex++;
      return Positioned(
        top: top,
        left: kFixedLeftPadding,
        child: SizedBox(
          width: kMenuButtonHeight,
          height: kButtonVisualHeight,
          child: IconButton(
            icon: Icon(icon, color: iconFg, size: 24),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.standard,
            constraints: BoxConstraints.tightFor(
              width: kMenuButtonHeight,
              height: kButtonVisualHeight,
            ),
            tooltip: tooltip,
            onPressed: onPressed,
          ),
        ),
      );
    }

    items.add(
      railIcon(
        icon: Icons.edit_square,
        tooltip: l.newChat,
        onPressed: _handleNewChatFromSidebar,
      ),
    );
    if (kFeatureWorkspaces) {
      items.add(
        railIcon(
          icon: Icons.folder_rounded,
          tooltip: l.workspaces,
          onPressed: _openWorkspacesPage,
        ),
      );
    }
    if (kFeatureMediaManager) {
      items.add(
        railIcon(
          icon: Icons.image_rounded,
          tooltip: l.media,
          onPressed: _openMediaPage,
        ),
      );
    }
    return items;
  }

  void _handleNewChatFromSidebar() {
    if (ChatStorageService.isLoadingChat) {
      if (kDebugMode) {
        debugPrint('🚫 [ROOT-DESKTOP] BLOCKED newChat - Chat is still loading');
      }
      return;
    }
    // Close any right-side panel (workspaces/media) AND drop the workspace
    // scope before creating the new chat — otherwise the new chat is
    // hidden behind a full-page panel and the user has to back out manually.
    setState(() {
      _activePanel = null;
      _activeProjectId = null;
    });
    _chatUIKey.currentState?.newChat();
    if (kFeatureArtifacts) {
      unawaited(ArtifactStorageService.setActiveChat(null, forceRefresh: true));
    }
    if (_isSidebarExpanded) _toggleSidebar();
  }

  Future<void> _handleChatDeleted(String deletedChatId) async {
    // deleteChat() clears selectedChatId when the active chat is deleted.
    // If selectedChatId is null here, reset the chat UI to a fresh state.
    final shouldStartFresh = ChatStorageService.selectedChatId == null;
    if (shouldStartFresh) {
      _activeProjectId = null;
      _chatUIKey.currentState?.newChat();
      if (kFeatureArtifacts) {
        unawaited(
          ArtifactStorageService.setActiveChat(null, forceRefresh: true),
        );
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final l = AppLocalizations.of(context)!;

    final bool isCompactMode = screenWidth < kCompactModeBreakpoint;

    final double sidebarVisibleWidth = isCompactMode
        ? screenWidth * 0.85
        : 320.0;
    final double effectiveSidebarWidth = math.min(
      screenWidth,
      sidebarVisibleWidth,
    );

    final bool isWorkspacesFullPage = _activePanel == 'workspaces';
    // CoWork runtime mode — same app, swaps the chat area for the CoWork
    // surface. See docs/COWORK_BUILD_PLAN.md.
    final bool isCoWork = kFeatureCoWork && _mode == AppMode.cowork;
    final bool showContent =
        (!isCompactMode || !_isSidebarExpanded) &&
        !isWorkspacesFullPage &&
        !isCoWork;
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
        if (kFeatureArtifacts) {
          unawaited(
            ArtifactStorageService.setActiveChat(newId, forceRefresh: false),
          );
        }
      },
      isSidebarExpanded: _isSidebarExpanded,
      isCompactMode: isCompactMode,
      // "More models" in the composer opens the redesigned settings modal on
      // the model section, not the standalone old page.
      onOpenModelSettings: () => showDesktopSettingsModal(
        context,
        config: widget.config,
        initialSectionId: 'model',
      ),
      showReasoningTokens: widget.config.showReasoningTokens,
      showModelInfo: widget.config.showModelInfo,
      showTps: widget.config.showTps,
      workspaceId: _activeProjectId,
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
      includeToolResultsInHistory: widget.config.includeToolResultsInHistory,
      toolCallingEnabled: widget.config.toolCallingEnabled,
      toolDiscoveryMode: widget.config.toolDiscoveryMode,
      showToolCalls: widget.config.showToolCalls,
      allowMarkdownToolCalls: widget.config.allowMarkdownToolCalls,
      autoSendVoiceTranscription: widget.config.autoSendVoiceTranscription,
    );

    // Right panel width for Projects/Media/Artifacts.
    // Minimum chat width of 300px required to show panel
    const double minChatWidth = 300.0;
    const double minPanelWidth = 320.0;
    final double sidebarWidth = _isSidebarExpanded ? effectiveSidebarWidth : 0;
    final double availableForPanel = screenWidth - sidebarWidth - minChatWidth;
    final bool hasArtifact =
        kFeatureArtifacts && _activeArtifact != null && _panelOpen;
    // Artifacts use user-dragged width (default 50%); other panels cap at 400px.
    final double contentWidth = screenWidth - sidebarWidth;
    final double defaultArtifactWidth = (contentWidth * 0.5).clamp(
      minPanelWidth,
      math.max(minPanelWidth, contentWidth - minChatWidth),
    );
    final double maxPanelWidth = hasArtifact
        ? (_userArtifactPanelWidth ?? defaultArtifactWidth).clamp(
            minPanelWidth,
            math.max(minPanelWidth, contentWidth - minChatWidth),
          )
        : 400.0;
    final double panelWidth = availableForPanel >= minPanelWidth
        ? math.min(maxPanelWidth, availableForPanel)
        : 0;
    // Assistants is full-page, not a side panel
    final String? effectivePanel = _activePanel == 'workspaces'
        ? null
        : (_activePanel ?? (hasArtifact ? 'artifact' : null));
    final bool showPanel =
        effectivePanel != null && !isCompactMode && panelWidth > 0;

    // Debug: Log panel state when active
    if (effectivePanel != null) {
      if (kDebugMode) {
        debugPrint(
          '📐 Panel: type=$effectivePanel, screen=$screenWidth, sidebar=$sidebarWidth, available=$availableForPanel, panelWidth=$panelWidth, showPanel=$showPanel',
        );
      }
    }

    return Scaffold(
      body: Stack(
        children: [
          // Always keep chatArea in the tree to avoid GlobalKey
          // removal/insertion conflicts.  Hide via Offstage when the
          // sidebar covers the full screen in compact mode or assistants
          // is showing full-page.
          Positioned.fill(
            // Reserve 48px for collapsed sidebar icons when artifact panel
            // is open, so chat content doesn't slide under the hamburger.
            left: (!isCompactMode && _isSidebarExpanded)
                ? effectiveSidebarWidth
                : (showPanel && effectivePanel == 'artifact' ? 48 : 0),
            right: showPanel ? panelWidth : 0,
            child: Offstage(offstage: !showContent, child: chatArea),
          ),

          // Full-page workspaces view (replaces chat area)
          if (isWorkspacesFullPage)
            Positioned.fill(
              left: _isSidebarExpanded
                  ? effectiveSidebarWidth
                  : 48, // Leave space for collapsed sidebar buttons
              child: WorkspacesPage(
                onOpenWorkspace: (workspaceId) {
                  _openWorkspace(workspaceId);
                },
              ),
            ),

          // Full-page CoWork surface (replaces chat area in CoWork mode)
          if (isCoWork)
            Positioned.fill(
              left: _isSidebarExpanded ? effectiveSidebarWidth : 48,
              child: const CoWorkSurface(),
            ),

          // Right Panel (Projects/Media/Artifact)
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
                child: effectivePanel == 'artifact'
                    // Artifacts use ArtifactPanel's own header (with copy/download).
                    ? ArtifactPanel(
                        artifact: _activeArtifact!,
                        showHeader: true,
                        onClose: _closeArtifactPanel,
                        onOpenSourceChat: _openSourceChatForArtifact,
                      )
                    : Column(
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
                                  effectivePanel == 'projects'
                                      ? Icons.folder_open
                                      : Icons.photo_library_outlined,
                                  color: iconFg,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  effectivePanel == 'projects'
                                      ? l.workspaces
                                      : l.media,
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
                            child: effectivePanel == 'projects'
                                ? WorkspacesPage(
                                    onOpenWorkspace: _openWorkspace,
                                    embedded: true,
                                  )
                                : const MediaManagerPage(embedded: true),
                          ),
                        ],
                      ),
              ),
            ),

          // Draggable divider — only for artifact panel (user can resize).
          if (showPanel && effectivePanel == 'artifact')
            Positioned(
              right: panelWidth - 3,
              top: 0,
              bottom: 0,
              width: 6,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      final newW =
                          (_userArtifactPanelWidth ?? panelWidth) -
                          details.delta.dx;
                      _userArtifactPanelWidth = newW.clamp(
                        minPanelWidth,
                        math.max(minPanelWidth, contentWidth - minChatWidth),
                      );
                    });
                  },
                  child: Center(
                    child: Container(
                      width: 1,
                      color: iconFg.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ),
            ),

          // Lazy-mount sidebar to keep startup frame light.
          if (_isSidebarExpanded || _hasOpenedSidebar)
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
                    onWorkspacesTapped: _openWorkspacesPage,
                    onMediaTapped: _openMediaPage,
                    onNewChatTapped: _handleNewChatFromSidebar,
                    onChatDeleted: _handleChatDeleted,
                    selectedChatId: ChatStorageService.selectedChatId,
                    isCompactMode: isCompactMode,
                    showWorkspacesButton: !isCompactMode || _isSidebarExpanded,
                    mode: _mode,
                    onModeChanged: _setMode,
                  ),
                ),
              ),
            ),

          // Hamburger menu — stays anchored at the top-left, never moves.
          // Uses an IconButton sized 48×40 so its elliptical splash matches
          // the mini-rail icons below (which are also 48-wide IconButtons
          // sized to kButtonVisualHeight). Without the 48×40 box the
          // splash would render as a perfect circle instead of the egg-
          // shaped ellipse the rail icons have, and the two wouldn't
          // match visually when the sidebar is collapsed.
          Positioned(
            top:
                kTopInitialSpacing +
                (kMenuButtonHeight - kButtonVisualHeight) / 2,
            left: kFixedLeftPadding,
            child: KeyedSubtree(
              key: TourKeyRegistry.instance.keyFor(TourSlots.menuButton),
              child: SizedBox(
                width: kMenuButtonHeight,
                height: kButtonVisualHeight,
                child: IconButton(
                  icon: Icon(Icons.menu_rounded, color: iconFg, size: 24),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.standard,
                  constraints: const BoxConstraints.tightFor(
                    width: kMenuButtonHeight,
                    height: kButtonVisualHeight,
                  ),
                  onPressed: _toggleSidebar,
                ),
              ),
            ),
          ),

          // CoWork mode switcher — collapsed-sidebar fallback only. When the
          // sidebar is open the switcher lives inside it, under the New chat
          // row; here it sits next to the hamburger so the mini-rail keeps
          // access to it. Same app, runtime mode.
          if (kFeatureCoWork && !_isSidebarExpanded)
            Positioned(
              top: kTopInitialSpacing + 3,
              left: kFixedLeftPadding + kMenuButtonHeight + 4,
              child: CoWorkModeSwitcher(
                mode: _mode,
                onChanged: _setMode,
              ),
            ),

          // Mini rail — visible only when sidebar is collapsed. Each icon's
          // visual centre lines up *exactly* with the matching SbRailRow in
          // the expanded sidebar: brand row is kMenuButtonHeight (48) tall,
          // then nav rows are kButtonVisualHeight (40) tall. Search is NOT
          // in the mini-rail — only New chat, Workspaces, Media.
          if (!_isSidebarExpanded) ..._buildMiniRail(iconFg, l),

          // Copy full chat button (top-right of chat area)
          if (showContent && _activeProjectId == null)
            Positioned(
              top: kTopInitialSpacing,
              right: (showPanel ? panelWidth : 0) + 12,
              child: IconButton(
                icon: Icon(Icons.copy_all_rounded, color: iconFg, size: 20),
                onPressed: _copyDebugChat,
                tooltip: 'Copy full chat',
              ),
            ),
        ],
      ),
    );
  }
}
