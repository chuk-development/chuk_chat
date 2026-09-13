// Shared state and behavior for the desktop and mobile sidebars.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/update_check_service.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

const int kSidebarPageSize = 40;

/// Strips generated Markdown decoration from a chat title before display.
String normalizeSidebarTitle(String title) {
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

String deriveSidebarChatTitle(StoredChat chat) {
  final rawTitle = chat.customName ?? chat.title ?? chat.previewText;
  final normalized = normalizeSidebarTitle(rawTitle);
  return normalized.isEmpty ? 'New chat' : normalized;
}

String sidebarDisplayName(ProfileRecord? profile) {
  if (profile == null) return 'Account';
  if (profile.displayName.trim().isNotEmpty) {
    return profile.displayName.trim();
  }
  if (profile.email.trim().isNotEmpty) return profile.email.trim();
  return 'Account';
}

/// The destinations shared by both sidebars, with a platform-owned search
/// entry because mobile morphs that card into a field while desktop does not.
List<Widget> buildSidebarNavigationCards({
  required BuildContext context,
  required bool showWorkspaces,
  required VoidCallback onWorkspacesTapped,
  required VoidCallback onMediaTapped,
  required Widget searchEntry,
}) {
  final l = AppLocalizations.of(context);
  return <Widget>[
    if (kFeatureWorkspaces && showWorkspaces)
      SbNavCard(
        icon: Icons.folder_rounded,
        label: l?.workspaces ?? 'Workspaces',
        onTap: onWorkspacesTapped,
      ),
    if (kFeatureMediaManager)
      SbNavCard(
        icon: Icons.image_rounded,
        label: l?.media ?? 'Media',
        onTap: onMediaTapped,
      ),
    searchEntry,
  ];
}

/// Common state, mutations, and grouped-list construction for both sidebars.
///
/// The hosts retain only their platform-specific filtering, layout, chat tile,
/// and menu behavior.
mixin SidebarStateCommon<T extends StatefulWidget> on State<T> {
  final TextEditingController searchController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final FocusNode searchFocus = FocusNode();
  final Set<String> collapsedGroups = <String>{};

  String searchQuery = '';
  List<StoredChat> filteredRecentChats = <StoredChat>[];
  int displayLimit = kSidebarPageSize;
  ProfileRecord? profile;
  bool isOfflineMode = false;

  StreamSubscription<String?>? _chatUpdatesSubscription;
  Timer? _deleteNotificationTimer;
  String? _lastDeletedChatTitle;

  Future<void> Function(String chatId)? get onChatDeletedCallback;

  /// Desktop filters synchronously; mobile may hand this work to an isolate.
  Future<void> applyChatFilter();

  void initSidebarCommon() {
    scrollController.addListener(onScrollForAutoLoad);
    isOfflineMode = !NetworkStatusService.isOnline;
    unawaited(loadSidebarProfile());
    _chatUpdatesSubscription = ChatStorageService.changes.listen((_) {
      if (!mounted) return;
      // The filtered list holds immutable StoredChat snapshots. A rebuild
      // alone keeps rendering the old title after a single-chat rename.
      unawaited(applyChatFilter());
    });
    NetworkStatusService.isOnlineListenable.addListener(
      onSidebarNetworkStatusChanged,
    );
    unawaited(UpdateCheckService.checkForUpdate());
  }

  void disposeSidebarCommon() {
    final chatUpdatesSubscription = _chatUpdatesSubscription;
    if (chatUpdatesSubscription != null) {
      unawaited(chatUpdatesSubscription.cancel());
    }
    _deleteNotificationTimer?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      onSidebarNetworkStatusChanged,
    );
    scrollController.removeListener(onScrollForAutoLoad);
    scrollController.dispose();
    searchController.dispose();
    searchFocus.dispose();
  }

  void handleSidebarWidgetUpdate({required bool selectedChatChanged}) {
    if (selectedChatChanged && mounted) setState(() {});
    if (ChatStorageService.savedChats.length != filteredRecentChats.length &&
        searchQuery.isEmpty) {
      unawaited(applyChatFilter());
    }
  }

  void onScrollForAutoLoad() {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    if (position.pixels < position.maxScrollExtent - 240) return;

    final restLength = filteredRecentChats.where((c) => !c.isStarred).length;
    if (restLength <= displayLimit) return;
    setState(() => displayLimit += kSidebarPageSize);
  }

  void toggleSidebarGroup(String label) {
    setState(() {
      if (!collapsedGroups.remove(label)) collapsedGroups.add(label);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onScrollForAutoLoad();
    });
  }

  void onSidebarNetworkStatusChanged() {
    if (!mounted) return;
    setState(() => isOfflineMode = !NetworkStatusService.isOnline);
  }

  Future<void> loadSidebarProfile() async {
    if (!SupabaseService.isInitialized) return;
    final userId = SupabaseService.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final record = await const ProfileService().loadOrCreateProfile();
      if (!mounted || SupabaseService.auth.currentUser?.id != userId) return;
      setState(() => profile = record);
    } catch (_) {
      // The account row can use its fallback label when profile loading fails.
    }
  }

  void showSidebarNotification(
    ScaffoldMessengerState messenger,
    String message, {
    AppNotificationKind kind = AppNotificationKind.info,
  }) {
    if (!mounted) return;
    AppNotifications.showOn(messenger, message, kind: kind);
  }

  Future<void> toggleSidebarChatStarred(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChatStorageService.setChatStarred(chat.id, !chat.isStarred);
    } on StateError catch (error) {
      showSidebarNotification(messenger, error.message);
      return;
    } catch (error) {
      showSidebarNotification(
        messenger,
        'Failed to update star: $error',
        kind: AppNotificationKind.error,
      );
      return;
    }

    if (!mounted) return;
    await _refreshSidebarAfterMutation(messenger, 'Star update');
  }

  Future<void> renameSidebarChat(StoredChat chat) async {
    final controller = TextEditingController(
      text: deriveSidebarChatTitle(chat),
    );
    final messenger = ScaffoldMessenger.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
      ),
    );
    controller.dispose();

    if (newName == null ||
        newName.isEmpty ||
        newName == deriveSidebarChatTitle(chat)) {
      return;
    }

    try {
      await ChatStorageService.renameChat(chat.id, newName);
    } on StateError catch (error) {
      showSidebarNotification(messenger, error.message);
      return;
    } catch (error) {
      showSidebarNotification(
        messenger,
        'Failed to rename chat: $error',
        kind: AppNotificationKind.error,
      );
      return;
    }

    if (!mounted) return;
    await _refreshSidebarAfterMutation(messenger, 'Rename');
  }

  Future<void> confirmAndDeleteSidebarChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    final derivedTitle = deriveSidebarChatTitle(chat);
    final chatTitle = derivedTitle.length > 40
        ? '${derivedTitle.substring(0, 40)}...'
        : derivedTitle;
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
      ),
    );
    if (shouldDelete != true) return;

    try {
      await ChatStorageService.deleteChat(chat.id);
    } on StateError catch (error) {
      showSidebarNotification(messenger, error.message);
      return;
    } catch (error) {
      showSidebarNotification(
        messenger,
        'Failed to delete chat: $error',
        kind: AppNotificationKind.error,
      );
      return;
    }

    if (!mounted) return;
    try {
      await onChatDeletedCallback?.call(chat.id);
    } catch (error) {
      showSidebarNotification(
        messenger,
        'Chat deleted, but the view failed to refresh: $error',
        kind: AppNotificationKind.error,
      );
    }
    if (!mounted) return;
    _showDebouncedDeleteNotification(chatTitle);
  }

  Future<void> _refreshSidebarAfterMutation(
    ScaffoldMessengerState messenger,
    String action,
  ) async {
    try {
      await applyChatFilter();
    } catch (error) {
      showSidebarNotification(
        messenger,
        '$action saved, but the chat list failed to refresh: $error',
        kind: AppNotificationKind.error,
      );
    }
  }

  void _showDebouncedDeleteNotification(String chatTitle) {
    _lastDeletedChatTitle = chatTitle;
    _deleteNotificationTimer?.cancel();
    _deleteNotificationTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final String title = _lastDeletedChatTitle ?? chatTitle;
      _lastDeletedChatTitle = null;
      final displayTitle = title.length > 30
          ? '${title.substring(0, 30)}...'
          : title;
      showSidebarNotification(
        ScaffoldMessenger.of(context),
        '"$displayTitle" deleted',
      );
    });
  }

  void showLockedSidebarChatDialog({required Color accentColor}) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Row(
            children: [
              AppIcon(Icons.lock, color: accentColor, size: 20),
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
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> buildSidebarChatSlivers({
    required List<Widget> leadingSlivers,
    required Color accent,
    required Color emptyTextColor,
    required Widget Function(StoredChat chat, int index, int length)
    itemBuilder,
  }) {
    final pinnedChats = filteredRecentChats.where((c) => c.isStarred).toList();
    final restChats = filteredRecentChats.where((c) => !c.isStarred).toList();
    final slivers = <Widget>[...leadingSlivers];

    if (pinnedChats.isEmpty && restChats.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              searchQuery.isEmpty
                  ? 'No recent chats yet.'
                  : 'No chats found for "$searchQuery".',
              style: TextStyle(color: emptyTextColor),
            ),
          ),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
      return slivers;
    }

    if (pinnedChats.isNotEmpty) {
      slivers.addAll(
        _buildSidebarGroup(
          AppLocalizations.of(context)?.pinned ?? 'Pinned',
          pinnedChats,
          itemBuilder,
        ),
      );
    }

    final localizations = MaterialLocalizations.of(context);
    final l = AppLocalizations.of(context);
    final groups = sbGroupByTime<StoredChat>(
      restChats,
      (chat) => chat.updatedAt ?? chat.createdAt,
      monthLabel: localizations.formatMonthYear,
      todayLabel: l?.today ?? 'Today',
      weekLabel: l?.thisWeek ?? 'This week',
      thisMonthLabel: l?.thisMonth ?? 'This month',
    );
    var budget = displayLimit;
    for (final group in groups) {
      final folded = collapsedGroups.contains(group.label);
      if (!folded && budget <= 0) break;
      final shown = folded ? 0 : math.min(budget, group.items.length);
      budget -= shown;
      slivers.addAll(
        _buildSidebarGroup(
          group.label,
          group.items.take(shown).toList(),
          itemBuilder,
          total: group.items.length,
        ),
      );
    }

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
    return slivers;
  }

  List<Widget> _buildSidebarGroup(
    String label,
    List<StoredChat> chats,
    Widget Function(StoredChat chat, int index, int length) itemBuilder, {
    int? total,
  }) {
    final collapsed = collapsedGroups.contains(label);
    return <Widget>[
      SliverToBoxAdapter(
        child: SbGroupHeader(
          label: label,
          count: total ?? chats.length,
          collapsed: collapsed,
          onToggle: () => toggleSidebarGroup(label),
        ),
      ),
      if (!collapsed)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => itemBuilder(chats[index], index, chats.length),
            childCount: chats.length,
          ),
        ),
    ];
  }
}
