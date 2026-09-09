// lib/widgets/sidebar/sidebar_common.dart
//
// Shared sidebar logic and chrome for SidebarDesktop and SidebarMobile.
//
// The two widgets stay separate — desktop keeps its hover pills, rail rows
// and right-click menus, mobile keeps its bottom sheet and pull-to-refresh —
// but everything that has to look and behave the same lives here, so a
// change lands on both platforms at once.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/update_check_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

/// Horizontal padding shared by sidebar list items and headers.
const double kSidebarHorizontalPadding = 16.0;

/// How many non-pinned chats are added per auto-load page.
const int kSidebarPageSize = 40;

/// Rough height of one chat row — only used to place the sticky header
/// swap points, never for layout.
const double kSidebarEstimatedRowHeight = 32.0;

/// Height of the sticky bucket header. Tall enough for the label's
/// descenders: the y of "Today" and the p of "Pinned" were cut off when
/// the label grew and this did not.
const double kSidebarStickyHeaderHeight = 42.0;

/// Room reserved at the bottom of the list so the last chat row is not
/// hidden behind the floating footer (UpdateBanner + name block).
const double kSidebarFooterReserve = 130.0;

/// The four colors both sidebars paint with. Derived once, in one place,
/// so desktop and mobile cannot drift apart again.
class SidebarPalette {
  /// Full-strength icon color — used for the brand lockup, where the
  /// dimmed [iconColor] would read as washed out.
  final Color iconStrong;
  final Color iconColor;
  final Color textColor;
  final Color accent;
  final Color background;

  const SidebarPalette({
    required this.iconStrong,
    required this.iconColor,
    required this.textColor,
    required this.accent,
    required this.background,
  });

  factory SidebarPalette.of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SidebarPalette(
      iconStrong: theme.resolvedIconColor,
      iconColor: theme.resolvedIconColor.withValues(alpha: 0.7),
      textColor:
          theme.textTheme.bodyMedium?.color ?? theme.colorScheme.onSurface,
      accent: theme.colorScheme.primary,
      background: theme.cardColor.darken(0.02),
    );
  }
}

/// Scroll offset at which a time bucket's inline label reaches the top of
/// the viewport — the point where the sticky overlay swaps its label.
class SidebarBucketBound {
  final String label;
  final double startOffset;
  const SidebarBucketBound(this.label, this.startOffset);
}

/// Strips markdown wrappers, a leading "Title:" and a leading heading marker
/// from a raw chat title, then collapses the whitespace.
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

/// Title shown for a chat in the sidebar.
///
/// Priority: customName > title (from encrypted_title) > previewText.
/// customName is the user-renamed or AI-generated title stored in the
/// payload, title is the fast-loaded decrypted title, previewText is the
/// fallback derived from the first user message.
String deriveSidebarChatTitle(StoredChat chat) {
  final rawTitle = chat.customName ?? chat.title ?? chat.previewText;
  final normalized = normalizeSidebarTitle(rawTitle);
  return normalized.isEmpty ? 'New chat' : normalized;
}

/// Label for the footer name block.
String sidebarDisplayNameFor(ProfileRecord? profile) {
  if (profile == null) return 'Account';
  if (profile.displayName.trim().isNotEmpty) {
    return profile.displayName.trim();
  }
  if (profile.email.trim().isNotEmpty) {
    return profile.email.trim();
  }
  return 'Account';
}

/// The one snack bar shape the sidebars use — floating, rounded, short.
void showSidebarSnackBar(ScaffoldMessengerState messenger, String message) {
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

/// Orange strip shown above the chat list while the device is offline.
class SidebarOfflineBanner extends StatelessWidget {
  final VoidCallback onRetry;

  const SidebarOfflineBanner({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSidebarHorizontalPadding,
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
            const Icon(Icons.cloud_off_rounded, size: 14, color: Colors.orange),
            const SizedBox(width: 6),
            const Expanded(
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
              icon: const Icon(Icons.refresh_rounded,
                  size: 14, color: Colors.orange),
              tooltip: 'Check for updates',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(
                width: 20,
                height: 20,
              ),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// The expanded search input. Both sidebars morph their "Search" nav row
/// into this field; only the surrounding padding and the clear-button
/// behaviour differ.
class SidebarSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Color textColor;
  final Color accent;
  final VoidCallback onClear;
  final EdgeInsets padding;
  final bool autofocus;

  const SidebarSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.textColor,
    required this.accent,
    required this.onClear,
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 10),
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: textColor.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          decoration: InputDecoration(
            hintText: 'Search chats',
            hintStyle: TextStyle(
              color: textColor.withValues(alpha: 0.5),
              fontSize: 13.5,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 17,
              color: textColor.withValues(alpha: 0.6),
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
              onTap: onClear,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: textColor.withValues(alpha: 0.55),
                ),
              ),
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 28,
              minHeight: 28,
            ),
          ),
          style: TextStyle(color: textColor, fontSize: 13.5),
          cursorColor: accent,
        ),
      ),
    );
  }
}

