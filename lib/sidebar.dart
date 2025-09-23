// sidebar.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/stripe_billing_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the color extensions

final List<String> _starredChats = ['Book writing Per chapter']; // Kept local for now

class CustomSidebar extends StatefulWidget {
  final Function(int index) onChatItemTapped;
  final Function() onSettingsTapped;
  final Function() onProjectsTapped; // Still passed, though Projects is now a top-level button
  final int selectedChatIndex;
  final bool isCompactMode;

  const CustomSidebar({
    Key? key,
    required this.onChatItemTapped,
    required this.onSettingsTapped,
    required this.onProjectsTapped,
    required this.selectedChatIndex,
    required this.isCompactMode,
  }) : super(key: key);

  @override
  State<CustomSidebar> createState() => _CustomSidebarState();
}

class _CustomSidebarState extends State<CustomSidebar> {
  // Common padding for sidebar list items and headers
  static const double _sidebarHorizontalPadding = 16.0;
  static const double _iconLeadingWidth = 24.0; // Standard icon width for alignment
  static const double _iconTextSpacing = 16.0; // Spacing between icon and text

  @override
  void initState() {
    super.initState();
    _loadChatsAndRefresh();
    StripeBillingService.instance.refreshSubscriptionStatus();
  }

  Future<void> _loadChatsAndRefresh() async {
    await ChatStorageService.loadSavedChatsForSidebar();
    if (mounted) {
      setState(() {});
    }
  }

  String _formatValidUntil(DateTime? date) {
    if (date == null) return '';
    final local = date.toLocal();
    final String month = local.month.toString().padLeft(2, '0');
    final String day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  Future<void> _handleManageSubscription() async {
    try {
      await StripeBillingService.instance.startSubscriptionCheckout();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open billing portal: $error')),
      );
    }
  }

  String _userInitials(String email) {
    final trimmed = email.trim();
    if (trimmed.isEmpty) return 'U';
    final namePart = trimmed.split('@').first;
    final segments = namePart.split(RegExp(r'[._\- ]+')).where((s) => s.isNotEmpty).toList();
    if (segments.length >= 2) {
      return (segments.first[0] + segments.last[0]).toUpperCase();
    }
    if (segments.isNotEmpty) {
      return segments.first.substring(0, 1).toUpperCase();
    }
    return trimmed.substring(0, 1).toUpperCase();
  }

