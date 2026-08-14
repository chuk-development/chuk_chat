// lib/platform_specific/sidebar_mobile.dart
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
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Assuming this exists
import 'package:chuk_chat/services/update_check_service.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/update_banner.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/cowork_mode_switcher.dart';
import 'package:chuk_chat/models/app_mode.dart';

class SidebarMobile extends StatefulWidget {
  final Function(String? chatId) onChatSelected;
  final Function() onSettingsTapped;
  final Function() onWorkspacesTapped;
  final Function() onMediaTapped;
  final Function() onNewChatTapped;
  final Future<void> Function(String chatId)? onChatDeleted;
  final String? selectedChatId;
  final bool isCompactMode; // Not directly used in the UI, but kept for context

  /// Current app mode and its setter — only used to render the CoWork
  /// switcher under the brand row when [kFeatureCoWork] is on.
  final AppMode mode;
  final ValueChanged<AppMode> onModeChanged;

  const SidebarMobile({
    super.key,
    required this.onChatSelected,
    required this.onSettingsTapped,
    required this.onWorkspacesTapped,
    required this.onMediaTapped,
    required this.onNewChatTapped,
    this.onChatDeleted,
    required this.selectedChatId,
    required this.isCompactMode,
    required this.mode,
    required this.onModeChanged,
  });

  @override
  State<SidebarMobile> createState() => _SidebarMobileState();
}

