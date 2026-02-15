// lib/platform_specific/root_wrapper_mobile.dart
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/pages/projects_page.dart';
import 'package:chuk_chat/pages/media_manager_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart'; // UPDATED: Use mobile sidebar
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';

/* ---------- ROOT WRAPPER MOBILE (for Phones) ---------- */
class RootWrapperMobile extends StatefulWidget {
  final AppShellConfig config;

  const RootWrapperMobile({super.key, required this.config});

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

    // Don't block UI startup - check permissions after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePermissions();
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

    if (state == AppLifecycleState.resumed) {
      _refreshSessionOnResume();
      // Re-check permissions on resume — Android can revoke them after
      // an APK update or if the user toggled them in system settings.
      _ensurePermissions();
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
    if (micStatus.isDenied || micStatus.isRestricted) {
      await Permission.microphone.request();
    }

    // Notifications (Android 13+ / API 33+)
    final notifStatus = await Permission.notification.status;
    if (notifStatus.isDenied || notifStatus.isRestricted) {
      await Permission.notification.request();
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
      MaterialPageRoute(builder: (_) => SettingsPage(config: widget.config)),
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
  }

  Future<void> _handleChatDeleted(String deletedChatId) async {
    // Prevent keyboard from opening when sidebar is visible
    if (_isSidebarExpanded) {
      FocusScope.of(context).unfocus();
    }
    // If the deleted chat is the one currently displayed, start a new chat
    if (ChatStorageService.selectedChatId == deletedChatId) {
      _chatUIMobileKey.currentState?.newChat();
    }
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
              leading: Semantics(
                identifier: 'menu_button',
                child: IconButton(
                  icon: Icon(Icons.menu, color: iconFg, size: 24),
                  onPressed: _toggleSidebar,
                  tooltip: 'Open menu',
                ),
              ),
              title: SizedBox(
                width: _isSidebarExpanded ? 0 : titleAvailableWidth,
                child: ClipRect(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4.0),
                    child: Text(
                      'Chuk Chat',
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
                  child: Semantics(
                    identifier: 'new_chat_button',
                    child: IconButton(
                      icon: Icon(Icons.edit_square, color: iconFg),
                      onPressed: _newChatFromAppBar,
                      tooltip: 'New Chat',
                    ),
                  ),
                ),
              ],
            ),
            Expanded(
              child: ChukChatUIMobile(
                key: _chatUIMobileKey,
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
                imageGenUseCustomSize: widget.config.imageGenUseCustomSize,
                includeRecentImagesInHistory:
                    widget.config.includeRecentImagesInHistory,
                includeAllImagesInHistory:
                    widget.config.includeAllImagesInHistory,
                includeReasoningInHistory:
                    widget.config.includeReasoningInHistory,
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
                      onChatSelected: _handleChatSelected,
                      onSettingsTapped: _openSettingsPage,
                      onProjectsTapped: _openProjectsPage,
                      onMediaTapped: _openMediaPage,
                      onAssistantsTapped: _openAssistantsPage,
                      onChatDeleted: _handleChatDeleted,
                      selectedChatId: ChatStorageService.selectedChatId,
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