/// Pinned chats, in their own tinted box above the scrolling list.
///
/// A tinted box, not just a label: pinned chats are a place, and the reader
/// should see where that place ends without reading anything.
class SidebarPinnedSection extends StatelessWidget {
  final List<Widget> tiles;
  final Color accent;

  const SidebarPinnedSection({
    super.key,
    required this.tiles,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
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
            count: tiles.length,
            color: accent,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: tiles,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The floating footer: name block, balance block, settings block.
///
/// Each control is its own block — the name, the balance and the gear no
/// longer share one bar. Only faintly translucent (alpha 0.96) so it reads
/// as a near-solid block, uniform across its whole face. No elevation: the
/// blocks end hard at their edge, no shadow bleeding into the background.
/// The balance and the gear both build on floatBg, so this one value sets
/// all three blocks.
class SidebarFooterRow extends StatelessWidget {
  final String name;
  final Color iconColor;
  final Color textColor;
  final Color accent;
  final Color sidebarBg;
  final VoidCallback onSettingsTapped;

  const SidebarFooterRow({
    super.key,
    required this.name,
    required this.iconColor,
    required this.textColor,
    required this.accent,
    required this.sidebarBg,
    required this.onSettingsTapped,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color floatBg = Color.alphaBlend(
      theme.colorScheme.surface.withValues(alpha: 0.62),
      sidebarBg,
    ).withValues(alpha: 0.96);
    const double elevation = 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 18),
      child: Row(
        children: [
          // Name — the widest block, taps through to settings.
          Expanded(
            child: Material(
              color: floatBg,
              borderRadius: BorderRadius.circular(20),
              elevation: elevation,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onSettingsTapped,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Balance — its own accent-tinted floating block.
          Material(
            color: Color.alphaBlend(accent.withValues(alpha: 0.24), floatBg),
            borderRadius: BorderRadius.circular(20),
            elevation: elevation,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: BalanceBadge(
                textStyle: TextStyle(
                  color: accent,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
                placeholderStyle: TextStyle(
                  color: textColor.withValues(alpha: 0.55),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Settings — its own round floating block.
          Material(
            color: floatBg,
            shape: const CircleBorder(),
            elevation: elevation,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onSettingsTapped,
              child: Padding(
                padding: const EdgeInsets.all(11),
                child:
                    Icon(Icons.settings_rounded, size: 22, color: iconColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rename / delete / pin / search / paging machinery both sidebars run.
///
/// Fields live here too, so the mixin is self-contained: the host state adds
/// only what its own platform needs (hover state on desktop, the search
/// debounce and refresh coalescing on mobile).
mixin SidebarStateCommon<T extends StatefulWidget> on State<T> {
  final TextEditingController searchController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final FocusNode searchFocus = FocusNode();

  // Manual "replace-style" sticky section header. Flutter's
  // SliverPersistentHeader(pinned: true) stacks pinned headers on top of
  // each other; we want exactly one header label visible at the top,
  // swapping as the user scrolls past each bucket. We track the accumulated
  // content offset of each bucket and pick the label in the scroll listener.
  final List<SidebarBucketBound> sectionMarkers = <SidebarBucketBound>[];

  String searchQuery = '';
  List<StoredChat> filteredRecentChats = <StoredChat>[];
  int displayLimit = kSidebarPageSize;
  String currentBucket = '';
  ProfileRecord? profile;
  StreamSubscription<String?>? chatUpdatesSub;
  Timer? deleteNotificationTimer;
  String? lastDeletedChatTitle;
  bool isOfflineMode = false;
  bool searchVisible = false;

  /// The host widget's `onChatDeleted` property.
  Future<void> Function(String chatId)? get onChatDeletedCallback;

  /// Re-runs the chat filter and rebuilds. Desktop filters synchronously,
  /// mobile hands the work to an isolate, so each host supplies its own.
  Future<void> applyChatFilter();

  /// Short tag for debug logs, e.g. `SIDEBAR-DESKTOP`.
  String get sidebarLogTag;

  /// Subscribes to chat changes, network status and the scroll position,
  /// and kicks off the background profile and update checks.
  void initSidebarCommon() {
    scrollController.addListener(onScrollForAutoLoad);
    chatUpdatesSub = ChatStorageService.changes.listen((changedChatId) {
      if (!mounted) return;
      if (changedChatId == null) {
        // Bulk change (initial load, sync) — refilter everything.
        unawaited(applyChatFilter());
      } else {
        // Single chat changed — the data is already updated in
        // ChatStorageService, so just rebuild.
        setState(() {});
      }
    });
    // Monitor network status for offline indicators.
    NetworkStatusService.isOnlineListenable.addListener(
      onNetworkStatusChanged,
    );
    unawaited(loadProfile()); // Don't block on profile load.
    // Check for app updates in background.
    unawaited(UpdateCheckService.checkForUpdate());
  }

  /// Tears down everything [initSidebarCommon] set up. The host disposes its
  /// own extras (search debounce, focus listeners) around this call.
  void disposeSidebarCommon() {
    chatUpdatesSub?.cancel();
    deleteNotificationTimer?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      onNetworkStatusChanged,
    );
    scrollController.removeListener(onScrollForAutoLoad);
    scrollController.dispose();
    searchController.dispose();
    searchFocus.dispose();
  }

  /// Shared half of `didUpdateWidget`: rebuild when the selection moved, and
  /// refilter when the underlying saved-chat list grew or shrank while no
  /// search is active (an active search refilters through its own path).
  void handleSidebarWidgetUpdate({required bool selectedChatChanged}) {
    if (selectedChatChanged) {
      if (mounted) setState(() {});
    }
    if (ChatStorageService.savedChats.length != filteredRecentChats.length &&
        searchQuery.isEmpty) {
      unawaited(applyChatFilter());
    }
  }

  // Auto-load older chats when the user scrolls within 240 px of the
  // bottom — no "Show more" button needed; the next page slides in while
  // they're still flicking. Also keeps the sticky overlay header in sync
  // with the topmost-visible bucket.
  void onScrollForAutoLoad() {
    if (!scrollController.hasClients) return;
    final pos = scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 240) {
      final int restLen = filteredRecentChats.where((c) => !c.isStarred).length;
      if (restLen > displayLimit) {
        setState(() {
          displayLimit += kSidebarPageSize;
        });
      }
    }
    refreshCurrentBucket();
  }

  // Picks the bucket label that should be sticky at the top right now,
  // based on the scroll position and the section markers built in
  // [buildSidebarSlivers]. Calls setState only when the label actually
  // changes to avoid extra rebuilds.
  void refreshCurrentBucket() {
    final String found = bucketLabelForCurrentOffset();
    if (found != currentBucket) {
      setState(() => currentBucket = found);
    }
  }

  /// The bucket label matching the current scroll offset, or '' when there
  /// are no buckets at all.
  String bucketLabelForCurrentOffset() {
    if (sectionMarkers.isEmpty) return '';
    final double offset =
        scrollController.hasClients ? scrollController.position.pixels : 0.0;
    String found = sectionMarkers.first.label;
    for (final m in sectionMarkers) {
      if (offset >= m.startOffset) {
        found = m.label;
      } else {
        break;
      }
    }
    return found;
  }

  void toggleSearch() {
    setState(() {
      searchVisible = !searchVisible;
    });
    if (searchVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // A frame later the sidebar may be gone, or the user may already have
        // closed search again — searchFocus is disposed in the first case.
        if (!mounted || !searchVisible) return;
        searchFocus.requestFocus();
      });
    } else {
      searchController.clear();
    }
  }

  void onNetworkStatusChanged() {
    if (!mounted) return;
    setState(() {
      // Update offline status when network changes.
      isOfflineMode = !NetworkStatusService.isOnline;
    });
  }

  Future<void> loadProfile() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    try {
      final record = await const ProfileService().loadOrCreateProfile();
      if (!mounted) return;
      setState(() {
        profile = record;
      });
    } catch (error, stackTrace) {
      // The sidebar shows a fallback label; nothing to recover here.
      if (kDebugMode) {
        debugPrint('[$sidebarLogTag] profile load failed: $error');
        debugPrint('$stackTrace');
      }
    }
  }

  /// Deleting several chats in a row should produce one snack bar, not a
  /// stack of them — the last title wins after a short quiet period.
  void showDebouncedDeleteNotification(String chatTitle) {
    lastDeletedChatTitle = chatTitle;
    deleteNotificationTimer?.cancel();
    deleteNotificationTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final title = lastDeletedChatTitle;
      lastDeletedChatTitle = null;

      final displayTitle = title != null && title.length > 30
          ? '${title.substring(0, 30)}...'
          : title;
      showSidebarSnackBar(
        ScaffoldMessenger.of(context),
        '"$displayTitle" deleted',
      );
    });
  }

  Future<void> toggleStarred(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChatStorageService.setChatStarred(chat.id, !chat.isStarred);
      if (!mounted) return;
      await applyChatFilter();
    } on StateError catch (error) {
      showSidebarSnackBar(messenger, error.message);
    } catch (error) {
      showSidebarSnackBar(messenger, 'Failed to update star: $error');
    }
  }

  Future<void> confirmAndDeleteChat(StoredChat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    // Use the display helper so the dialog shows the same title as the row.
    final derivedTitle = deriveSidebarChatTitle(chat);
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
      // No need to reload — deleteChat() updates local state and fires
      // notifyChanges(). The changes stream listener handles the rebuild.
      if (!mounted) return;
      final onDeleted = onChatDeletedCallback;
      if (onDeleted != null) {
        await onDeleted(chat.id);
      }
      showDebouncedDeleteNotification(chatTitle);
    } on StateError catch (error) {
      showSidebarSnackBar(messenger, error.message);
    } catch (error) {
      showSidebarSnackBar(messenger, 'Failed to delete chat: $error');
    }
  }

  Future<void> renameChatDialog(StoredChat chat) async {
    final controller =
        TextEditingController(text: deriveSidebarChatTitle(chat));
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
        newName == deriveSidebarChatTitle(chat)) {
      return;
    }

    try {
      await ChatStorageService.renameChat(chat.id, newName);
      if (!mounted) return;
      await applyChatFilter();
    } on StateError catch (error) {
      showSidebarSnackBar(messenger, error.message);
    } catch (error) {
      showSidebarSnackBar(messenger, 'Failed to rename chat: $error');
    }
  }

  /// Locked chats cannot be opened with the current password — say why.
  void showLockedChatDialog({required Color accentColor}) {
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

  /// Builds the slivers for the scrolling recent area AND the marker list
  /// the overlay header uses. Layout in scroll content:
  ///
  ///   [TODAY label]      <- content offset 0   (hidden behind overlay
  ///   today chat 1          at scroll 0)
  ///   today chat 2
  ///   ...
  ///   [THIS WEEK label]  <- transition point
  ///   week chats...
  ///   [OLDER label]
  ///   older chats...
  ///   [footer buffer]
  ///
  /// Each bucket's marker is the scroll position at which the next inline
  /// label would appear just below the sticky overlay (viewport y = overlay
  /// height). The bucket label inside the overlay is then [currentBucket].
  List<Widget> buildSidebarSlivers({
    required List<StoredChat> rest,
    required Color iconColor,
    required Color accent,
    required Widget Function(StoredChat chat) tileBuilder,
  }) {
    final List<Widget> slivers = [];
    sectionMarkers.clear();

    if (rest.isEmpty) {
      currentBucket = '';
      // Buffer so the empty-state text isn't hidden by the (now empty)
      // overlay region.
      slivers.add(const SliverToBoxAdapter(
        child: SizedBox(height: kSidebarStickyHeaderHeight),
      ));
      final String msg = searchQuery.isEmpty
          ? 'No recent chats yet.'
          : 'No chats found for "$searchQuery".';
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSidebarHorizontalPadding,
            vertical: 8.0,
          ),
          child: Text(msg,
              style: TextStyle(color: iconColor.withValues(alpha: 0.4))),
        ),
      ));
      slivers.add(const SliverToBoxAdapter(
        child: SizedBox(height: kSidebarFooterReserve),
      ));
      return slivers;
    }

    final int visible = math.min(rest.length, displayLimit);
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
      sectionMarkers.add(SidebarBucketBound(
        label,
        math.max(0.0, cursor - kSidebarStickyHeaderHeight),
      ));
      // Fixed to the overlay's height so the sticky overlay header lands
      // exactly on top of this inline label and never spills onto the first
      // item below it — that overlap was clipping the first row's hover and
      // selection highlight at the top.
      slivers.add(SliverToBoxAdapter(
        child: SizedBox(
          height: kSidebarStickyHeaderHeight,
          child: SbSectionLabel(
            label: label,
            color: accent,
            padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
          ),
        ),
      ));
      cursor += kSidebarStickyHeaderHeight;
      slivers.add(SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) => tileBuilder(chats[i]),
          childCount: chats.length,
        ),
      ));
      cursor += chats.length * kSidebarEstimatedRowHeight;
    }

    addBucket('Today', today);
    addBucket('This week', week);
    addBucket('Older', older);

    currentBucket = bucketLabelForCurrentOffset();

    // Reserve room at the bottom so the last chat row isn't hidden behind
    // the footer overlay (UpdateBanner + name block).
    slivers.add(const SliverToBoxAdapter(
      child: SizedBox(height: kSidebarFooterReserve),
    ));

    return slivers;
  }

  /// The sticky bucket label painted over the top of the scrolling list.
  Widget buildStickyBucketHeader({
    required Color accent,
    required Color sidebarBg,
  }) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Container(
          height: kSidebarStickyHeaderHeight,
          color: sidebarBg,
          child: SbSectionLabel(
            label: currentBucket,
            color: accent,
            padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
          ),
        ),
      ),
    );
  }
}