class _SidebarMobileState extends State<SidebarMobile> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;
  static const Duration _searchDebounceDuration = Duration(milliseconds: 300);
  static const int _searchMessageLimit = 50;
  static const int _kPageSize = 40;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<StoredChat> _filteredRecentChats = [];
  int _displayLimit = _kPageSize;
  final ScrollController _scrollController = ScrollController();
  String _currentBucket = '';
  final List<_BucketBound> _sectionMarkers = [];
  static const double _kEstimatedRowHeight = 32.0;
  // Tall enough for the label's descenders: the y of "Today" and the p of
  // "Pinned" were cut off when the label grew and this did not.
  static const double _kStickyHeaderHeight = 42.0;
  ProfileRecord? _profile;
  Future<void>? _refreshInFlight;
  bool _refreshPending = false;
  StreamSubscription<String?>? _chatUpdatesSub;
  Timer? _searchDebounce;
  int _filterGeneration = 0;
  Timer? _deleteNotificationTimer;
  String? _lastDeletedChatTitle;
  bool _isOfflineMode = false;
  bool _searchVisible = false;
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Chat loading handled by AppInitializationService and ChatSyncService
    _searchController.addListener(_onSearchChanged);
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
  // Show-more button needed. Also keeps the sticky overlay header in
  // sync with the topmost-visible bucket.
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

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _displayLimit = _kPageSize;
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
            'Error: $error',
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
            'Error: $error',
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
    final l = AppLocalizations.of(context)!;
    final Color iconColorDefault = theme.resolvedIconColor.withValues(
      alpha: 0.7,
    );
    final Color textColorDefault =
        theme.textTheme.bodyMedium?.color ?? theme.colorScheme.onSurface;
    final Color accentColor = theme.colorScheme.primary;
    final Color sidebarBg = theme.cardColor.darken(0.02);

    final List<StoredChat> pinnedChats =
        _filteredRecentChats.where((c) => c.isStarred).toList();
    final List<StoredChat> restChats =
        _filteredRecentChats.where((c) => !c.isStarred).toList();

    // Use the real device safe-area inset instead of a magic 40.0 — a
    // fixed value puts the brand row under the dynamic island / camera
    // notch on devices with larger top insets. Add 8 px of breathing
    // room on top of the inset so the brand sits visually below the
    // status indicators, not flush against them.
    final double topStatusBarSpacing =
        MediaQuery.paddingOf(context).top + 8.0;
    final bool showSearchField = _searchVisible || _searchQuery.isNotEmpty;

    return Container(
      color: sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: topStatusBarSpacing),

          SbBrand(
            label: 'Chuk Chat',
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 12),
            trailing: SbNewChatPill(onTap: widget.onNewChatTapped),
          ),

          // CoWork switcher — directly under the brand row and its New chat
          // pill, above the nav items. Same app, runtime mode.
          if (kFeatureCoWork)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: CoWorkModeSwitcher(
                  mode: widget.mode,
                  onChanged: widget.onModeChanged,
                ),
              ),
            ),

          // Match desktop ordering: Workspaces → Media → Search at the bottom.
          // The Search row morphs in-place into the input field when tapped
          // (search row disappears, input takes the same slot) so the text
          // field never pushes other rows out of place.
          if (kFeatureWorkspaces)
            SbNavItem(
              icon: Icons.folder_rounded,
              label: l.workspaces,
              onTap: widget.onWorkspacesTapped,
            ),
          if (kFeatureMediaManager)
            SbNavItem(
              icon: Icons.image_rounded,
              label: l.media,
              onTap: widget.onMediaTapped,
            ),
          if (!showSearchField)
            SbNavItem(
              icon: Icons.search_rounded,
              label: 'Search',
              onTap: _toggleSearch,
            ),
          if (showSearchField)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: textColorDefault.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  decoration: InputDecoration(
                    hintText: 'Search chats',
                    hintStyle: TextStyle(
                      color: textColorDefault.withValues(alpha: 0.5),
                      fontSize: 13.5,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 17,
                      color: textColorDefault.withValues(alpha: 0.6),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 38,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    border: InputBorder.none,
                    suffixIcon: InkResponse(
                      radius: 14,
                      onTap: () {
                        // Tapping the X always collapses the search row back —
                        // mirrors desktop. The text is cleared on the way out
                        // so a future re-open starts fresh.
                        _clearSearchQuery();
                        setState(() => _searchVisible = false);
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: textColorDefault.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                  style: TextStyle(
                    color: textColorDefault,
                    fontSize: 13.5,
                  ),
                  cursorColor: accentColor,
                ),
              ),
            ),
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
                        'Offline - Cached chats',
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

          Expanded(
            child: Stack(
              children: [
                Column(
                  children: [
                    if (pinnedChats.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: _buildPinnedSticky(
                          pinnedChats,
                          iconColorDefault,
                          textColorDefault,
                          accentColor,
                        ),
                      ),
                    Expanded(
                      child: Stack(
                        children: [
                          CustomScrollView(
                            controller: _scrollController,
                            slivers: _buildScrollableSlivers(
                              restChats,
                              iconColorDefault,
                              textColorDefault,
                              accentColor,
                              sidebarBg,
                            ),
                          ),
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
                                    color: accentColor,
                                    padding: const EdgeInsets.fromLTRB(
                                        20, 8, 16, 8),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // One long fade instead of a thin fade plus a solid
                      // slab. The chat list stays faintly visible under the
                      // name pill — the footer floats over the list rather
                      // than cutting it off with a hard edge.
                      //
                      // The fade is a Positioned.fill behind the footer and
                      // wrapped in IgnorePointer: painted as a Container
                      // around the column it would swallow taps meant for
                      // the chat rows showing through it.
                      Stack(
                        children: [
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      sidebarBg.withValues(alpha: 0),
                                      sidebarBg.withValues(alpha: 0.35),
                                      sidebarBg.withValues(alpha: 0.6),
                                    ],
                                    stops: const [0.0, 0.55, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 34),
                              const UpdateBanner(),
                              KeyedSubtree(
                                key: TourKeyRegistry.instance.keyFor(
                                  TourSlots.settingsEntry,
                                ),
                                child: _buildFooterRow(
                                  iconColorDefault,
                                  textColorDefault,
                                  accentColor,
                                  sidebarBg,
                                ),
                              ),
                            ],
                          ),
                        ],
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

  // Sticky pinned block — sits above the scrolling time-bucketed list.
  Widget _buildPinnedSticky(
    List<StoredChat> pinned,
    Color iconColor,
    Color textColor,
    Color accent,
  ) {
    Widget chatTile(StoredChat c) => _buildRecentItem(
          c,
          onTap: () => _onChatTapped(c),
          onDelete: () => _confirmAndDeleteChat(c),
          accentColor: accent,
          iconColor: iconColor,
          textColor: textColor,
        );
    // A tinted box, not just a label: pinned chats are a place, and the
    // reader should see where that place ends without reading anything.
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SbSectionLabel(
            label: 'Pinned',
            count: pinned.length,
            color: accent,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
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
      ),
    );
  }

  // Time-bucketed slivers with pinned section headers — TODAY stays at
  // the top while scrolling today's chats, then THIS WEEK pins as the
  // user scrolls past, then OLDER. Pagination is invisible: more chats
  // stream in as the user scrolls (see `_onScrollForAutoLoad`).
  List<Widget> _buildScrollableSlivers(
    List<StoredChat> rest,
    Color iconColor,
    Color textColor,
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
              style: TextStyle(color: iconColor.withValues(alpha: 0.4))),
        ),
      ));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 130)));
      return slivers;
    }

    final int visible = rest.length < _displayLimit ? rest.length : _displayLimit;
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
      // first bucket so it's the default. Mirrors the desktop layout so
      // mobile and desktop swap the sticky header at the same boundary.
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
            iconColor: iconColor,
            textColor: textColor,
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

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 130)));

    return slivers;
  }

  Widget _buildFooterRow(
    Color iconColor,
    Color textColor,
    Color accent,
    Color sidebarBg,
  ) {
    final String name = _displayNameFor(_profile);
    // The pill itself is opaque. Only the space around it fades into the
    // list — a translucent pill let chat titles show through the user's
    // own name, which is the one thing that must stay legible.
    final Color pillColor = Color.alphaBlend(
      accent.withValues(alpha: 0.08),
      sidebarBg,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 18),
      child: Material(
        color: pillColor,
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
                      color: textColor,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
                      color: textColor.withValues(alpha: 0.55),
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
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.settings_rounded,
                          size: 22, color: iconColor),
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
    if (kDebugMode) {
      debugPrint(
        '👆 [SIDEBAR-MOBILE] User tapped recent chat ${storedChat.id}',
      );
    }
    widget.onChatSelected(storedChat.id);
  }

  Widget _buildRecentItem(
    StoredChat chat, {
    bool isLast = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconColor,
    required Color textColor,
    bool compact = false,
  }) {
    bool isSelected = chat.id == widget.selectedChatId;
    final bool isLocked = chat.isLocked;
    final bool isPinned = chat.isStarred;
    final String title =
        isLocked ? 'Locked encrypted chat' : _deriveChatTitle(chat);
    return SbChatTile(
      title: title,
      createdAt: chat.updatedAt ?? chat.createdAt,
      selected: isSelected,
      pinned: isPinned,
      locked: isLocked,
      dimmed: isLast,
      compact: compact,
      onTap: isLocked
          ? () => _showLockedChatDialog(accentColor: accentColor)
          : onTap,
      onLongPress: isLocked
          ? null
          : () => _showChatOptionsBottomSheet(
              chat,
              onDelete: onDelete,
              accentColor: accentColor,
              iconColor: iconColor,
              textColor: textColor,
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
          'opened with your current one. Go to Account Settings \u2192 Chat '
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
    required Color textColor,
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

class _BucketBound {
  final String label;
  final double startOffset;
  const _BucketBound(this.label, this.startOffset);
}
