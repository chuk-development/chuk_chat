// lib/platform_specific/sidebar_mobile.dart
//
// Same structure as the desktop sidebar, and deliberately so: an account
// card, a navigation block, one block of chats per time group under its own
// header, and a bar at the foot with the search field and the two round
// actions. What differs here is only what the phone needs — a debounced,
// off-thread search and a bottom sheet instead of a right-click menu.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Assuming this exists
import 'package:chuk_chat/services/update_check_service.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/update_banner.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

class SidebarMobile extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onWorkspacesTapped;
  final Function() onMediaTapped;
  final Function() onNewChatTapped;
  final Future<void> Function(String chatId)? onChatDeleted;

  /// Slides the drawer shut. Null hides the profile card's collapse button.
  final VoidCallback? onCollapseTapped;
  final String? selectedChatId;
  final bool isCompactMode; // Not directly used in the UI, but kept for context

  const SidebarMobile({
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
  });

  @override
  State<SidebarMobile> createState() => _SidebarMobileState();
}

class _SidebarMobileState extends State<SidebarMobile> {
  static const Duration _searchDebounceDuration = Duration(milliseconds: 300);
  static const int _searchMessageLimit = 50;
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
  Future<void>? _refreshInFlight;
  bool _refreshPending = false;
  StreamSubscription<String?>? _chatUpdatesSub;
  Timer? _searchDebounce;
  int _filterGeneration = 0;
  Timer? _deleteNotificationTimer;
  String? _lastDeletedChatTitle;
  bool _isOfflineMode = false;
  final FocusNode _searchFocus = FocusNode();

  /// True while the search row shows the field instead of the nav card.
  bool _searchActive = false;

  @override
  void initState() {
    super.initState();
    // Chat loading handled by AppInitializationService and ChatSyncService
    _searchController.addListener(_onSearchChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
    _scrollController.addListener(_onScrollForAutoLoad);
    unawaited(_loadProfile());
    _chatUpdatesSub = ChatStorageService.changes.listen((changedChatId) {
      if (!mounted) return;
      if (changedChatId == null) {
        // Bulk change (initial load, sync) - refilter everything
        unawaited(_filterRecentChats());
      } else {
        // Single chat changed - just trigger rebuild without refiltering
        setState(() {});
      }
    });
    // Monitor network status for offline indicators
    NetworkStatusService.isOnlineListenable.addListener(
      _onNetworkStatusChanged,
    );
    unawaited(_filterRecentChats());
    // Check for app updates in background
    unawaited(UpdateCheckService.checkForUpdate());
  }

  @override
  void dispose() {
    _chatUpdatesSub?.cancel();
    _searchDebounce?.cancel();
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

  // Auto-load older chats as the user scrolls near the bottom — no
  // Show-more button needed.
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
  /// Opens the search row and puts the caret in it. The row folds back into
  /// the plain nav card once the field is empty and no longer focused, so an
  /// abandoned search does not sit there forever.
  void _focusSearch() {
    setState(() => _searchActive = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _onSearchFocusChanged() {
    if (_searchFocus.hasFocus) return;
    if (_searchController.text.isNotEmpty) return;
    if (!mounted) return;
    setState(() => _searchActive = false);
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
    _searchDebounce?.cancel();
    _displayLimit = _kPageSize;
    // Repaint now so the field's own clear button appears with the first
    // keystroke; the expensive filtering still waits for the debounce.
    if (mounted) setState(() {});
    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      unawaited(_filterRecentChats());
    });
  }

  void _clearSearchQuery() {
    _searchDebounce?.cancel();
    _filterGeneration++;
    _searchController.clear();
    if (!mounted) return;
    setState(() {
      _searchQuery = '';
      _filteredRecentChats = List<StoredChat>.from(
        ChatStorageService.savedChats,
      );
    });
  }

  Future<void> _loadChatsAndRefresh() async {
    await _refreshChats();
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
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('SidebarMobile profile load failed: $error');
      }
      if (kDebugMode) {
        debugPrint('$stackTrace');
      }
    }
  }

  Future<void> _refreshChats() {
    if (_refreshInFlight != null) {
      _refreshPending = true;
      return _refreshInFlight!;
    }

    final future = _performRefresh().whenComplete(() {
      final shouldRepeat = _refreshPending;
      _refreshInFlight = null;
      _refreshPending = false;
      if (shouldRepeat) {
        unawaited(_refreshChats());
      }
    });
    _refreshInFlight = future;
    return future;
  }

