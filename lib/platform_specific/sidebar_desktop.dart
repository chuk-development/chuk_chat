// lib/platform_specific/sidebar_desktop.dart
//
// The desktop sidebar reads as a stack of blocks in the app's settings
// language: an account card, a navigation block, then one block of chats per
// time group under its own quiet header, and a bar at the foot carrying the
// search field and the two round actions. Everything above the foot scrolls
// as one column, so a short window spends its height on chats rather than on
// fixed chrome.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions
import 'package:chuk_chat/services/update_check_service.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/update_banner.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';

class SidebarDesktop extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onWorkspacesTapped;
  final Function() onMediaTapped;
  final Function() onNewChatTapped;
  final Future<void> Function(String chatId)? onChatDeleted;

  /// Folds the sidebar back to the mini rail. Null hides the profile card's
  /// collapse button, for a host that has no such state.
  final VoidCallback? onCollapseTapped;
  final String? selectedChatId;
  final bool isCompactMode;
  final bool showWorkspacesButton;

  const SidebarDesktop({
    super.key,
    required this.onChatSelected,
    required this.onSettingsTapped,
    required this.onWorkspacesTapped,
    required this.onMediaTapped,
    required this.onNewChatTapped,
    this.onChatDeleted,
    this.onCollapseTapped,
    required this.selectedChatId,
    required this.isCompactMode,
    required this.showWorkspacesButton,
  });

  @override
  State<SidebarDesktop> createState() => _SidebarDesktopState();
}

class _SidebarDesktopState extends State<SidebarDesktop> {
  static const int _kPageSize = 40;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<StoredChat> _filteredRecentChats = [];
  int _displayLimit = _kPageSize;
  final ScrollController _scrollController = ScrollController();

