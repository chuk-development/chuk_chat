// lib/platform_specific/sidebar_mobile.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/chat_storage_service.dart'; // Assuming this exists
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Assuming this exists

class SidebarMobile extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped;
  final Future<void> Function(String chatId)? onChatDeleted;
  final int selectedChatIndex;
  final bool isCompactMode; // Not directly used in the UI, but kept for context

  const SidebarMobile({
    super.key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    this.onChatDeleted,
    required this.selectedChatIndex,
    required this.isCompactMode,
  });

  @override
  State<SidebarMobile> createState() => _SidebarMobileState();
}

class _SidebarMobileState extends State<SidebarMobile> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;
  // Standard icon width for alignment (originally in main.dart's Drawer)
  static const double _iconLeadingWidth = 24.0;
  // Spacing between icon and text (originally in main.dart's Drawer)
  static const double _iconTextSpacing = 16.0;
  static const Duration _searchDebounceDuration =
      Duration(milliseconds: 300);
  static const int _searchMessageLimit = 50;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<StoredChat> _filteredRecentChats = [];
  ProfileRecord? _profile;
  Timer? _refreshTimer;
  Future<void>? _refreshInFlight;
  bool _refreshPending = false;
  StreamSubscription<void>? _chatUpdatesSub;
  Timer? _searchDebounce;
  int _filterGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadChatsAndRefresh());
    _startAutoRefresh();
    _searchController.addListener(_onSearchChanged);
    unawaited(_loadProfile());
    _chatUpdatesSub = ChatStorageService.changes.listen((_) {
      if (!mounted) return;
      unawaited(_filterRecentChats());
    });
    unawaited(_filterRecentChats());
  }

  @override
  void dispose() {
    _chatUpdatesSub?.cancel();
    _refreshTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
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
      _filteredRecentChats =
          List<StoredChat>.from(ChatStorageService.savedChats);
    });
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshChatsPeriodically(),
    );
  }

  Future<void> _refreshChatsPeriodically() async {
    await _refreshChats();
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
      debugPrint('SidebarMobile profile load failed: $error');
      debugPrint('$stackTrace');
    }
  }

  String _initialsFor(ProfileRecord? profile) {
    final source = profile?.displayName.isNotEmpty == true
        ? profile!.displayName
        : profile?.email ?? '';
    if (source.trim().isEmpty) return '?';

    final parts = source.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    final first = parts.first.substring(0, 1).toUpperCase();
    final last = parts.last.substring(0, 1).toUpperCase();
    return '$first$last';
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
      await ChatStorageService.loadSavedChatsForSidebar();
      if (!mounted) return;
      await _filterRecentChats();
    } catch (error, stackTrace) {
      debugPrint('SidebarMobile chat sync failed: $error');
      debugPrint('$stackTrace');
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
    return chat.previewText;
  }

  Future<void> _toggleStarred(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChatStorageService.setChatStarred(chat.id, !chat.isStarred);
      if (!mounted) return;
      await _filterRecentChats();
    } on StateError catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to update star: $error')),
      );
    }
  }

  void _openChat(StoredChat chat) {
    final index = ChatStorageService.savedChats.indexWhere(
      (stored) => stored.id == chat.id,
    );
    if (index != -1) {
      widget.onChatItemTapped(index);
    }
  }

  Future<void> _confirmAndDeleteChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: const Text(
            'Deleting this chat removes it forever. This action cannot be undone.',
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
      await ChatStorageService.loadSavedChatsForSidebar();
      if (!mounted) return;
      await _filterRecentChats();
      if (widget.onChatDeleted != null) {
        await widget.onChatDeleted!(chat.id);
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('Chat deleted permanently.')),
      );
    } on StateError catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to delete chat: $error')),
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
      final List<StoredChat> filtered =
          _filterChatsLocally(savedChats, lowerQuery);
      if (!mounted || currentGeneration != _filterGeneration) return;
      setState(() {
        _searchQuery = query;
        _filteredRecentChats = filtered;
      });
      return;
    }

    final List<Map<String, Object?>> payload = savedChats
        .map((chat) => {
              'id': chat.id,
              'preview': _deriveChatTitle(chat).toLowerCase(),
              'messages': chat.messages
                  .take(_searchMessageLimit)
                  .map((message) => message.text.toLowerCase())
                  .toList(growable: false),
            })
        .toList(growable: false);

    try {
      final List<String> matchIds = await compute(
        _filterChatsIsolate,
        {'chats': payload, 'query': lowerQuery},
      );
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
      debugPrint('SidebarMobile filtering failed: $error');
      debugPrint('$stackTrace');
      if (!mounted || currentGeneration != _filterGeneration) return;
      final List<StoredChat> fallback =
          _filterChatsLocally(savedChats, lowerQuery);
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
    return chats.where((chat) {
      final bool titleMatches =
          _deriveChatTitle(chat).toLowerCase().contains(lowerQuery);
      if (titleMatches) return true;
      return chat.messages
          .take(_searchMessageLimit)
          .any((message) => message.text.toLowerCase().contains(lowerQuery));
    }).toList(growable: false);
  }

  @override
  void didUpdateWidget(covariant SidebarMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
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
    final Color iconColorDefault = theme.iconTheme.color!.withValues(
      alpha: 0.7,
    );
    final Color textColorDefault =
        theme.textTheme.bodyMedium?.color ?? theme.colorScheme.onSurface;
    final Color accentColor = theme.colorScheme.primary;
    final Color sidebarBg = theme.cardColor.darken(0.02);
    final Color dividerColor = theme.dividerColor.withValues(alpha: 0.5);
    final List<StoredChat> starredChats = ChatStorageService.savedChats
        .where((chat) => chat.isStarred)
        .toList();

    const double initialVerticalPadding =
        48.0; // From main.dart Drawer top padding

    return Container(
      color: sidebarBg,
      child: Column(
        children: [
          SizedBox(height: initialVerticalPadding),

          // Search Old Chats input field (styled from main.dart's InputDecorationTheme)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _sidebarHorizontalPadding,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Suchen',
                      prefixIcon: Icon(Icons.search, color: iconColorDefault),
                      filled: true,
                      fillColor: sidebarBg.lighten(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: dividerColor, width: 1),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: dividerColor, width: 1),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: accentColor, width: 1.3),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 0,
                      ),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Eingabe löschen',
                              splashRadius: 18,
                              icon: Icon(
                                Icons.clear,
                                color: iconColorDefault,
                              ),
                              onPressed: _clearSearchQuery,
                            ),
                    ),
                    style: TextStyle(color: textColorDefault),
                    cursorColor: textColorDefault,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16), // Spacing after search bar
          // Projects entry as per main.dart's Drawer items
          _buildDrawerItem(
            Icons.folder_open_outlined,
            'Neues Projekt',
            widget.onProjectsTapped,
            iconColorDefault,
            textColorDefault,
            tileBg: sidebarBg.lighten(0.04),
            dividerColor: dividerColor,
            accentColor: accentColor,
          ),

          const SizedBox(height: 24.0), // Spacing between groups
          // Starred Section - Fixed
          _buildSectionHeader('Starred', textColor: textColorDefault),
          if (starredChats.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _sidebarHorizontalPadding,
                vertical: 8.0,
              ),
              child: Text(
                'No starred chats yet.',
                style: TextStyle(
                  color: iconColorDefault.withValues(alpha: 0.4),
                ),
              ),
            )
          else
            ...starredChats.map(
              (chat) => _buildStarredItem(
                chat,
                textColorDefault,
                accentColor,
              ),
            ),
          Divider(
            color: dividerColor,
            indent: _sidebarHorizontalPadding,
            endIndent: _sidebarHorizontalPadding,
          ),

          // Recents Section - Scrollable
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildSectionHeader('Recents', textColor: textColorDefault),
                if (_filteredRecentChats.isEmpty && _searchQuery.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _sidebarHorizontalPadding,
                      vertical: 8.0,
                    ),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(
                        color: iconColorDefault.withValues(alpha: 0.4),
                      ),
                    ),
                  )
                else if (_filteredRecentChats.isEmpty &&
                    _searchQuery.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _sidebarHorizontalPadding,
                      vertical: 8.0,
                    ),
                    child: Text(
                      'No chats found for "$_searchQuery".',
                      style: TextStyle(
                        color: iconColorDefault.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ..._filteredRecentChats.asMap().entries.map((entry) {
                  final storedChat = entry.value;
                  final index = ChatStorageService.savedChats.indexOf(
                    storedChat,
                  );
                  if (index == -1) {
                    return const SizedBox.shrink();
                  }

                  return _buildRecentItem(
                    storedChat,
                    index: index,
                    onTap: () {
                      widget.onChatItemTapped(index);
                    },
                    onDelete: () => _confirmAndDeleteChat(storedChat),
                    accentColor: accentColor,
                    iconColor: iconColorDefault,
                    textColor: textColorDefault,
                  );
                }),
                const SizedBox(height: 10),
              ],
            ),
          ),

          // User profile section at the bottom (styled from main.dart)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 24.0),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: widget.onSettingsTapped,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: sidebarBg.lighten(0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: dividerColor, width: 1),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: accentColor.withValues(alpha: 0.2),
                        child: Text(
                          _initialsFor(_profile),
                          style: TextStyle(
                            color: accentColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12.0),
                      Expanded(
                        child: Text(
                          _displayNameFor(_profile),
                          style: TextStyle(
                            color: textColorDefault,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(Icons.settings, color: iconColorDefault),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper for consistent leading alignment in ListTiles
  Widget _leadingIconPlaceholder(IconData icon, {required Color iconColor}) {
    return SizedBox(
      width: _iconLeadingWidth + _iconTextSpacing,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Icon(icon, color: iconColor),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {required Color textColor}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _sidebarHorizontalPadding,
        16.0,
        _sidebarHorizontalPadding,
        8.0,
      ),
      child: Text(
        title,
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // Modified to use the common Drawer Item style from main.dart
  Widget _buildDrawerItem(
    IconData icon,
    String title,
    VoidCallback onTap,
    Color iconColor,
    Color textColor, {
    Color? tileBg,
    Color? dividerColor,
    Color? accentColor,
  }) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title, style: TextStyle(color: textColor)),
      onTap: onTap,
      tileColor: tileBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: dividerColor ?? Colors.transparent, width: 1),
      ),
      hoverColor: accentColor?.withValues(alpha: 0.08),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: _sidebarHorizontalPadding,
        vertical: 4,
      ),
      // dense and iconColor/textColor set by ListTileThemeData in main.dart
    );
  }

  Widget _buildStarredItem(
    StoredChat chat,
    Color textColor,
    Color accentColor,
  ) {
    String title = _deriveChatTitle(chat);
    if (title.length > 25) {
      title = '${title.substring(0, 22)}...';
    }
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star, iconColor: accentColor),
      title: Text(title, style: TextStyle(color: textColor)),
      onTap: () => _openChat(chat),
      dense: true,
      tileColor: Colors.transparent,
      contentPadding: const EdgeInsets.only(
        left: _sidebarHorizontalPadding,
        right: 16.0,
      ),
      iconColor: accentColor,
      textColor: textColor,
      trailing: IconButton(
        icon: Icon(Icons.star, color: accentColor),
        tooltip: 'Remove from starred',
        onPressed: () => _toggleStarred(chat),
      ),
    );
  }

  Widget _buildRecentItem(
    StoredChat chat, {
    required int index,
    bool isLast = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
    required Color accentColor,
    required Color iconColor,
    required Color textColor,
  }) {
    bool isSelected = index == widget.selectedChatIndex;
    bool isStarred = chat.isStarred;
    String title = _deriveChatTitle(chat);
    if (title.length > 25) {
      title = '${title.substring(0, 22)}...';
    }
    return ListTile(
      leading: _leadingIconPlaceholder(
        Icons.chat_bubble_outline,
        iconColor: iconColor,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isLast
              ? textColor.withValues(alpha: 0.38)
              : (isSelected ? accentColor : textColor),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.only(
        left: _sidebarHorizontalPadding,
        right: 16.0,
      ),
      tileColor: isSelected ? accentColor.withValues(alpha: 0.1) : null,
      selectedTileColor: accentColor.withValues(alpha: 0.1),
      selectedColor: accentColor,
      iconColor: iconColor,
      textColor: textColor,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              isStarred ? Icons.star : Icons.star_border,
              color: isStarred ? accentColor : iconColor.withValues(alpha: 0.7),
            ),
            tooltip: isStarred ? 'Remove from starred' : 'Add to starred',
            onPressed: () => _toggleStarred(chat),
          ),
          if (onDelete != null)
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                color: iconColor.withValues(alpha: 0.7),
              ),
              tooltip: 'Delete chat',
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }

  // The original _buildSidebarButton is replaced by _buildDrawerItem for consistency
  // as per the new styling. However, for "Projects" if it needs a distinct style,
  // we could re-introduce a version of it or define it directly.
  // For now, it uses _buildDrawerItem.
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

    final List<dynamic> messages = chat['messages'] as List<dynamic>? ?? const [];
    final bool hasMatch = messages.any(
      (dynamic message) => (message as String).contains(query),
    );
    if (hasMatch) {
      matches.add(id);
    }
  }

  return matches;
}