  @override
  void didUpdateWidget(covariant CustomSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access theme colors dynamically
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color sidebarBg = Theme.of(context).cardColor.darken(0.03); // Slightly darker for sidebar itself

    // The height of the top bar is calculated dynamically.
    // In compact mode, "New Chat" and "Projects" buttons are handled outside the sidebar
    // and only visible when the sidebar is open.
    // However, when open, they still need to occupy this space *within* the sidebar
    // so that "Starred" and "Recents" start correctly below them.
    // So, the "160.0" value is retained.
    final double topSpacingForSidebarContent = kTopInitialSpacing +
        kMenuButtonHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight +
        kSpacingBetweenTopButtons +
        kButtonVisualHeight +
        kSpacingBetweenTopButtons; // This is the 160.0 value from main.dart

    return Container(
      color: sidebarBg, // Use dynamically derived sidebar background
      child: Column(
        children: [
          SizedBox(height: topSpacingForSidebarContent), // Uses the calculated constant

          // Starred Section - Fixed
          _buildSectionHeader('Starred', iconFg: iconFg),
          ..._starredChats.map((title) => _buildStarredItem(title, iconFg: iconFg)).toList(),
          Divider(color: Theme.of(context).dividerColor, indent: _sidebarHorizontalPadding, endIndent: _sidebarHorizontalPadding),

          // Recents Section - Scrollable
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero, // Remove default ListView padding
              children: [
                _buildSectionHeader('Recents', iconFg: iconFg),
                _buildSubscriptionTile(iconFg: iconFg, accent: accent),
                if (ChatStorageService.savedChats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: _sidebarHorizontalPadding, vertical: 8.0),
                    child: Text(
                      'No recent chats yet.',
                      style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
                    ),
                  ),
                ...ChatStorageService.savedChats.asMap().entries.map((entry) {
                  final int index = entry.key;
                  final title = entry.value.previewTitle;
                  return _buildRecentItem(
                    title,
                    index: index,
                    isLast: index == ChatStorageService.savedChats.length - 1,
                    onTap: () {
                      widget.onChatItemTapped(index);
                    },
                    accentColor: accent,
                    iconFgColor: iconFg,
                  );
                }).toList(),
                const SizedBox(height: 10), // Small space at the end of scrollable content
              ],
            ),
          ),

          // User profile section at the bottom - Now a PopupMenuButton with precise control
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: PopupMenuButton<String>(
                tooltip: 'User options',
                // This child is what gets rendered, and its tap triggers the menu.
                // It should have the same appearance as the ListTile, but allow for proper tap handling
                // by the PopupMenuButton itself.
                child: InkWell( // Use InkWell here to ensure the ripple effect still works
                  borderRadius: BorderRadius.circular(8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: iconFg.withValues(alpha: 0.3),
                      child: Text(
                        _userInitials(AuthService.currentUser?.email ?? 'U'),
                        style: TextStyle(color: iconFg, fontSize: 16),
                      ),
                    ),
                    title: Text(AuthService.currentUser?.email ?? 'Account', style: TextStyle(color: iconFg)),
                    trailing: Icon(Icons.keyboard_arrow_up, color: iconFg), // Arrow pointing up
                    contentPadding: const EdgeInsets.symmetric(horizontal: _sidebarHorizontalPadding),
                  ),
                ),
                // Custom styling for the popup menu
                color: sidebarBg.lighten(0.05), // Slightly lighter than sidebar background for the menu card itself
                elevation: 8.0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
                ),
                // IMPORTANT: Precise positioning and width control
                // The offset moves the menu relative to the bottom-left corner of the `child`.
                // For a menu of 2 items (approx 40px each + padding), total height ~96px.
                // We want its bottom to be aligned just above the child's top.
                // ListTile height is about 56px.
                // So, offset.dy = -(Menu Height + small gap)
                offset: const Offset(0, -96), // Adjusted offset: 2*40 + 2*8 + 8(gap) = 96
                constraints: const BoxConstraints(
                  minWidth: 180, // Minimum width of the menu
                  maxWidth: 220, // Maximum width, prevents it from taking full sidebar width
                  minHeight: kButtonVisualHeight * 2 + 16, // Ensure it's tall enough for content
                ),
                onSelected: (value) async {
                  if (value == 'settings') {
                    widget.onSettingsTapped(); // Call parent settings handler
                  } else if (value == 'logout') {
                    await AuthService.signOut();
                  } else if (value == 'billing') {
                    await _handleManageSubscription();
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'settings',
                    height: kButtonVisualHeight, // Consistent button height
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.settings, color: iconFg, size: 20),
                        const SizedBox(width: 12),
                        Text('Settings', style: TextStyle(color: iconFg, fontSize: 15)),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'billing',
                    height: kButtonVisualHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.credit_card, color: iconFg, size: 20),
                        const SizedBox(width: 12),
                        Text('Manage billing', style: TextStyle(color: iconFg, fontSize: 15)),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'logout',
                    height: kButtonVisualHeight, // Consistent button height
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(Icons.logout, color: iconFg, size: 20),
                        const SizedBox(width: 12),
                        Text('Logout', style: TextStyle(color: iconFg, fontSize: 15)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper for consistent leading alignment in ListTiles
  Widget _leadingIconPlaceholder(IconData icon, {required Color iconFgColor}) {
    return SizedBox(
      width: _iconLeadingWidth + _iconTextSpacing, // Space for icon + its margin to text
      child: Align(
        alignment: Alignment.centerLeft,
        child: Icon(icon, color: iconFgColor),
      ),
    );
  }

  Widget _buildSubscriptionTile({required Color iconFg, required Color accent}) {
    final accentBg = accent.withValues(alpha: 0.08);
    final accentBorder = accent.withValues(alpha: 0.3);

    return ValueListenableBuilder<bool>(
      valueListenable: StripeBillingService.instance.subscriptionActive,
      builder: (context, active, _) {
        return ValueListenableBuilder<DateTime?>(
          valueListenable: StripeBillingService.instance.subscriptionValidUntil,
          builder: (context, validUntil, __) {
            final subtitle = active
                ? (validUntil != null
                    ? 'Active until ${_formatValidUntil(validUntil)}.'
                    : 'Subscription active.')
                : 'Subscribe to unlock encrypted, cloud-synced chat history.';
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                _sidebarHorizontalPadding,
                8.0,
                _sidebarHorizontalPadding,
                16.0,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: accentBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accentBorder, width: 1),
                ),
                child: ListTile(
                  leading: Icon(
                    active ? Icons.verified_user : Icons.lock_outline,
                    color: iconFg,
                  ),
                  title: Text(
                    active ? 'Subscription active' : 'Subscription inactive',
                    style: TextStyle(color: iconFg, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    subtitle,
                    style: TextStyle(color: iconFg.withValues(alpha: 0.7)),
                  ),
                  trailing: active
                      ? IconButton(
                          tooltip: 'Refresh subscription status',
                          onPressed: StripeBillingService.instance.refreshSubscriptionStatus,
                          icon: Icon(Icons.refresh, color: iconFg),
                        )
                      : FilledButton.tonal(
                          onPressed: _handleManageSubscription,
                          child: const Text('Subscribe'),
                        ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSectionHeader(String title, {required Color iconFg}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_sidebarHorizontalPadding, 16.0, _sidebarHorizontalPadding, 8.0),
      child: Text(
        title,
        style: TextStyle(
            color: iconFg, fontSize: 14, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildStarredItem(String title, {required Color iconFg}) {
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.star_border, iconFgColor: iconFg), // Using a placeholder for alignment
      title: Text(title),
      onTap: () {},
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding), // Only left padding as leading handles space
      iconColor: iconFg,
      textColor: iconFg,
    );
  }

  Widget _buildRecentItem(String title, {int? index, bool isLast = false, VoidCallback? onTap, required Color accentColor, required Color iconFgColor}) {
    bool isSelected = index != null && index == widget.selectedChatIndex;
    return ListTile(
      leading: _leadingIconPlaceholder(Icons.chat_bubble_outline, iconFgColor: iconFgColor), // Placeholder for alignment
      title: Text(
        title,
        style: TextStyle(
          color: isLast ? iconFgColor.withValues(alpha: 0.38) : (isSelected ? accentColor : iconFgColor),
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.only(left: _sidebarHorizontalPadding), // Only left padding as leading handles space
      tileColor: isSelected ? accentColor.withValues(alpha: 0.1) : null,
      selectedTileColor: accentColor.withValues(alpha: 0.1),
      selectedColor: accentColor,
    );
  }
}