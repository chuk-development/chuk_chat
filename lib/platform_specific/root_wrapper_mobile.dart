// lib/platform_specific/root_wrapper_mobile.dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/pages/workspace_detail_page.dart';
import 'package:chuk_chat/pages/workspaces_page.dart';
import 'package:chuk_chat/pages/media_manager_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_top_bar.dart';
import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart'; // UPDATED: Use mobile sidebar
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/accent_icon_button.dart';
import 'package:chuk_chat/widgets/artifact_panel.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;
import 'package:chuk_chat/utils/debug_chat_formatter.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart'
    show sbChatDateLine;
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart'
    show deriveSidebarChatTitle, kSidebarAddComputerLabel;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/platform_specific/chat/chat_debug_snapshot.dart';
import 'package:chuk_chat/services/share/share_intent_service.dart';

/* ---------- ROOT WRAPPER MOBILE (for Phones) ---------- */
class RootWrapperMobile extends StatefulWidget {
  final AppShellConfig config;

  /// Takes the place of the title pill in the floating top bar. The Agents
  /// build puts its Chat | Agents switch here. Shown in a new chat only; an
  /// open chat shows its title pill. Null draws the title pill, as chuk_chat
  /// always has.
  final Widget? headerCenter;

  /// Reads the chat in view. Null reads `ChatStorageService.selectedChatId`,
  /// the app-wide pointer, as chuk_chat always has. The Agents build shares
  /// that pointer with its agent thread, so it hands in a reader that
  /// always answers with this chat.
  final ValueGetter<String?>? selectedChatIdReader;

  /// The Agents build's "Add your computer" entry, drawn as a row in the
  /// sidebar. Null, as in chuk_chat, draws nothing.
  final VoidCallback? onAddComputer;

  /// The Agents build's phone layout for the Chats half (owner, 2026-11-05):
  /// no drawer, no bottom bar. [MobileTopBar] holds the menu chip,
  /// [headerCenter] (the Chats | Agents switch) and the new-chat button, and
  /// under them a [ChatTitleStrip] that names the chat in view. A sideways
  /// swipe on the chat moves to the next or previous chat ([SwipeChatPager])
  /// in the same chat view; a tap on the strip opens the chat list.
  ///
  /// False, the default, is chuk_chat's layout unchanged: the floating top
  /// bar and the sliding sidebar.
  final bool swipeNavigation;

  const RootWrapperMobile({
    super.key,
    required this.config,
    this.headerCenter,
    this.selectedChatIdReader,
    this.onAddComputer,
    this.swipeNavigation = false,
  });

  @override
  State<RootWrapperMobile> createState() => _RootWrapperMobileState();
}