  Future<void> _performRefresh() async {
    try {
      // Use syncNow() instead of loadSavedChatsForSidebar() to fetch
      // from the server rather than redundantly reloading the local cache.
      // The sync service updates local state and fires notifyChanges().
      await ChatSyncService.syncNow();
      if (!mounted) return;
      await _filterRecentChats();
      setState(() {
        _isOfflineMode = !NetworkStatusService.isOnline;
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('SidebarMobile chat sync failed: $error');
      }
      if (kDebugMode) {
        debugPrint('$stackTrace');
      }
    }
  }

  void _onNetworkStatusChanged() {
    if (!mounted) return;
    setState(() {
      _isOfflineMode = !NetworkStatusService.isOnline;
    });
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
      await _filterRecentChats();
    } on StateError catch (error) {
      _showSnack(messenger, error.message);
    } catch (error) {
      _showSnack(messenger, 'Error: $error');
    }
  }

  // One snack shape for the whole sidebar, so an error, a rename failure and
  // a delete confirmation all look the same.
  void _showSnack(ScaffoldMessengerState messenger, String message) {
    // The messenger is captured before an await and outlives this sidebar, so
    // a failure that lands after the drawer closed would otherwise put a snack
    // on a screen the user already left.
    if (!mounted) return;
    // Two failures in a row otherwise queue: the second message would wait out
    // the first one's two seconds before the user ever sees it.
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
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
      _showSnack(messenger, '"$displayTitle" deleted');
    });
  }

  Future<void> _confirmAndDeleteChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    // Get chat title for display (use helper for consistent derivation)
    final derivedTitle = _deriveChatTitle(chat);
    final chatTitle = derivedTitle.length > 40
        ? '${derivedTitle.substring(0, 40)}...'
        : derivedTitle;

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
      _showSnack(messenger, error.message);
    } catch (error) {
      _showSnack(messenger, 'Error: $error');
    }
  }

  Future<void> _filterRecentChats() async {
    final String query = _searchController.text.trim();
    final List<StoredChat> savedChats = ChatStorageService.savedChats;
    final int currentGeneration = ++_filterGeneration;

    if (query.isEmpty) {
      if (!mounted || currentGeneration != _filterGeneration) return;
      setState(() {
        _searchQuery = '';
        _filteredRecentChats = List<StoredChat>.from(savedChats);
      });
      return;
    }

    if (savedChats.isEmpty) {
      if (!mounted || currentGeneration != _filterGeneration) return;
      setState(() {
        _searchQuery = query;
        _filteredRecentChats = const <StoredChat>[];
      });
      return;
    }

    final String lowerQuery = query.toLowerCase();

    if (kIsWeb) {
      final List<StoredChat> filtered = _filterChatsLocally(
        savedChats,
        lowerQuery,
      );
      if (!mounted || currentGeneration != _filterGeneration) return;
      setState(() {
        _searchQuery = query;
        _filteredRecentChats = filtered;
      });
      return;
    }

    final List<Map<String, Object?>> payload = savedChats
        .map(
          (chat) => {
            'id': chat.id,
            'preview': _deriveChatTitle(chat).toLowerCase(),
            'messages': (chat.messagesOrNull ?? const [])
                .take(_searchMessageLimit)
                .map((message) => message.text.toLowerCase())
                .toList(growable: false),
          },
        )
        .toList(growable: false);

    try {
      final List<String> matchIds = await compute(_filterChatsIsolate, {
        'chats': payload,
        'query': lowerQuery,
      });
      if (!mounted || currentGeneration != _filterGeneration) return;
      final Set<String> matchIdSet = matchIds.toSet();
      final List<StoredChat> latestChats = ChatStorageService.savedChats;
      final List<StoredChat> filtered = latestChats
          .where((chat) => matchIdSet.contains(chat.id))
          .toList(growable: false);
      setState(() {
        _searchQuery = query;
        _filteredRecentChats = filtered;
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('SidebarMobile filtering failed: $error');
      }
      if (kDebugMode) {
        debugPrint('$stackTrace');
      }
      if (!mounted || currentGeneration != _filterGeneration) return;
      final List<StoredChat> fallback = _filterChatsLocally(
        savedChats,
        lowerQuery,
      );
      setState(() {
        _searchQuery = query;
        _filteredRecentChats = fallback;
      });
    }
  }

  List<StoredChat> _filterChatsLocally(
    List<StoredChat> chats,
    String lowerQuery,
  ) {
    return chats
        .where((chat) {
          final bool titleMatches = _deriveChatTitle(
            chat,
          ).toLowerCase().contains(lowerQuery);
          if (titleMatches) return true;
          return (chat.messagesOrNull ?? const [])
              .take(_searchMessageLimit)
              .any(
                (message) => message.text.toLowerCase().contains(lowerQuery),
              );
        })
        .toList(growable: false);
  }

  @override
  void didUpdateWidget(covariant SidebarMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatId != oldWidget.selectedChatId) {
      if (mounted) setState(() {});
    }
    // Also refresh filtered chats if the underlying ChatStorageService.savedChats list changes
    if (ChatStorageService.savedChats.length != _filteredRecentChats.length &&
        _searchQuery.isEmpty) {
      unawaited(_filterRecentChats());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color accentColor = theme.colorScheme.primary;
    final Color sidebarBg = theme.cardColor.darken(0.02);

    // Use the real device safe-area inset instead of a magic 40.0 — a fixed
    // value puts the first block under the dynamic island / camera notch on
    // devices with larger top insets.
    final EdgeInsets viewPadding = MediaQuery.paddingOf(context);

    // Both bars are cards that float over the list, not bands that box it
    // in: the chats run past them on every side, and the panel keeps its
    // full height for content.
    const double topChromeHeight = 54.0;
    const double bottomChromeHeight = 54.0;
    final double topInset = viewPadding.top + 8.0;
    final double bottomInset = 10.0 + viewPadding.bottom;

    return Container(
      color: sidebarBg,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              controller: _scrollController,
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: SizedBox(height: topInset + topChromeHeight + 8),
                ),
                ..._buildSlivers(accentColor),
                SliverToBoxAdapter(
                  child: SizedBox(height: bottomChromeHeight + bottomInset),
                ),
              ],
            ),
          ),

          // The top of the sidebar names the app, not the person using it,
          // and carries the one action that starts something: a new chat.
          Positioned(
            top: topInset,
            left: kSbBlockInset + 4,
            right: kSbBlockInset + 4,
            child: SbFloatingBar(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: SizedBox(
                  height: topChromeHeight - 12,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: BrandWordmark(color: theme.resolvedIconColor),
                        ),
                      ),
                      if (widget.onCollapseTapped != null)
                        SbRoundAction(
                          icon: Icons.keyboard_double_arrow_left_rounded,
                          tooltip: AppLocalizations.of(context)?.hideSidebar ??
                              'Hide sidebar',
                          diameter: 34,
                          iconSize: 19,
                          onTap: widget.onCollapseTapped!,
                        ),
                      const SizedBox(width: 6),
                      SbRoundAction(
                        icon: Icons.edit_square,
                        tooltip:
                            AppLocalizations.of(context)?.newChat ?? 'New chat',
                        diameter: 34,
                        iconSize: 17,
                        fill: accentColor,
                        onTap: widget.onNewChatTapped,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const UpdateBanner(),
                KeyedSubtree(
                  key:
                      TourKeyRegistry.instance.keyFor(TourSlots.settingsEntry),
                  child: Padding(
                    // The home indicator sits below the box, so it keeps its
                    // own 6 px and adds what the device reserves.
                    padding: EdgeInsets.fromLTRB(
                      kSbBlockInset + 4,
                      6,
                      kSbBlockInset + 4,
                      bottomInset,
                    ),
                    child: SbAccountLine(
                      name: _displayNameFor(_profile),
                      onTap: widget.onSettingsTapped,
                      onSettings: widget.onSettingsTapped,
                      balance: BalanceBadge(
                        textStyle: TextStyle(
                          color: accentColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        placeholderStyle: TextStyle(
                          color: theme.m3.onSurfaceVariant,
                          fontSize: 13,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The whole scrolling column, top to bottom: account, navigation, the
  // offline notice, then one header + block per time group.
  List<Widget> _buildSlivers(Color accent) {
    final theme = Theme.of(context);
    final List<StoredChat> pinnedChats =
        _filteredRecentChats.where((c) => c.isStarred).toList();
    final List<StoredChat> restChats =
        _filteredRecentChats.where((c) => !c.isStarred).toList();

    final List<Widget> slivers = <Widget>[
      SliverToBoxAdapter(child: SbBlock(children: _buildNavCards())),
      if (_isOfflineMode)
        SliverToBoxAdapter(
          child: SbOfflineNotice(
            label: 'Offline - cached chats',
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
              style: TextStyle(color: theme.m3.onSurfaceVariant),
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
      // A folded group renders no tiles, so it must not spend the page
      // either — otherwise folding the top group empties the ones below it.
      final bool folded = _collapsedGroups.contains(group.label);
      if (!folded && budget <= 0) break;
      final int shown = folded ? 0 : math.min(budget, group.items.length);
      budget -= shown;
      slivers.addAll(
        _buildGroup(
          group.label,
          group.items.take(shown).toList(),
          accent,
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
      if (kFeatureWorkspaces)
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
      // Search stays in its own row and becomes the field in place: same
      // slot, same card, same corners. A second search box at the bottom of
      // the panel was only a duplicate of this one.
      if (_searchActive)
        SbCard(
          // `selected` is what paints the accent outline, and it follows the
          // card's own corners — the field keeps the ring it used to have,
          // in the shape of the row it replaced.
          selected: true,
          padding: EdgeInsets.zero,
          minHeight: kSbNavCardHeight,
          child: SbSearchField(
            controller: _searchController,
            focusNode: _searchFocus,
            transparent: true,
            onClear: _clearSearchQuery,
          ),
        )
      else
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
    Color accent, {
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
                kSbCardGap,
                kSbBlockInset,
                0,
              ),
              child: SbCardShape(
                // The header above is the first card of this block, so the
                // chats are 1..n and only the last one rounds outward.
                radius: sbBlockRadiusFor(
                  index: i + 1,
                  length: chats.length + 1,
                ),
                child: _buildRecentItem(
                  chats[i],
                  onTap: () => _onChatTapped(chats[i]),
                  onDelete: () => _confirmAndDeleteChat(chats[i]),
                  accentColor: accent,
                ),
              ),
            ),
            childCount: chats.length,
          ),
        ),
    ];
  }

  void _onChatTapped(StoredChat storedChat) {
    if (kDebugMode) {
      debugPrint(
        '👆 [SIDEBAR-MOBILE] User tapped recent chat ${storedChat.id}',
      );
    }
    widget.onChatSelected(storedChat.id);
  }

  Widget _buildRecentItem(
    StoredChat chat, {
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
  }) {
    final theme = Theme.of(context);
    final bool isSelected = chat.id == widget.selectedChatId;
    final bool isLocked = chat.isLocked;
    final bool isStreaming = StreamingManager().isStreaming(chat.id);
    final String title =
        isLocked ? 'Locked encrypted chat' : _deriveChatTitle(chat);
    void openSheet() => _showChatOptionsBottomSheet(
          chat,
          onDelete: onDelete,
          accentColor: accentColor,
          iconColor: theme.m3.onSurfaceVariant,
        );
    return SbChatTile(
      title: title,
      dateLine: sbChatDateLine(context, chat.updatedAt ?? chat.createdAt),
      selected: isSelected,
      locked: isLocked,
      streaming: isStreaming,
      onTap: isLocked
          ? () => _showLockedChatDialog(accentColor: accentColor)
          : onTap,
      // Long press stays as it was; the button is only a second, visible way
      // into the same sheet.
      onLongPress: isLocked ? null : openSheet,
      trailing: isLocked
          ? null
          // The glyph stays small, but the box around it is Material's 48 px
          // minimum: it sits right beside the tile's own tap area, and a
          // near miss on a smaller target opens the chat instead of the
          // sheet.
          : SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 18,
                  color: theme.m3.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                splashRadius: 24,
                tooltip: 'Chat options',
                constraints:
                    const BoxConstraints.tightFor(width: 48, height: 48),
                onPressed: openSheet,
              ),
            ),
    );
  }

  void _showLockedChatDialog({required Color accentColor}) {
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

  void _showChatOptionsBottomSheet(
    StoredChat chat, {
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconColor,
  }) {
    final bool isPinned = chat.isStarred;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: isPinned ? accentColor : iconColor,
                ),
                title: Text(isPinned ? 'Unpin chat' : 'Pin chat'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleStarred(chat);
                },
              ),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: iconColor),
                title: const Text('Rename'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _renameChatDialog(chat);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent.withValues(alpha: 0.8),
                ),
                title: Text(
                  'Delete',
                  style: TextStyle(
                    color: Colors.redAccent.withValues(alpha: 0.8),
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (onDelete != null) onDelete();
                },
              ),
            ],
          ),
        );
      },
    );
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
      await _filterRecentChats();
    } on StateError catch (error) {
      _showSnack(messenger, error.message);
    } catch (error) {
      _showSnack(messenger, 'Failed to rename chat: $error');
    }
  }
}

List<String> _filterChatsIsolate(Map<String, dynamic> params) {
  final List<dynamic> chats = params['chats'] as List<dynamic>? ?? const [];
  final String query = params['query'] as String? ?? '';
  if (query.isEmpty || chats.isEmpty) {
    return const <String>[];
  }

  final List<String> matches = <String>[];
  for (final dynamic entry in chats) {
    final Map<dynamic, dynamic> chat = entry as Map<dynamic, dynamic>;
    final String? id = chat['id'] as String?;
    if (id == null) {
      continue;
    }

    final String preview = (chat['preview'] as String?) ?? '';
    if (preview.contains(query)) {
      matches.add(id);
      continue;
    }

    final List<dynamic> messages =
        chat['messages'] as List<dynamic>? ?? const [];
    final bool hasMatch = messages.any(
      (dynamic message) => (message as String).contains(query),
    );
    if (hasMatch) {
      matches.add(id);
    }
  }

  return matches;
}
