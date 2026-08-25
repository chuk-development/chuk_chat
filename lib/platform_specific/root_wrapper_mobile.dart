// lib/platform_specific/root_wrapper_mobile.dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:chuk_chat/models/app_mode.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/platform_specific/cowork/cowork_surface.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/pages/workspace_detail_page.dart';
import 'package:chuk_chat/pages/workspaces_page.dart';
import 'package:chuk_chat/pages/media_manager_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart'; // UPDATED: Use mobile sidebar
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/artifact_panel.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:chuk_chat/utils/debug_chat_formatter.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/* ---------- ROOT WRAPPER MOBILE (for Phones) ---------- */
class RootWrapperMobile extends StatefulWidget {
  final AppShellConfig config;

  const RootWrapperMobile({super.key, required this.config});

  @override
  State<RootWrapperMobile> createState() => _RootWrapperMobileState();
}

class _RootWrapperMobileState extends State<RootWrapperMobile>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// Guards the battery-optimization prompt to once per app process so the
  /// system dialog isn't re-shown on every screen unlock. Static so it
  /// survives widget rebuilds within the same launch.
  static bool _batteryPromptedThisLaunch = false;

  bool _isSidebarExpanded = false;
  bool _artifactSheetOpen = false;
  AppMode _mode = AppMode.chat;
  final GlobalKey<ChukChatUIMobileState> _chatUIMobileKey = GlobalKey();
  late AnimationController _sidebarAnimController;
  late Animation<double> _sidebarAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kFeatureArtifacts) {
      // The notifier defaults to true (desktop idles with the panel "open").
      // On mobile the panel is a modal sheet, so force the notifier to false
      // at startup.
      ArtifactStorageService.panelOpenNotifier.value = false;
      ArtifactStorageService.activeArtifactNotifier.addListener(
        _onArtifactChanged,
      );
      // Counter-based open event: fires on every tap even when the panel
      // notifier was already true. This is the primary signal on mobile.
      ArtifactStorageService.openRequestNotifier.addListener(
        _onPanelOpenRequested,
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
              '⚠️ [RootMobile] Deferred dev options init failed: $error',
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
                '⚠️ [RootMobile] Deferred artifact activation failed: $error',
              );
            }
          }
        }),
      );
    }

    // Initialize smooth sidebar animation
    _sidebarAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _sidebarAnimation = CurvedAnimation(
      parent: _sidebarAnimController,
      curve: Curves.easeOutCubic,
    );

    // Don't block UI startup - check permissions after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePermissions();
    });
  }

  @override
  void dispose() {
    if (kFeatureArtifacts) {
      ArtifactStorageService.activeArtifactNotifier.removeListener(
        _onArtifactChanged,
      );
      ArtifactStorageService.openRequestNotifier.removeListener(
        _onPanelOpenRequested,
      );
    }
    _sidebarAnimController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onPanelOpenRequested() {
    if (!mounted) return;
    _maybeOpenArtifactSheet();
  }

  void _onArtifactChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeOpenArtifactSheet();
  }

  void _maybeOpenArtifactSheet() {
    if (_artifactSheetOpen) return;
    if (!ArtifactStorageService.panelOpenNotifier.value) return;
    final artifact = ArtifactStorageService.activeArtifactNotifier.value;
    if (artifact == null) return;
    _openArtifactSheet();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      _refreshSessionOnResume();
      // Re-check permissions on resume — Android can revoke them after
      // an APK update or if the user toggled them in system settings.
      _ensurePermissions();
      // Reconnect the chat socket proactively. While backgrounded, Android
      // Doze freezes the heartbeat timer and the load balancer drops the
      // idle WS — without this the first post-unlock send pays the full
      // reconnect on the critical path. prewarm() reuses a healthy socket
      // and never tears down an in-flight stream.
      unawaited(MultiplexSession.prewarm());
    }
  }

  Future<void> _refreshSessionOnResume() async {
    // No network check here - just try to refresh
    // If it fails due to network, that's fine - user stays logged in
    // This avoids false "offline" detection when screen unlocks
    try {
      final session = await SupabaseService.refreshSession();
      if (session != null) {
        if (kDebugMode) {
          debugPrint('✅ Session refreshed on resume');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ Session refresh on resume failed: $e');
      }
    }
  }

  /// Re-check and request runtime permissions.
  ///
  /// Called both on first launch and on every resume so that permissions
  /// are restored after an APK update or after the user toggles them
  /// in Android system settings.
  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;

    // Microphone
    final micStatus = await Permission.microphone.status;
    if (micStatus.isPermanentlyDenied) {
      _showPermissionBlockedSnackBar('Microphone');
    } else if (micStatus.isDenied || micStatus.isRestricted) {
      await Permission.microphone.request();
    }

    // Notifications (Android 13+ / API 33+)
    final notifStatus = await Permission.notification.status;
    if (notifStatus.isPermanentlyDenied) {
      _showPermissionBlockedSnackBar('Notifications');
    } else if (notifStatus.isDenied || notifStatus.isRestricted) {
      await Permission.notification.request();
    }

    // Battery optimization exemption — without it Android freezes the app
    // shortly after the screen locks, killing in-flight multi-pass tool loops.
    await _ensureBatteryOptimizationDisabled();
  }

  /// Ask the user to exempt the app from battery optimization.
  ///
  /// Re-checks on every cold launch (so it keeps nagging until granted), but
  /// only prompts once per app process to avoid re-spamming the system dialog
  /// on every screen unlock. No-op once the exemption is in place.
  Future<void> _ensureBatteryOptimizationDisabled() async {
    if (!Platform.isAndroid) return;
    if (_RootWrapperMobileState._batteryPromptedThisLaunch) return;

    final ignoring =
        await StreamingForegroundService.isIgnoringBatteryOptimizations();
    if (ignoring || !mounted) return;

    _RootWrapperMobileState._batteryPromptedThisLaunch = true;

    final l = AppLocalizations.of(context);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l?.batteryOptimizationTitle ?? 'Keep responses running'),
        content: Text(
          l?.batteryOptimizationBody ??
              'Android may pause Chuk Chat when the screen is locked, '
                  'cutting off long AI responses and tool steps mid-way. '
                  'Allow unrestricted background activity so replies finish '
                  'even when your phone is locked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l?.batteryOptimizationLater ?? 'Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l?.batteryOptimizationAllow ?? 'Allow'),
          ),
        ],
      ),
    );

    if (proceed == true) {
      await StreamingForegroundService.requestIgnoreBatteryOptimization();
    }
  }

  void _showPermissionBlockedSnackBar(String permissionName) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '$permissionName permission is blocked. Enable it in app settings.',
        ),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: () {
            unawaited(openAppSettings());
          },
        ),
      ),
    );
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
        settings: const RouteSettings(name: 'tour:settings'),
        builder: (_) => SettingsPage(config: widget.config),
      ),
    );
  }

  void _openWorkspacesPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkspacesPage(
          onOpenWorkspace: (workspaceId) {
            // Tap on a workspace card opens the workspace edit/settings
            // view. The user can launch a new chat from inside it via
            // the FAB. Previously this jumped straight into a new chat.
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => WorkspaceDetailPage(
                  workspaceId: workspaceId,
                  onStartNewChat: (id) {
                    final wsId = id ?? workspaceId;
                    // Pop the detail page and the workspaces list so
                    // the new chat sits at the root again.
                    Navigator.of(context)
                      ..pop()
                      ..pop();
                    _chatUIMobileKey.currentState?.startNewChatWithWorkspace(
                      wsId,
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openMediaPage() {
    if (_isSidebarExpanded) _toggleSidebar();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const MediaManagerPage()));
  }

  void _handleChatSelected(String? chatId) {
    // Add guard like desktop has - prevent rapid chat switching during load
    if (ChatStorageService.isLoadingChat) {
      if (kDebugMode) {
        debugPrint('🚫 [ROOT-MOBILE] BLOCKED - Chat is still loading');
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
      debugPrint('│ 📥 [ROOT-MOBILE] _handleChatSelected called');
    }
    if (kDebugMode) {
      debugPrint('│ 📥 [ROOT-MOBILE] New chatId: $chatId');
    }
    if (kDebugMode) {
      debugPrint(
        '│ 📥 [ROOT-MOBILE] Old selectedChatId: ${ChatStorageService.selectedChatId}',
      );
    }
    if (kDebugMode) {
      debugPrint('│ 📥 [ROOT-MOBILE] Calling setState() to rebuild...');
    }
    if (kDebugMode) {
      debugPrint(
        '└─────────────────────────────────────────────────────────────',
      );
    }
    // Hide keyboard when switching chats
    FocusScope.of(context).unfocus();

    // Update chat ID and close sidebar in a single setState to guarantee
    // the widget tree rebuilds with the new selectedChatId.
    setState(() {
      ChatStorageService.selectedChatId = chatId;
      if (_isSidebarExpanded) {
        _isSidebarExpanded = false;
        _sidebarAnimController.reverse();
      }
    });
    if (kFeatureArtifacts) {
      unawaited(
        ArtifactStorageService.setActiveChat(chatId, forceRefresh: false),
      );
    }
  }

  Future<void> _handleChatDeleted(String deletedChatId) async {
    // Prevent keyboard from opening when sidebar is visible
    if (_isSidebarExpanded) {
      FocusScope.of(context).unfocus();
    }
    // deleteChat() clears selectedChatId when the active chat is deleted.
    // If selectedChatId is null here, reset the chat UI to a fresh state.
    if (ChatStorageService.selectedChatId == null) {
      _chatUIMobileKey.currentState?.newChat();
      if (kFeatureArtifacts) {
        unawaited(
          ArtifactStorageService.setActiveChat(null, forceRefresh: true),
        );
      }
    }
    setState(() {});
  }

  void _newChatFromAppBar() {
    // Hide keyboard when creating new chat
    FocusScope.of(context).unfocus();
    _chatUIMobileKey.currentState?.newChat();
    if (kFeatureArtifacts) {
      unawaited(ArtifactStorageService.setActiveChat(null, forceRefresh: true));
    }
  }

  /// Title of the chat in view, or null for a fresh/unsaved chat.
  String? _currentChatTitle() {
    final String? id = ChatStorageService.selectedChatId;
    if (id == null) return null;
    for (final c in ChatStorageService.savedChats) {
      if (c.id == id) {
        final t = c.title?.trim();
        return (t == null || t.isEmpty) ? null : t;
      }
    }
    return null;
  }

  /// The composer's top row, rebuilt as free-floating blocks: a round menu
  /// chip, a translucent title pill that carries the chat name, and round
  /// action chips — each lifted off the background instead of sitting in one
  /// solid app bar.
  Widget _buildFloatingTopBar(Color iconFg, double titleAvailableWidth) {
    final ThemeData theme = Theme.of(context);
    final Color bg = theme.scaffoldBackgroundColor;
    final Color chipBg = Color.alphaBlend(
      theme.colorScheme.surface.withValues(alpha: 0.62),
      bg,
    ).withValues(alpha: 0.86);
    final Color pillBg = Color.alphaBlend(
      theme.colorScheme.surface.withValues(alpha: 0.42),
      bg,
    ).withValues(alpha: 0.55);
    final Color shadowColor = Colors.black.withValues(alpha: 0.30);
    final String? title = _currentChatTitle();

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              KeyedSubtree(
                key: TourKeyRegistry.instance.keyFor(TourSlots.menuButton),
                child: _floatIconChip(
                  icon: Icons.menu,
                  onTap: _toggleSidebar,
                  iconFg: iconFg,
                  chipBg: chipBg,
                  shadowColor: shadowColor,
                  tooltip: 'Open menu',
                  semanticsId: 'menu_button',
                ),
              ),
              const SizedBox(width: 8),
              if (!_isSidebarExpanded)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: titleAvailableWidth),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: pillBg,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: shadowColor,
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: (title != null)
                          ? Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: iconFg.withValues(alpha: 0.92),
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            )
                          : BrandWordmark(
                              color: iconFg.withValues(alpha: 0.92)),
                    ),
                  ),
                ),
              const Spacer(),
              const SizedBox(width: 8),
              _floatIconChip(
                icon: Icons.copy_all,
                onTap: _copyDebugChat,
                iconFg: iconFg,
                chipBg: chipBg,
                shadowColor: shadowColor,
                tooltip: 'Copy full chat',
                semanticsId: 'copy_debug_chat_button',
              ),
              const SizedBox(width: 8),
              _floatIconChip(
                icon: Icons.edit_square,
                onTap: _newChatFromAppBar,
                iconFg: iconFg,
                chipBg: chipBg,
                shadowColor: shadowColor,
                tooltip: 'New Chat',
                semanticsId: 'new_chat_button',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One round, lifted icon chip for the floating top bar.
  Widget _floatIconChip({
    required IconData icon,
    required VoidCallback onTap,
    required Color iconFg,
    required Color chipBg,
    required Color shadowColor,
    required String tooltip,
    required String semanticsId,
  }) {
    return Semantics(
      identifier: semanticsId,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: chipBg,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: shadowColor,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(icon, size: 22, color: iconFg),
            ),
          ),
        ),
      ),
    );
  }

  void _newChatFromSidebar() {
    // Mirrors the close-then-act pattern of _openSettingsPage etc. — the
    // sidebar's "new chat" button needs to collapse the drawer, otherwise
    // the overlay stays mounted on top of the fresh chat until the user
    // dismisses it manually.
    if (_isSidebarExpanded) _toggleSidebar();
    _newChatFromAppBar();
  }

  void _openArtifactSheet() {
    final artifact = ArtifactStorageService.activeArtifactNotifier.value;
    if (artifact == null) return;
    if (_artifactSheetOpen) return;

    _artifactSheetOpen = true;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => ArtifactBottomSheet(
        onOpenSourceChat: (chatId) => _handleChatSelected(chatId),
      ),
    ).whenComplete(() {
      _artifactSheetOpen = false;
      // Clear the "open" flag so the next tap can re-open via the listener.
      if (ArtifactStorageService.panelOpenNotifier.value) {
        ArtifactStorageService.panelOpenNotifier.value = false;
      }
    });
  }

  void _copyDebugChat() {
    final state = _chatUIMobileKey.currentState;
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

  Map<String, String> _debugContext(ChukChatUIMobileState? state) {
    if (state == null) return const {};
    final chatId = state.debugActiveChatId;
    final chat = chatId == null ? null : ChatStorageState.chatsById[chatId];
    final lastSync = ChatSyncService.lastSyncAt;
    return {
      'Model': state.debugModelId,
      'Provider': state.debugProviderSlug ?? '',
      'Workspace': state.debugWorkspaceId ?? '',
      'Reasoning': state.debugReasoningEffort,
      'Platform': 'mobile',
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

  @override
  Widget build(BuildContext context) {
    // sizeOf, not of(): this sits above the Scaffold, so `of` would see the
    // raw animating viewInsets and rebuild the app bar, the chat screen and
    // the whole sidebar on every keyboard frame.
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    // Mobile sidebar fills the entire screen — a full-page panel instead
    // of a partial drawer. Desktop is unaffected (sidebar_desktop.dart is
    // hosted by root_wrapper_desktop.dart in its own layout).
    final double sidebarVisibleWidth = screenWidth;
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
            _buildFloatingTopBar(iconFg, titleAvailableWidth),
            Expanded(
              child: (kFeatureCoWork && _mode == AppMode.cowork)
                  ? const CoWorkSurface()
                  : ChukChatUIMobile(
                      key: _chatUIMobileKey,
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
                            ArtifactStorageService.setActiveChat(
                              newId,
                              forceRefresh: false,
                            ),
                          );
                        }
                      },
                      isSidebarExpanded: _isSidebarExpanded,
                      showReasoningTokens: widget.config.showReasoningTokens,
                      showModelInfo: widget.config.showModelInfo,
                      showTps: widget.config.showTps,
                      autoSendVoiceTranscription:
                          widget.config.autoSendVoiceTranscription,
                      // Image generation settings
                      imageGenEnabled: widget.config.imageGenEnabled,
                      imageGenDefaultSize: widget.config.imageGenDefaultSize,
                      imageGenCustomWidth: widget.config.imageGenCustomWidth,
                      imageGenCustomHeight: widget.config.imageGenCustomHeight,
                      imageGenUseCustomSize:
                          widget.config.imageGenUseCustomSize,
                      includeRecentImagesInHistory:
                          widget.config.includeRecentImagesInHistory,
                      includeAllImagesInHistory:
                          widget.config.includeAllImagesInHistory,
                      includeReasoningInHistory:
                          widget.config.includeReasoningInHistory,
                      includeToolResultsInHistory:
                          widget.config.includeToolResultsInHistory,
                      toolCallingEnabled: widget.config.toolCallingEnabled,
                      toolDiscoveryMode: widget.config.toolDiscoveryMode,
                      showToolCalls: widget.config.showToolCalls,
                      allowMarkdownToolCalls:
                          widget.config.allowMarkdownToolCalls,
                    ),
            ),
          ],
        ),
      ),
    );

    // Built once per build, not once per animation frame. Constructing
    // SidebarMobile inside the AnimatedBuilder handed the framework a new
    // widget instance 60 times a second, and the sidebar rebuilds its whole
    // chat list, time buckets and footer every time — while it is off
    // screen.
    final Widget sidebar = GestureDetector(
      onHorizontalDragEnd: (DragEndDetails details) {
        // Swipe left on sidebar to close it
        if (_isSidebarExpanded &&
            details.primaryVelocity != null &&
            details.primaryVelocity! < -500) {
          _toggleSidebar();
        }
      },
      child: SidebarMobile(
        onChatSelected: _handleChatSelected,
        onSettingsTapped: _openSettingsPage,
        onWorkspacesTapped: _openWorkspacesPage,
        onMediaTapped: _openMediaPage,
        onNewChatTapped: _newChatFromSidebar,
        onChatDeleted: _handleChatDeleted,
        selectedChatId: ChatStorageService.selectedChatId,
        isCompactMode: true,
        mode: _mode,
        onModeChanged: (m) => setState(() => _mode = m),
      ),
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: AnimatedBuilder(
        animation: _sidebarAnimation,
        builder: (context, child) {
          final animValue = _sidebarAnimation.value;
          final sidebarOffset =
              -sidebarVisibleWidth + (sidebarVisibleWidth * animValue);

          return Stack(
            children: [
              // Main content that slides right - keeps full width to prevent layout collapse
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(sidebarVisibleWidth * animValue, 0),
                  child: mainContent,
                ),
              ),
              // Sidebar that slides in from left
              Positioned(
                left: sidebarOffset,
                top: 0,
                bottom: 0,
                width: sidebarVisibleWidth,
                child: sidebar,
              ),
            ],
          );
        },
      ),
    );
  }
}
