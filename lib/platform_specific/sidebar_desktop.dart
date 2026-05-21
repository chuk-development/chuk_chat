// lib/platform_specific/sidebar_desktop.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
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
import 'package:chuk_chat/platform_config.dart';
import 'package:flutter/foundation.dart';

class SidebarDesktop extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onWorkspacesTapped;
  final Function() onMediaTapped;
  final Function() onNewChatTapped;
  final Future<void> Function(String chatId)? onChatDeleted;
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
    required this.selectedChatId,
    required this.isCompactMode,
    required this.showWorkspacesButton,
  });

  @override
  State<SidebarDesktop> createState() => _SidebarDesktopState();
}

class _SidebarDesktopState extends State<SidebarDesktop> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;

  static const int _kPageSize = 40;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<StoredChat> _filteredRecentChats = [];
  int _displayLimit = _kPageSize;
  final ScrollController _scrollController = ScrollController();
  // Manual "replace-style" sticky section header. Flutter's
  // SliverPersistentHeader(pinned: true) stacks pinned headers on top of
  // each other; we want exactly one header label visible at the top,
  // swapping as the user scrolls past each bucket. We track the
  // accumulated content offset of each bucket and pick the appropriate
  // label in the scroll listener.
  String _currentBucket = '';
  final List<_BucketBound> _sectionMarkers = [];
  static const double _kEstimatedRowHeight = 32.0;
  static const double _kStickyHeaderHeight = 32.0;
  ProfileRecord? _profile;
  StreamSubscription<String?>? _chatUpdatesSub;
  Timer? _deleteNotificationTimer;
  String? _lastDeletedChatTitle;
  bool _isOfflineMode = false;
  bool _searchVisible = false;
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _filterRecentChats(); // Filter cached chats immediately for instant UI
    // Chat loading handled by main.dart - we only listen to changes stream
    _searchController.addListener(_onSearchChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
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
    _searchFocus.removeListener(_onSearchFocusChanged);
    _scrollController.removeListener(_onScrollForAutoLoad);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // Auto-load older chats when the user scrolls within 240 px of the
  // bottom — no "Show more" button needed; the next page slides in
  // while they're still flicking. Also keeps the sticky overlay header
  // in sync with the topmost-visible bucket.
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
    _refreshCurrentBucket();
  }

  // Picks the bucket label that should be sticky at the top right now,
  // based on the scroll position and the section markers built in
  // `_buildScrollableSlivers`. Calls setState only when the label
  // actually changes to avoid extra rebuilds.
  void _refreshCurrentBucket() {
    if (_sectionMarkers.isEmpty) {
      if (_currentBucket.isNotEmpty) {
        setState(() => _currentBucket = '');
      }
      return;
    }
    final double offset =
        _scrollController.hasClients ? _scrollController.position.pixels : 0.0;
    String found = _sectionMarkers.first.label;
    for (final m in _sectionMarkers) {
      if (offset >= m.startOffset) {
        found = m.label;
      } else {
        break;
      }
    }
    if (found != _currentBucket) {
      setState(() => _currentBucket = found);
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
    });
    if (_searchVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchFocus.requestFocus();
      });
    } else {
      _searchController.clear();
    }
  }

  // Collapse the morphing search field back to the plain "Search" nav row
  // when the user clicks away and there is nothing to keep open. Anything
  // in the query is preserved — the row stays expanded so the filter view
  // sticks around until the user explicitly clears it.
  void _onSearchFocusChanged() {
    if (!mounted) return;
    if (_searchFocus.hasFocus) return;
    if (_searchQuery.isNotEmpty) return;
    if (!_searchVisible) return;
    setState(() => _searchVisible = false);
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to update star: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03);

    // Pinned chats live in their own bento card; rest go in a flat list.
    final List<StoredChat> pinnedChats =
        _filteredRecentChats.where((c) => c.isStarred).toList();
    final List<StoredChat> restChats =
        _filteredRecentChats.where((c) => !c.isStarred).toList();

    // Hamburger stays anchored to the top-left always — brand text starts
    // just to the right of it so the two share the same baseline.
    final double brandLeftPadding =
        kFixedLeftPadding + kMenuButtonHeight + 4;

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
                child: Text(
                  'Chuk Chat',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: iconFg,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
            ),
          ),

          // All four rail rows share a uniform pill width = the widest
          // label's intrinsic width. IntrinsicWidth measures the longest
          // child Row, then Column(stretch) forces every row to that width
          // so the hover pills look consistent rather than ragged.
          Align(
            alignment: Alignment.centerLeft,
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SbRailRow(
                    icon: Icons.edit_square,
                    label: 'New chat',
                    onTap: widget.onNewChatTapped,
                  ),
                  if (kFeatureWorkspaces && widget.showWorkspacesButton)
                    SbRailRow(
                      icon: Icons.folder_rounded,
                      label: 'Workspaces',
                      onTap: widget.onWorkspacesTapped,
                    ),
                  if (kFeatureMediaManager)
                    SbRailRow(
                      icon: Icons.image_rounded,
                      label: 'Media',
                      onTap: widget.onMediaTapped,
                    ),
                  if (!(_searchVisible || _searchQuery.isNotEmpty))
                    SbRailRow(
                      icon: Icons.search_rounded,
                      label: 'Search',
                      onTap: _toggleSearch,
                    ),
                ],
              ),
            ),
          ),

          // Active search field sits below the rail rows so it can use the
          // full sidebar width — the inline morph happens in the same slot
          // visually because the inactive Search rail row above is removed
          // when active.
          if (_searchVisible || _searchQuery.isNotEmpty)
            _buildSearchRailRow(iconFg, accent),

          const SizedBox(height: 10),

          if (_isOfflineMode)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _sidebarHorizontalPadding,
                vertical: 4,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        size: 14, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Offline - Showing cached chats',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: Icon(Icons.refresh_rounded,
                          size: 14, color: Colors.orange),
                      tooltip: 'Check for updates',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 20,
                        height: 20,
                      ),
                      onPressed: () async {
                        final isOnline =
                            await NetworkStatusService.quickCheck();
                        if (isOnline && mounted) {
                          await _loadChatsAndRefresh();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),

          // Sticky pinned block above the scrolling time-bucketed list.
          // Capped height + internal scroll so many pinned chats don't push
          // the recent list offscreen.
          if (pinnedChats.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: _buildPinnedSticky(pinnedChats, iconFg, accent),
            ),

          Expanded(
            child: Stack(
              children: [
                CustomScrollView(
                  controller: _scrollController,
                  cacheExtent: 200.0,
                  slivers: _buildScrollableSlivers(
                      restChats, iconFg, accent, sidebarBg),
                ),
                // Sticky overlay header — exactly one bucket label visible
                // at the top at any time, swapped as the user scrolls past
                // each bucket boundary.
                if (_currentBucket.isNotEmpty)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Container(
                        height: _kStickyHeaderHeight,
                        color: sidebarBg,
                        child: SbSectionLabel(
                          label: _currentBucket,
                          color: accent,
                          padding:
                              const EdgeInsets.fromLTRB(20, 8, 16, 8),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Thin fade above so list rows blur into the footer.
                      IgnorePointer(
                        child: Container(
                          height: 22,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                sidebarBg.withValues(alpha: 0),
                                sidebarBg,
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Footer sits on solid sidebar bg — no transparency over
                      // the user's name.
                      Container(
                        color: sidebarBg,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const UpdateBanner(),
                            KeyedSubtree(
                              key: TourKeyRegistry.instance.keyFor(
                                TourSlots.settingsEntry,
                              ),
                              child: _buildFooterRow(iconFg, accent),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Sticky pinned section — sits between the nav stack and the scrolling
  // recent list. Internal SingleChildScrollView keeps it bounded when the
  // user has many pinned chats.
  Widget _buildPinnedSticky(
    List<StoredChat> pinned,
    Color iconFg,
    Color accent,
  ) {
    Widget chatTile(StoredChat c) => _buildRecentItem(
          c,
          onTap: () => _onChatTapped(c),
          onDelete: () => _confirmAndDeleteChat(c),
          accentColor: accent,
          iconFgColor: iconFg,
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SbSectionLabel(
          label: 'Pinned',
          padding: EdgeInsets.fromLTRB(20, 8, 16, 4),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: pinned.map(chatTile).toList(),
            ),
          ),
        ),
      ],
    );
  }

  // Builds the slivers for the scrolling recent area AND the marker list
  // the overlay header uses. Layout in scroll content:
  //
  //   [TODAY label]      <- content offset 0   (hidden behind overlay
  //   today chat 1          at scroll 0)
  //   today chat 2
  //   ...
  //   [THIS WEEK label]  <- transition point
  //   week chats...
  //   [OLDER label]
  //   older chats...
  //   [130 px footer buffer]
  //
  // Each bucket's marker is the scroll position at which the next inline
  // label would appear just below the sticky overlay (viewport y = overlay
  // height). The bucket label inside the overlay is then `_currentBucket`.
  List<Widget> _buildScrollableSlivers(
    List<StoredChat> rest,
    Color iconFg,
    Color accent,
    Color sidebarBg,
  ) {
    final List<Widget> slivers = [];
    _sectionMarkers.clear();

    if (rest.isEmpty) {
      _currentBucket = '';
      // Buffer so the empty-state text isn't hidden by the (now empty)
      // overlay region.
      slivers.add(const SliverToBoxAdapter(
        child: SizedBox(height: _kStickyHeaderHeight),
      ));
      final String msg = _searchQuery.isEmpty
          ? 'No recent chats yet.'
          : 'No chats found for "$_searchQuery".';
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _sidebarHorizontalPadding,
            vertical: 8.0,
          ),
          child: Text(msg,
              style: TextStyle(color: iconFg.withValues(alpha: 0.5))),
        ),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 130)));
      return slivers;
    }

    final int visible = math.min(rest.length, _displayLimit);
    final List<StoredChat> visibleRest = rest.take(visible).toList();

    final DateTime now = DateTime.now();
    final DateTime today0 = DateTime(now.year, now.month, now.day);
    final DateTime weekStart = today0.subtract(const Duration(days: 6));

    final List<StoredChat> today = [];
    final List<StoredChat> week = [];
    final List<StoredChat> older = [];
    for (final c in visibleRest) {
      // Bucket by last activity (the same field that drives recent
      // ordering) so a long-running chat that got a new message today
      // shows up under "Today" rather than under its creation date.
      final d = c.updatedAt ?? c.createdAt;
      if (!d.isBefore(today0)) {
        today.add(c);
      } else if (!d.isBefore(weekStart)) {
        week.add(c);
      } else {
        older.add(c);
      }
    }

    double cursor = 0;
    void addBucket(String label, List<StoredChat> chats) {
      if (chats.isEmpty) return;
      // Marker is the scroll position at which this bucket's inline label
      // arrives at viewport y = overlay height — clamped to 0 for the
      // first bucket so it's the default.
      _sectionMarkers.add(_BucketBound(
        label,
        math.max(0.0, cursor - _kStickyHeaderHeight),
      ));
      slivers.add(SliverToBoxAdapter(
        child: SbSectionLabel(
          label: label,
          color: accent,
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
        ),
      ));
      cursor += _kStickyHeaderHeight;
      slivers.add(SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) => _buildRecentItem(
            chats[i],
            onTap: () => _onChatTapped(chats[i]),
            onDelete: () => _confirmAndDeleteChat(chats[i]),
            accentColor: accent,
            iconFgColor: iconFg,
          ),
          childCount: chats.length,
        ),
      ));
      cursor += chats.length * _kEstimatedRowHeight;
    }

    addBucket('Today', today);
    addBucket('This week', week);
    addBucket('Older', older);

    if (_sectionMarkers.isNotEmpty) {
      final double offset = _scrollController.hasClients
          ? _scrollController.position.pixels
          : 0.0;
      String found = _sectionMarkers.first.label;
      for (final m in _sectionMarkers) {
        if (offset >= m.startOffset) {
          found = m.label;
        } else {
          break;
        }
      }
      _currentBucket = found;
    } else {
      _currentBucket = '';
    }

    // Reserve room at the bottom so the last chat row isn't hidden behind
    // the footer overlay (UpdateBanner + name pill ≈ 130 px).
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 130)));

    return slivers;
  }

  // Inline search slot: SbRailRow until the user taps it, then morphs into
  // the original soft-rounded search field (same hint/prefix/suffix styling
  // as before — only the host position changed). Tapping the trailing X
  // collapses it back to the nav row.
  Widget _buildSearchRailRow(Color iconFg, Color accent) {
    final bool active = _searchVisible || _searchQuery.isNotEmpty;
    if (!active) {
      return SbRailRow(
        icon: Icons.search_rounded,
        label: 'Search',
        onTap: _toggleSearch,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: iconFg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search chats',
            hintStyle: TextStyle(
              color: iconFg.withValues(alpha: 0.5),
              fontSize: 13.5,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 17,
              color: iconFg.withValues(alpha: 0.6),
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 36,
              minHeight: 36,
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: InputBorder.none,
            suffixIcon: InkResponse(
              radius: 14,
              onTap: () {
                if (_searchQuery.isNotEmpty) {
                  _clearSearchQuery();
                } else {
                  setState(() => _searchVisible = false);
                }
              },
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: iconFg.withValues(alpha: 0.55),
                ),
              ),
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 28,
              minHeight: 28,
            ),
          ),
          style: TextStyle(color: iconFg, fontSize: 13.5),
          cursorColor: accent,
        ),
      ),
    );
  }

  Widget _buildFooterRow(Color iconFg, Color accent) {
    final String name = _displayNameFor(_profile);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Material(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: widget.onSettingsTapped,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 5, 4, 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: iconFg,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Credit pill — bigger, fully rounded, layered tint above
                // the footer background so it reads as a discrete badge.
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.20),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: BalanceBadge(
                    textStyle: TextStyle(
                      color: accent,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                    placeholderStyle: TextStyle(
                      color: iconFg.withValues(alpha: 0.55),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(width: 6),
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onSettingsTapped,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.settings_rounded,
                          size: 24, color: iconFg.withValues(alpha: 0.8)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    bool isLast = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconFgColor,
    bool compact = false,
    bool noOuterPad = false,
  }) {
    final bool isSelected = chat.id == widget.selectedChatId;
    final bool isStreaming = StreamingManager().isStreaming(chat.id);
    final String title = chat.isLocked ? 'Locked chat' : _deriveChatTitle(chat);
    final bool isLocked = chat.isLocked;
    final bool isPinned = chat.isStarred;
    return SbChatTile(
      title: title,
      createdAt: chat.createdAt,
      selected: isSelected,
      pinned: isPinned,
      locked: isLocked,
      streaming: isStreaming,
      dimmed: isLast,
      compact: compact,
      noOuterPad: noOuterPad,
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
      trailingOnHover: !compact,
      trailing: compact
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    icon: Icon(
                      isPinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 15,
                      color: isPinned
                          ? accentColor
                          : iconFgColor.withValues(alpha: 0.75),
                    ),
                    padding: EdgeInsets.zero,
                    splashRadius: 14,
                    visualDensity: VisualDensity.compact,
                    tooltip: isPinned ? 'Unpin chat' : 'Pin chat',
                    constraints:
                        const BoxConstraints.tightFor(width: 24, height: 24),
                    onPressed: () => _toggleStarred(chat),
                  ),
                ),
                Builder(builder: (btnContext) {
                  return SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      icon: Icon(
                        Icons.more_horiz_rounded,
                        size: 17,
                        color: iconFgColor.withValues(alpha: 0.75),
                      ),
                      padding: EdgeInsets.zero,
                      splashRadius: 14,
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Chat options',
                      constraints:
                          const BoxConstraints.tightFor(width: 24, height: 24),
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
              ],
            ),
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
      case 'edit':
        _renameChatDialog(chat);
        break;
      case 'delete':
        if (onDelete != null) onDelete();
        break;
    }
  }

  // Build menu items for both PopupMenuButton and context menu.
  // Pin/unpin is exposed as a dedicated hover button next to the three-dots
  // — keeping it out of the menu makes the common toggle a single click.
  List<PopupMenuEntry<String>> _buildMenuItems(
    StoredChat chat, {
    required Color accentColor,
    required Color iconFgColor,
  }) {
    return [
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
          'This chat is encrypted with a previous password. '
          'Go to Settings \u2192 Recover Encrypted Chats to unlock it '
          'by entering your old password.',
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to rename chat: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '"$displayTitle" deleted',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to delete chat: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    }
  }
}

class _BucketBound {
  final String label;
  final double startOffset;
  const _BucketBound(this.label, this.startOffset);
}