  /// Headers the user has folded shut, by label. Kept per label rather than
  /// per index so a group keeps its state while chats move between buckets.
  final Set<String> _collapsedGroups = <String>{};
  ProfileRecord? _profile;
  StreamSubscription<String?>? _chatUpdatesSub;
  Timer? _deleteNotificationTimer;
  String? _lastDeletedChatTitle;
  bool _isOfflineMode = false;
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _filterRecentChats(); // Filter cached chats immediately for instant UI
    // Chat loading handled by main.dart - we only listen to changes stream
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScrollForAutoLoad);
    unawaited(_loadProfile()); // Don't block on profile load
    _chatUpdatesSub = ChatStorageService.changes.listen((changedChatId) {
      if (!mounted) return;
      if (changedChatId == null) {
        // Bulk change (initial load, sync) - refilter everything
        setState(() {
          _filterRecentChats();
        });
      } else {
        // Single chat changed - just trigger rebuild without refiltering
        // The chat data is already updated in ChatStorageService
        setState(() {});
      }
    });
    // Monitor network status for offline indicators
    NetworkStatusService.isOnlineListenable.addListener(
      _onNetworkStatusChanged,
    );
    // Check for app updates in background
    unawaited(UpdateCheckService.checkForUpdate());
  }

  @override
  void dispose() {
    _chatUpdatesSub?.cancel();
    _deleteNotificationTimer?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      _onNetworkStatusChanged,
    );
    _searchController.removeListener(_onSearchChanged);
    _scrollController.removeListener(_onScrollForAutoLoad);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // Auto-load older chats when the user scrolls within 240 px of the
  // bottom — no "Show more" button needed; the next page slides in
  // while they're still flicking.
  void _onScrollForAutoLoad() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      final int restLen =
          _filteredRecentChats.where((c) => !c.isStarred).length;
      if (restLen > _displayLimit) {
        setState(() {
          _displayLimit += _kPageSize;
        });
      }
    }
  }

  // The Search nav card doesn't open a second field — it hands the caret to
  // the one already sitting in the bottom bar.
  void _focusSearch() {
    _searchFocus.requestFocus();
  }

  void _toggleGroup(String label) {
    setState(() {
      if (!_collapsedGroups.remove(label)) _collapsedGroups.add(label);
    });
    // Folding a group can leave the content shorter than the viewport, and
    // the scroll listener only fires near the bottom — so without a nudge
    // here the list would sit there with pages left unloaded and no gesture
    // able to ask for them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScrollForAutoLoad();
    });
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
      _displayLimit = _kPageSize;
      _filterRecentChats();
    });
  }

  void _onNetworkStatusChanged() {
    if (!mounted) return;
    setState(() {
      // Update offline status when network changes
      _isOfflineMode = !NetworkStatusService.isOnline;
    });
  }

  void _clearSearchQuery() {
    _searchController.clear();
  }

  // Refreshes chats from network via ChatSyncService and re-filters.
  // Uses syncNow() instead of loadSavedChatsForSidebar() to avoid
  // redundant local-cache reloads — the sync service fetches from the
  // server and updates local state, which triggers the changes stream.
  Future<void> _loadChatsAndRefresh() async {
    await ChatSyncService.syncNow();
    if (mounted) {
      setState(() {
        _filterRecentChats();
        _isOfflineMode = !NetworkStatusService.isOnline;
      });
    }
  }

  // Filters ChatStorageService.savedChats based on _searchQuery
  void _filterRecentChats() {
    if (_searchQuery.isEmpty) {
      _filteredRecentChats = List<StoredChat>.from(
        ChatStorageService.savedChats,
      ); // Use List.from to create a mutable copy
    } else {
      final lowerQuery = _searchQuery.toLowerCase();
      _filteredRecentChats = ChatStorageService.savedChats.where((chat) {
        final titleMatches = _deriveChatTitle(
          chat,
        ).toLowerCase().contains(lowerQuery);
        if (titleMatches) return true;
        return (chat.messagesOrNull ?? const []).any(
          (message) => message.text.toLowerCase().contains(lowerQuery),
        );
      }).toList();
    }
  }

  @override
  void didUpdateWidget(covariant SidebarDesktop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatId != oldWidget.selectedChatId) {
      if (mounted) setState(() {});
    }
    // Check if the underlying saved chats list has changed (e.g., new chat added)
    // and refresh the filtered list if search query is empty (showing all).
    // If _searchQuery is not empty, _onSearchChanged will handle re-filtering.
    if (ChatStorageService.savedChats.length != _filteredRecentChats.length &&
        _searchQuery.isEmpty) {
      _filterRecentChats();
    }
  }

  Future<void> _loadProfile() async {
    // Reading `auth` before Supabase is initialised throws, which is exactly
    // what happens in a widget test that only wants to see the layout.
    if (!SupabaseService.isInitialized) return;
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    try {
      final record = await const ProfileService().loadOrCreateProfile();
      if (!mounted) return;
      setState(() {
        _profile = record;
      });
    } catch (_) {
      // Silently ignore profile load errors; sidebar will show fallback label.
    }
  }

  String _displayNameFor(ProfileRecord? profile) {
    if (profile == null) return 'Account';
    if (profile.displayName.trim().isNotEmpty) {
      return profile.displayName.trim();
    }
    if (profile.email.trim().isNotEmpty) {
      return profile.email.trim();
    }
    return 'Account';
  }

  String _deriveChatTitle(StoredChat chat) {
    // Priority: customName > title (from encrypted_title) > previewText
    // customName: User-renamed or AI-generated title stored in payload
    // title: Fast-loaded decrypted title for sidebar
    // previewText: Fallback derived from first user message
    final rawTitle = chat.customName ?? chat.title ?? chat.previewText;
    final normalized = _normalizeTitleForDisplay(rawTitle);
    return normalized.isEmpty ? 'New chat' : normalized;
  }

  String _normalizeTitleForDisplay(String title) {
    var normalized = title.trim();
    normalized = normalized.replaceFirst(
      RegExp(r'^\s*title\s*:\s*', caseSensitive: false),
      '',
    );
    normalized = normalized.replaceFirst(RegExp(r'^\s*#+\s*'), '');

    final wrappers = <RegExp>[
      RegExp(r'^\*\*(.+)\*\*$', dotAll: true),
      RegExp(r'^__(.+)__$', dotAll: true),
      RegExp(r'^\*(.+)\*$', dotAll: true),
      RegExp(r'^_(.+)_$', dotAll: true),
      RegExp(r'^`(.+)`$', dotAll: true),
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final pattern in wrappers) {
        final match = pattern.firstMatch(normalized);
        if (match == null) continue;
        final inner = match.group(1)?.trim() ?? '';
        if (inner.isEmpty) continue;
        normalized = inner;
        changed = true;
      }
    }

    return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _toggleStarred(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChatStorageService.setChatStarred(chat.id, !chat.isStarred);
      if (!mounted) return;
      setState(() {
        _filterRecentChats();
      });
    } on StateError catch (error) {
      NiceSnackBar.showOn(messenger, error.message);
    } catch (error) {
      NiceSnackBar.showOn(messenger, 'Failed to update star: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03);

    // Hamburger stays anchored to the top-left always — brand text starts
    // just to the right of it so the two share the same baseline.
    final double brandLeftPadding = kFixedLeftPadding + kMenuButtonHeight + 4;

    return Container(
      color: sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top spacer matches the hamburger's `top` offset.
          SizedBox(height: kTopInitialSpacing),

          // Brand row is exactly kMenuButtonHeight tall and vertically centred
          // — that puts "Chuk Chat" on the same baseline as the hamburger.
          SizedBox(
            height: kMenuButtonHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(brandLeftPadding, 0, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: BrandWordmark(color: iconFg),
              ),
            ),
          ),

          Expanded(
            child: CustomScrollView(
              controller: _scrollController,
              slivers: _buildSlivers(iconFg, accent),
            ),
          ),

          const UpdateBanner(),

          KeyedSubtree(
            key: TourKeyRegistry.instance.keyFor(TourSlots.settingsEntry),
            child: SbBottomBar(
              search: SbSearchField(
                controller: _searchController,
                focusNode: _searchFocus,
                onClear: _clearSearchQuery,
              ),
              onSettings: widget.onSettingsTapped,
              onNewChat: widget.onNewChatTapped,
            ),
          ),
        ],
      ),
    );
  }

  // The whole scrolling column, top to bottom: account, navigation, the
  // offline notice, then one header + block per time group.
  List<Widget> _buildSlivers(Color iconFg, Color accent) {
    final List<StoredChat> pinnedChats =
        _filteredRecentChats.where((c) => c.isStarred).toList();
    final List<StoredChat> restChats =
        _filteredRecentChats.where((c) => !c.isStarred).toList();

    final List<Widget> slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 6)),
      SliverToBoxAdapter(
        child: SbBlock(
          children: [
            SbProfileCard(
              name: _displayNameFor(_profile),
              onTap: widget.onSettingsTapped,
              onCollapse: widget.onCollapseTapped,
              subtitle: BalanceBadge(
                textStyle: TextStyle(
                  color: accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                placeholderStyle: TextStyle(
                  color: Theme.of(context).m3.onSurfaceVariant,
                  fontSize: 13,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 10)),
      SliverToBoxAdapter(child: SbBlock(children: _buildNavCards())),
      if (_isOfflineMode)
        SliverToBoxAdapter(
          child: SbOfflineNotice(
            label: 'Offline - showing cached chats',
            onRetry: () async {
              final isOnline = await NetworkStatusService.quickCheck();
              if (isOnline && mounted) {
                await _loadChatsAndRefresh();
              }
            },
          ),
        ),
    ];

    if (pinnedChats.isEmpty && restChats.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              _searchQuery.isEmpty
                  ? 'No recent chats yet.'
                  : 'No chats found for "$_searchQuery".',
              style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
            ),
          ),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
      return slivers;
    }

    if (pinnedChats.isNotEmpty) {
      slivers.addAll(_buildGroup(
        AppLocalizations.of(context)?.pinned ?? 'Pinned',
        pinnedChats,
        accent,
        iconFg,
      ));
    }

    // Grouping runs on the whole unpinned list so a header's number is the
    // size of the real bucket. Pagination then walks the groups in order and
    // stops once the page budget is spent — a count that only described the
    // loaded page would read as a total and grow as the user scrolled.
    final MaterialLocalizations localizations =
        MaterialLocalizations.of(context);
    // The month buckets follow the locale through formatMonthYear; the three
    // named buckets have to be handed in, or they sit in English next to them.
    final AppLocalizations? l = AppLocalizations.of(context);
    final List<SbChatGroup<StoredChat>> groups = sbGroupByTime<StoredChat>(
      restChats,
      (chat) => chat.updatedAt ?? chat.createdAt,
      monthLabel: localizations.formatMonthYear,
      todayLabel: l?.today ?? 'Today',
      weekLabel: l?.thisWeek ?? 'This week',
      thisMonthLabel: l?.thisMonth ?? 'This month',
    );
    int budget = _displayLimit;
    for (final group in groups) {
      if (budget <= 0) break;
      final int shown = math.min(budget, group.items.length);
      budget -= shown;
      slivers.addAll(
        _buildGroup(
          group.label,
          group.items.take(shown).toList(),
          accent,
          iconFg,
          total: group.items.length,
        ),
      );
    }

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
    return slivers;
  }

  List<Widget> _buildNavCards() {
    // Null-safe like every other lookup here: a host that builds the sidebar
    // without the delegate should get English labels, not a crashed nav block.
    final AppLocalizations? l = AppLocalizations.of(context);
    return <Widget>[
      if (kFeatureWorkspaces && widget.showWorkspacesButton)
        SbNavCard(
          icon: Icons.folder_rounded,
          label: l?.workspaces ?? 'Workspaces',
          onTap: widget.onWorkspacesTapped,
        ),
      if (kFeatureMediaManager)
        SbNavCard(
          icon: Icons.image_rounded,
          label: l?.media ?? 'Media',
          onTap: widget.onMediaTapped,
        ),
      SbNavCard(
        icon: Icons.search_rounded,
        label: l?.search ?? 'Search',
        onTap: _focusSearch,
      ),
    ];
  }

  // A header and the chats under it. The chats stay in a SliverList rather
  // than a single box so a long group is still built lazily.
  List<Widget> _buildGroup(
    String label,
    List<StoredChat> chats,
    Color accent,
    Color iconFg, {
    /// The size of the whole bucket, which is larger than [chats] once
    /// pagination has cut the group short. Null means the two are the same.
    int? total,
  }) {
    final bool collapsed = _collapsedGroups.contains(label);
    return <Widget>[
      SliverToBoxAdapter(
        child: SbGroupHeader(
          label: label,
          count: total ?? chats.length,
          collapsed: collapsed,
          onToggle: () => _toggleGroup(label),
        ),
      ),
      if (!collapsed)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => Padding(
              // The gap belongs between the cards, so the last one in a
              // group carries none and the header below it sets the spacing.
              padding: EdgeInsets.fromLTRB(
                kSbBlockInset,
                0,
                kSbBlockInset,
                i == chats.length - 1 ? 0 : kSbCardGap,
              ),
              child: _buildRecentItem(
                chats[i],
                onTap: () => _onChatTapped(chats[i]),
                onDelete: () => _confirmAndDeleteChat(chats[i]),
                accentColor: accent,
                iconFgColor: iconFg,
              ),
            ),
            childCount: chats.length,
          ),
        ),
    ];
  }

  void _onChatTapped(StoredChat storedChat) {
    if (ChatStorageService.isLoadingChat) {
      if (kDebugMode) {
        debugPrint(
          '🚫 [SIDEBAR-DESKTOP] BLOCKED - Chat is still loading',
        );
      }
      return;
    }
    if (kDebugMode) {
      debugPrint('👆 [SIDEBAR-DESKTOP] User tapped recent chat ${storedChat.id}');
    }
    widget.onChatSelected(storedChat.id);
  }

  Widget _buildRecentItem(
    StoredChat chat, {
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconFgColor,
  }) {
    final bool isSelected = chat.id == widget.selectedChatId;
    final bool isStreaming = StreamingManager().isStreaming(chat.id);
    final String title = chat.isLocked
        ? 'Locked encrypted chat'
        : _deriveChatTitle(chat);
    final bool isLocked = chat.isLocked;
    final bool isPinned = chat.isStarred;
    return SbChatTile(
      title: title,
      dateLine: sbChatDateLine(context, chat.updatedAt ?? chat.createdAt),
      selected: isSelected,
      locked: isLocked,
      streaming: isStreaming,
      onTap: isLocked
          ? () => _showLockedChatDialog(
                context,
                iconFgColor: iconFgColor,
                accentColor: accentColor,
              )
          : onTap,
      onSecondaryTap: isLocked
          ? null
          : (pos) => _showChatContextMenu(
                context,
                pos,
                chat,
                accentColor: accentColor,
                iconFgColor: iconFgColor,
                onDelete: onDelete,
              ),
      // Pin stays a one-click toggle on hover; the same action is in the
      // menu for anyone who never hovers.
      hoverTrailing: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          icon: Icon(
            isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            size: 16,
            color: isPinned
                ? accentColor
                : iconFgColor.withValues(alpha: 0.75),
          ),
          padding: EdgeInsets.zero,
          splashRadius: 16,
          visualDensity: VisualDensity.compact,
          tooltip: isPinned ? 'Unpin chat' : 'Pin chat',
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          onPressed: () => _toggleStarred(chat),
        ),
      ),
      trailing: Builder(builder: (btnContext) {
        return SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            icon: Icon(
              Icons.more_horiz_rounded,
              size: 18,
              color: iconFgColor.withValues(alpha: 0.75),
            ),
            padding: EdgeInsets.zero,
            splashRadius: 16,
            visualDensity: VisualDensity.compact,
            tooltip: 'Chat options',
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: () => _openChatActionsMenu(
              btnContext,
              chat,
              accentColor: accentColor,
              iconFgColor: iconFgColor,
              onDelete: onDelete,
            ),
          ),
        );
      }),
    );
  }

  // Opens the rename/pin/delete menu anchored to the three-dot button.
  // Uses the button's render box so the menu lands right beside the icon,
  // not at some far-off origin where it would be clipped or invisible.
  void _openChatActionsMenu(
    BuildContext btnContext,
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
    VoidCallback? onDelete,
  }) {
    final overlayState = Overlay.of(btnContext);
    final box = btnContext.findRenderObject() as RenderBox?;
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;
    final Offset topLeft =
        box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final Offset bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlayBox,
    );
    showMenu<String>(
      context: btnContext,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        bottomRight.dy,
        overlayBox.size.width - bottomRight.dx,
        overlayBox.size.height - bottomRight.dy,
      ),
      items: _buildMenuItems(
        chat,
        accentColor: accentColor,
        iconFgColor: iconFgColor,
      ),
    ).then((value) {
      if (value != null) {
        _handleMenuSelection(value, chat, onDelete);
      }
    });
  }

  // Handle menu item selection
  void _handleMenuSelection(
    String value,
    StoredChat chat,
    VoidCallback? onDelete,
  ) {
    switch (value) {
      case 'pin':
        unawaited(_toggleStarred(chat));
        break;
      case 'edit':
        _renameChatDialog(chat);
        break;
      case 'delete':
        if (onDelete != null) onDelete();
        break;
    }
  }

  // Build menu items for both the three-dot button and the right-click menu.
  List<PopupMenuEntry<String>> _buildMenuItems(
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
  }) {
    final bool isPinned = chat.isStarred;
    return [
      PopupMenuItem(
        value: 'pin',
        child: Row(
          children: [
            Icon(
              isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              color: isPinned ? accentColor : iconFgColor,
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(isPinned ? 'Unpin' : 'Pin'),
          ],
        ),
      ),
      PopupMenuItem(
        value: 'edit',
        child: Row(
          children: [
            Icon(Icons.edit_outlined, color: iconFgColor, size: 20),
            const SizedBox(width: 12),
            const Text('Rename'),
          ],
        ),
      ),
      PopupMenuItem(
        value: 'delete',
        child: Row(
          children: [
            Icon(
              Icons.delete_outline,
              color: Colors.redAccent.withValues(alpha: 0.8),
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    ];
  }

  void _showLockedChatDialog(
    BuildContext context, {
    required Color iconFgColor,
    required Color accentColor,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.lock, color: accentColor, size: 20),
            const SizedBox(width: 8),
            const Text('Locked Chat'),
          ],
        ),
        content: const Text(
          'This chat is encrypted with a previous password and can\'t be '
          'opened with your current one. Go to Account Settings → Chat '
          'Recovery and enter your old password to unlock it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // Show context menu on right-click
  void _showChatContextMenu(
    BuildContext context,
    Offset position,
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
    VoidCallback? onDelete,
  }) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: _buildMenuItems(
        chat,
        accentColor: accentColor,
        iconFgColor: iconFgColor,
      ),
    ).then((value) {
      if (value != null) {
        _handleMenuSelection(value, chat, onDelete);
      }
    });
  }

  Future<void> _renameChatDialog(StoredChat chat) async {
    final controller = TextEditingController(text: _deriveChatTitle(chat));
    final messenger = ScaffoldMessenger.of(context);

    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Chat name',
              hintText: 'Enter new name',
            ),
            onSubmitted: (value) {
              Navigator.of(dialogContext).pop(value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (newName == null ||
        newName.isEmpty ||
        newName == _deriveChatTitle(chat)) {
      return;
    }

    try {
      await ChatStorageService.renameChat(chat.id, newName);
      if (!mounted) return;
      setState(() {
        _filterRecentChats();
      });
    } on StateError catch (error) {
      NiceSnackBar.showOn(messenger, error.message);
    } catch (error) {
      NiceSnackBar.showOn(messenger, 'Failed to rename chat: $error');
    }
  }

  void _showDebouncedDeleteNotification(String chatTitle) {
    _lastDeletedChatTitle = chatTitle;
    _deleteNotificationTimer?.cancel();
    _deleteNotificationTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final title = _lastDeletedChatTitle;
      _lastDeletedChatTitle = null;

      final messenger = ScaffoldMessenger.of(context);
      final displayTitle = title != null && title.length > 30
          ? '${title.substring(0, 30)}...'
          : title;
      NiceSnackBar.showOn(messenger, '"$displayTitle" deleted');
    });
  }

  Future<void> _confirmAndDeleteChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    // Get chat title for display
    final chatTitle =
        chat.customName ??
        (chat.previewText.length > 40
            ? '${chat.previewText.substring(0, 40)}...'
            : chat.previewText);

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            '"$chatTitle"\n\nThis will be removed forever. Once deleted, it cannot be recovered.',
          ),
          actions: [
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
        );
      },
    );

    if (shouldDelete != true) return;

    try {
      await ChatStorageService.deleteChat(chat.id);
      // No need to reload — deleteChat() updates local state and fires notifyChanges().
      // The changes stream listener in initState handles the UI rebuild.
      if (!mounted) return;
      if (widget.onChatDeleted != null) {
        await widget.onChatDeleted!(chat.id);
      }
      _showDebouncedDeleteNotification(chatTitle);
    } on StateError catch (error) {
      NiceSnackBar.showOn(messenger, error.message);
    } catch (error) {
      NiceSnackBar.showOn(messenger, 'Failed to delete chat: $error');
    }
  }
}