class _RootWrapperMobileState extends State<RootWrapperMobile>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// Guards the battery-optimization prompt to once per app process so the
  /// system dialog isn't re-shown on every screen unlock. Static so it
  /// survives widget rebuilds within the same launch.
  static bool _batteryPromptedThisLaunch = false;

  /// Same guard for the notification prompt: asked at most once per app
  /// process, never again on every resume.
  static bool _notificationPromptedThisLaunch = false;

  /// Asks for the signed-in permissions the moment the user signs in, so
  /// the login page never shows a system prompt.
  StreamSubscription<AuthState>? _authSubscription;

  bool _isSidebarExpanded = false;
  bool _artifactSheetOpen = false;

  final GlobalKey<ChukChatUIMobileState> _chatUIMobileKey = GlobalKey();

  /// The chat in view (see [RootWrapperMobile.selectedChatIdReader]).
  String? get _selectedChatId {
    final ValueGetter<String?>? read = widget.selectedChatIdReader;
    return read != null ? read() : ChatStorageService.selectedChatId;
  }

  late AnimationController _sidebarAnimController;
  late Animation<double> _sidebarAnimation;

  /// Swipe mode only ([RootWrapperMobile.swipeNavigation]): shares the
  /// pager's drag with the title strip.
  SwipeChatPagerController? _swipeController;

  /// Swipe mode only: rebuilds the entries when a chat is created, renamed,
  /// deleted or reordered by a new message.
  StreamSubscription<String?>? _chatListSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.swipeNavigation) _startSwipeNavigation();
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
              _selectedChatId,
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
    try {
      _authSubscription = SupabaseService.auth.onAuthStateChange.listen((
        AuthState state,
      ) {
        if (state.event == AuthChangeEvent.signedIn) _ensurePermissions();
      });
    } catch (_) {
      // Supabase not configured: there is no sign-in to wait for.
    }

    // Content shared into the app from the system share sheet.
    ShareIntentService.instance.incoming.addListener(_onShareIncoming);
    _onShareIncoming();
  }

  /// Handled after the frame, never inside the notification: the Agents
  /// shell listens to the same share and first brings the Chats half to the
  /// front.
  void _onShareIncoming() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeShare());
    WidgetsBinding.instance.scheduleFrame();
  }

  /// A share for the app itself (not for one agent) opens a new chat with
  /// the shared text and files in the composer. A plain build has no agents,
  /// so a share that names one (a contact left from an Agents build) lands
  /// here too.
  void _takeShare([int attempt = 0]) {
    if (!mounted) return;
    final SharedContent? share = ShareIntentService.instance.incoming.value;
    if (share == null || (share.agentId != null && kFeatureAgents)) return;
    if (_chatUIMobileKey.currentState == null) {
      // The chat view is not built yet (first frame after sign-in).
      if (attempt < 20) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _takeShare(attempt + 1),
        );
      }
      return;
    }
    ShareIntentService.instance.take();
    Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    if (_isSidebarExpanded) _toggleSidebar();
    _newChatFromAppBar();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _chatUIMobileKey.currentState?.applySharedContent(share),
    );
  }

  @override
  void dispose() {
    ShareIntentService.instance.incoming.removeListener(_onShareIncoming);
    if (kFeatureArtifacts) {
      ArtifactStorageService.activeArtifactNotifier.removeListener(
        _onArtifactChanged,
      );
      ArtifactStorageService.openRequestNotifier.removeListener(
        _onPanelOpenRequested,
      );
    }
    _stopSwipeNavigation(unmounting: true);
    _sidebarAnimController.dispose();
    _authSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RootWrapperMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.swipeNavigation != oldWidget.swipeNavigation) {
      if (widget.swipeNavigation) {
        _startSwipeNavigation();
      } else {
        _stopSwipeNavigation();
      }
    }
  }

  void _startSwipeNavigation() {
    _swipeController ??= SwipeChatPagerController();
    _chatListSubscription ??= ChatStorageService.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _stopSwipeNavigation({bool unmounting = false}) {
    final StreamSubscription<String?>? sub = _chatListSubscription;
    _chatListSubscription = null;
    if (sub != null) unawaited(sub.cancel());
    final SwipeChatPagerController? controller = _swipeController;
    _swipeController = null;
    if (controller == null) return;
    if (unmounting) {
      // The pager below has already been unmounted (children go first).
      controller.dispose();
    } else {
      // The pager still holds it until this frame drops it.
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
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
      // A sign-in that finished in the browser lands here; the guards
      // inside keep this from asking twice.
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

  /// Asks for the runtime permissions the app needs in the background.
  ///
  /// Only when signed in: the login page never shows a system prompt.
  /// Each prompt at most once per launch. The microphone, the camera and
  /// the location are not asked here: the feature that uses them asks at
  /// the moment the user starts it (recording, voice call, map).
  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid || !mounted) return;
    if (!_isSignedIn()) return;

    // Notifications (Android 13+ / API 33+): replies and agent messages
    // that finish while the app is in the background.
    if (!_RootWrapperMobileState._notificationPromptedThisLaunch) {
      _RootWrapperMobileState._notificationPromptedThisLaunch = true;
      final PermissionStatus notifStatus = await Permission.notification.status;
      if (notifStatus.isDenied) {
        await Permission.notification.request();
      }
    }

    // Battery optimization exemption — without it Android freezes the app
    // shortly after the screen locks, killing in-flight multi-pass tool loops.
    if (!mounted) return;
    await _ensureBatteryOptimizationDisabled();
  }

  bool _isSignedIn() {
    try {
      return SupabaseService.auth.currentUser != null;
    } catch (_) {
      return false;
    }
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

  void _toggleSidebar() {
    // Hide keyboard when opening sidebar
    if (!_isSidebarExpanded) {
      FocusManager.instance.primaryFocus?.unfocus();
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
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MediaManagerPage()));
  }

  /// [keepKeyboard]: a swipe moves on to the next chat while the user may
  /// be typing; the keyboard stays up (owner, 2026-11-10). Every other way
  /// of opening a chat closes it.
  void _handleChatSelected(String? chatId, {bool keepKeyboard = false}) {
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
    // Hide keyboard when switching chats, except on a swipe.
    if (!keepKeyboard) FocusManager.instance.primaryFocus?.unfocus();

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
      FocusManager.instance.primaryFocus?.unfocus();
    }
    // deleteChat() clears selectedChatId when the active chat is deleted.
    // If selectedChatId is null here, reset the chat UI to a fresh state.
    if (_selectedChatId == null) {
      _chatUIMobileKey.currentState?.newChat();
      if (kFeatureArtifacts) {
        unawaited(
          ArtifactStorageService.setActiveChat(null, forceRefresh: true),
        );
      }
    }
    setState(() {});
  }

  void _newChatFromAppBar({bool keepKeyboard = false}) {
    // Hide keyboard when creating new chat, except on a swipe.
    if (!keepKeyboard) FocusManager.instance.primaryFocus?.unfocus();
    _chatUIMobileKey.currentState?.newChat();
    if (kFeatureArtifacts) {
      unawaited(ArtifactStorageService.setActiveChat(null, forceRefresh: true));
    }
  }

  /// Title of the chat in view, or null for a fresh/unsaved chat.
  String? _currentChatTitle() {
    final String? id = _selectedChatId;
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
  Widget _buildFloatingTopBar(Color iconFg) {
    // Chips and pill share the composer's surface through
    // [FloatingChromeSurface], so the floating chrome of the chat and of the
    // sidebar cannot drift apart.
    final String? title = _currentChatTitle();
    final Color pageColor = Theme.of(context).scaffoldBackgroundColor;

    return DecoratedBox(
      // The chat runs on underneath this bar, so the bar holds the page down
      // behind it: page colour at the status bar, nothing at all by its
      // lower edge. Without it a table or a heading scrolls straight across
      // the clock and the title pill.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [pageColor, pageColor, pageColor.withValues(alpha: 0)],
          stops: const [0.0, 0.62, 1.0],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          // The chips take a 48 px press around a 42 px paint; the 3 px of slop
          // comes out of the margins so the painted chips keep their place.
          padding: const EdgeInsets.fromLTRB(7, 8, 10, 6),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                KeyedSubtree(
                  key: TourKeyRegistry.instance.anchorFor(TourSlots.menuButton),
                  child: _floatIconChip(
                    icon: Icons.menu,
                    onTap: _toggleSidebar,
                    iconFg: iconFg,
                    tooltip: 'Open menu',
                    semanticsId: 'menu_button',
                  ),
                ),
                const SizedBox(width: 5),
                // Expanded, not a fixed width + Spacer: the title takes exactly
                // the room left after the two right-hand buttons, so a long
                // title ellipsises with "…" instead of pushing the buttons off
                // the right edge. Left-aligned so a short title hugs the menu.
                // A [RootWrapperMobile.headerCenter] takes the pill's place in
                // a new chat; an open chat shows its title pill.
                Expanded(
                  child: _isSidebarExpanded
                      ? const SizedBox.shrink()
                      : Align(
                          alignment: Alignment.centerLeft,
                          child:
                              (_selectedChatId == null
                                  ? widget.headerCenter
                                  : null) ??
                              FloatingChromeSurface(
                                radius: 18,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 11,
                                ),
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
                                        color: iconFg.withValues(alpha: 0.92),
                                      ),
                              ),
                        ),
                ),
                const SizedBox(width: 5),
                _floatIconChip(
                  icon: Icons.copy_all,
                  onTap: _copyDebugChat,
                  iconFg: iconFg,
                  tooltip: 'Copy full chat',
                  semanticsId: 'copy_debug_chat_button',
                ),
                const SizedBox(width: 5),
                // Accent-filled circle, not a frosted chip: the new-chat button
                // is the primary action and matches the identical button in the
                // sidebar (AccentIconButton) so the two read as the same control.
                AccentIconButton(
                  icon: Icons.edit_square,
                  onTap: _newChatFromAppBar,
                  tooltip: 'New Chat',
                  semanticsId: 'new_chat_button',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One round chip of the floating top bar: the app's header chip
  /// ([FloatingHeaderButton]), so the chat and the settings pages share it.
  Widget _floatIconChip({
    required IconData icon,
    required VoidCallback onTap,
    required Color iconFg,
    required String tooltip,
    required String semanticsId,
  }) {
    return FloatingHeaderButton(
      icon: icon,
      onPressed: onTap,
      color: iconFg,
      tooltip: tooltip,
      semanticsId: semanticsId,
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
      AppNotifications.show(context, 'No messages to copy');
      return;
    }
    final text = DebugChatFormatter.format(
      messages,
      context: chatDebugContext(state, platform: 'mobile'),
    );
    Clipboard.setData(ClipboardData(text: text));
    AppNotifications.show(
      context,
      'Copied ${messages.length} messages (debug, images redacted)',
      duration: Duration(seconds: 2),
    );
  }

  // ---------- Swipe mode ([RootWrapperMobile.swipeNavigation]) ----------

  /// The id of the "New chat" page, the leftmost entry of the pager. It is
  /// selected while no chat is open.
  static const String _kNewChatEntryId = '__new__';

  /// The pages of the pager, left to right: "New chat", then the chats the
  /// sidebar lists, newest first.
  ///
  /// The source is the sidebar's: [ChatStorageService.savedChats], which
  /// already leaves out Agents threads and sorts by last activity, and
  /// [ChatStorageService.changes] (see [_startSwipeNavigation]) for every
  /// create, rename, delete and reorder. Titles go through the sidebar's
  /// [deriveSidebarChatTitle]. Two differences: pinned chats are not pulled
  /// to the front (a swipe follows time, not pins), and locked chats are left
  /// out, because the sidebar does not open them either.
  List<SwipeChatEntry> _swipeEntries(BuildContext context) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final StreamingManager streaming = StreamingManager();
    return <SwipeChatEntry>[
      SwipeChatEntry(
        id: _kNewChatEntryId,
        title: l?.newChat ?? 'New chat',
        leading: const _NewChatFace(),
      ),
      for (final StoredChat chat in ChatStorageService.savedChats)
        if (!chat.isLocked)
          SwipeChatEntry(
            id: chat.id,
            title: deriveSidebarChatTitle(chat),
            subtitle: sbChatDateLine(context, chat.updatedAt ?? chat.createdAt),
            working: streaming.isStreaming(chat.id),
          ),
    ];
  }

  /// The pager committed a switch: open that chat, or a new one.
  void _onSwipeSelected(String id) {
    if (id == _kNewChatEntryId) {
      // newChat() hands null to onChatIdChanged, which selects it.
      _newChatFromAppBar(keepKeyboard: true);
      setState(() {});
      return;
    }
    _handleChatSelected(id, keepKeyboard: true);
  }

  /// The menu chip: the pages the sidebar used to hold.
  void _openSwipeMenu() {
    FocusManager.instance.primaryFocus?.unfocus();
    final AppLocalizations? l = AppLocalizations.of(context);
    final VoidCallback? onAddComputer = widget.onAddComputer;
    final String? current = _selectedChatId;
    unawaited(
      showMobileMenuSheet(
        context,
        shortcuts: <MobileMenuItem>[
          MobileMenuItem(
            icon: Icons.settings,
            label: l?.settings ?? 'Settings',
            onTap: _openSettingsPage,
          ),
          if (kFeatureMediaManager)
            MobileMenuItem(
              icon: Icons.image_rounded,
              label: l?.media ?? 'Media',
              onTap: _openMediaPage,
            ),
          if (kFeatureWorkspaces)
            MobileMenuItem(
              icon: Icons.folder_rounded,
              label: l?.workspaces ?? 'Workspaces',
              onTap: _openWorkspacesPage,
            ),
          if (onAddComputer != null)
            MobileMenuItem(
              icon: Icons.computer,
              label: kSidebarAddComputerLabel,
              onTap: onAddComputer,
            ),
        ],
        // The chat in view; there is no list to do it from any more.
        sectionTitle: current == null ? null : _titleOfChat(current),
        items: <MobileMenuItem>[
          if (current != null)
            MobileMenuItem(
              icon: Icons.edit_outlined,
              label: l?.chatSwipeRename ?? 'Rename',
              onTap: () => unawaited(_renameCurrentChat(current)),
            ),
          MobileMenuItem(
            icon: Icons.copy_all,
            label: l?.chatSwipeCopyChat ?? 'Copy full chat',
            onTap: _copyDebugChat,
          ),
          if (current != null)
            MobileMenuItem(
              icon: Icons.delete_outline_rounded,
              label: l?.delete ?? 'Delete',
              destructive: true,
              onTap: () => unawaited(_deleteCurrentChat(current)),
            ),
        ],
      ),
    );
  }

  /// The title the strip shows for [chatId], for the menu's section header.
  String? _titleOfChat(String chatId) {
    final StoredChat? chat = ChatStorageService.getChatById(chatId);
    return chat == null ? null : deriveSidebarChatTitle(chat);
  }

  /// The sidebar's delete path ([SidebarStateCommon]): the same question,
  /// the same store call, then the same reset of the chat in view.
  Future<void> _deleteCurrentChat(String chatId) async {
    final StoredChat? chat = ChatStorageService.getChatById(chatId);
    if (chat == null) return;
    final String derivedTitle = deriveSidebarChatTitle(chat);
    final String chatTitle = derivedTitle.length > 40
        ? '${derivedTitle.substring(0, 40)}...'
        : derivedTitle;
    final bool? shouldDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          '"$chatTitle"\n\nThis will be removed forever. Once deleted, it '
          'cannot be recovered.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !mounted) return;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    try {
      await ChatStorageService.deleteChat(chatId);
    } on StateError catch (error) {
      if (messenger != null) AppNotifications.showOn(messenger, error.message);
      return;
    } catch (error) {
      if (messenger != null) {
        AppNotifications.showOn(
          messenger,
          'Failed to delete chat: $error',
          kind: AppNotificationKind.error,
        );
      }
      return;
    }
    if (!mounted) return;
    await _handleChatDeleted(chatId);
    if (!mounted || messenger == null) return;
    final String shown = chatTitle.length > 30
        ? '${chatTitle.substring(0, 30)}...'
        : chatTitle;
    AppNotifications.showOn(messenger, '"$shown" deleted');
  }

  /// The sidebar's rename path ([SidebarStateCommon]).
  Future<void> _renameCurrentChat(String chatId) async {
    final StoredChat? chat = ChatStorageService.getChatById(chatId);
    if (chat == null) return;
    final String oldName = deriveSidebarChatTitle(chat);
    // The dialog owns its text controller: it is still built during the
    // route's exit animation, after showDialog has returned.
    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _RenameChatDialog(initial: oldName),
    );
    if (newName == null || newName.isEmpty || newName == oldName) return;
    if (!mounted) return;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    try {
      await ChatStorageService.renameChat(chatId, newName);
    } on StateError catch (error) {
      if (messenger != null) AppNotifications.showOn(messenger, error.message);
      return;
    } catch (error) {
      if (messenger != null) {
        AppNotifications.showOn(
          messenger,
          'Failed to rename chat: $error',
          kind: AppNotificationKind.error,
        );
      }
      return;
    }
    if (mounted) setState(() {});
  }

  /// Swipe mode's screen: the one chat view inside the pager, and the top
  /// bar with the strip lying over it.
  Widget _buildSwipeLayout(BuildContext context) {
    final AppLocalizations? l = AppLocalizations.of(context);
    // viewPaddingOf: see the plain build below.
    final double topInset =
        MediaQuery.viewPaddingOf(context).top + kMobileTopBarHeight;
    final List<SwipeChatEntry> entries = _swipeEntries(context);
    final String selectedId = _selectedChatId ?? _kNewChatEntryId;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: SwipeChatPager(
              entries: entries,
              selectedId: selectedId,
              controller: _swipeController,
              onSelected: _onSwipeSelected,
              // Only the name in the strip moves (owner, 2026-11-05).
              moveChild: false,
              child: _buildChatView(
                topInset: topInset,
                onToggleSidebar: _openSwipeMenu,
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MobileTopBar(
              onMenu: _openSwipeMenu,
              centre: widget.headerCenter,
              onAdd: _newChatFromAppBar,
              menuTooltip: l?.chatSwipeMenu ?? 'Menu',
              addTooltip: l?.newChat ?? 'New chat',
              strip: ChatTitleStrip(
                entries: entries,
                selectedId: selectedId,
                controller: _swipeController,
                semanticsHint: l?.chatSwipeStripHint ?? 'Swipe to switch chats',
                workingLabel: l?.chatSwipeWorking ?? 'working',
                // A chat that is not in the list yet (saved a moment ago).
                emptyTitle: _currentChatTitle() ?? (l?.newChat ?? 'New chat'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The one chat view. Both layouts build it through here, with the same
  /// key, so it is the same widget whichever layout holds it.
  Widget _buildChatView({
    required double topInset,
    required VoidCallback onToggleSidebar,
  }) {
    return ChukChatUIMobile(
      key: _chatUIMobileKey,
      topInset: topInset,
      onToggleSidebar: onToggleSidebar,
      selectedChatId: _selectedChatId,
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
      showReasoningTokens: widget.config.showReasoningTokens,
      showModelInfo: widget.config.showModelInfo,
      showTps: widget.config.showTps,
      autoSendVoiceTranscription: widget.config.autoSendVoiceTranscription,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.swipeNavigation) return _buildSwipeLayout(context);

    // sizeOf, not of(): this sits above the Scaffold, so `of` would see the
    // raw animating viewInsets and rebuild the app bar, the chat screen and
    // the whole sidebar on every keyboard frame.
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    // Mobile sidebar fills the entire screen — a full-page panel instead
    // of a partial drawer. Desktop is unaffected (sidebar_desktop.dart is
    // hosted by root_wrapper_desktop.dart in its own layout).
    final double sidebarVisibleWidth = screenWidth;

    // The floating top bar overlays the chat so the conversation shows
    // through its translucent chips. That means the chat has to reserve
    // this much space at the top, or its first row starts hidden behind the
    // bar. Height = safe-area inset + the bar's own padded content
    // (8 + 48 + 6 == 62, see _buildFloatingTopBar).
    //
    // viewPaddingOf, not paddingOf: `padding.bottom` falls to 0 while the
    // keyboard rises, and that would rebuild this whole screen, the sidebar
    // included, on the first frames of every keyboard animation.
    final double topBarInset = MediaQuery.viewPaddingOf(context).top + 62;

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
        // Overlay, not a column: the top bar floats on top of the chat so
        // the conversation scrolls under its translucent chips and shows
        // through. The chat reserves `topBarInset` at the top so nothing
        // starts hidden behind the bar.
        child: Stack(
          children: [
            Positioned.fill(
              child: _buildChatView(
                topInset: topBarInset,
                onToggleSidebar: _toggleSidebar,
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildFloatingTopBar(iconFg),
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
        // The drawer had no visible close control, only the swipe.
        onCollapseTapped: _toggleSidebar,
        // The page opens over the chat, so the drawer closes first.
        onAddComputerTapped: widget.onAddComputer == null
            ? null
            : () {
                if (_isSidebarExpanded) _toggleSidebar();
                widget.onAddComputer!();
              },
        selectedChatId: _selectedChatId,
        isCompactMode: true,
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

/// The face of the "New chat" page in the title strip: the new-chat glyph in
/// a 32 px circle.
class _NewChatFace extends StatelessWidget {
  const _NewChatFace();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: HugeIcon(
        HugeIcons.pencilEdit02,
        size: 18,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}

/// The rename question of the swipe menu. It owns its controller, so the
/// field outlives the `showDialog` future through the exit animation.
class _RenameChatDialog extends StatefulWidget {
  const _RenameChatDialog({required this.initial});

  final String initial;

  @override
  State<_RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<_RenameChatDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename chat'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Chat name',
          hintText: 'Enter new name',
        ),
        onSubmitted: (String value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
