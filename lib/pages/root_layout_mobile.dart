import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/chat/chat_ui.dart';
import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/sidebar.dart';

class MobileRootScaffold extends StatelessWidget {
  final GlobalKey<ChukChatUIState> chatUIKey;
  final bool isSidebarExpanded;
  final double sidebarWidth;
  final VoidCallback onToggleSidebar;
  final VoidCallback onNewChat;
  final VoidCallback onOpenProjects;
  final VoidCallback onOpenSettings;
  final ValueChanged<int> onChatTapped;
  final int selectedChatIndex;
  final Color iconColor;

  const MobileRootScaffold({
    Key? key,
    required this.chatUIKey,
    required this.isSidebarExpanded,
    required this.sidebarWidth,
    required this.onToggleSidebar,
    required this.onNewChat,
    required this.onOpenProjects,
    required this.onOpenSettings,
    required this.onChatTapped,
    required this.selectedChatIndex,
    required this.iconColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: isSidebarExpanded ? 0.0 : 1.0,
              child: GestureDetector(
                onTap: isSidebarExpanded ? onToggleSidebar : null,
                child: AbsorbPointer(
                  absorbing: isSidebarExpanded,
                  child: ChukChatUI(
                    key: chatUIKey,
                    onToggleSidebar: onToggleSidebar,
                    selectedChatIndex: selectedChatIndex,
                    isSidebarExpanded: isSidebarExpanded,
                    isCompactMode: true,
                  ),
                ),
              ),
            ),
          ),
          if (isSidebarExpanded)
            Positioned(
              left: sidebarWidth,
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: onToggleSidebar,
                child: Container(
                  color: Colors.black.withOpacity(0.25),
                ),
              ),
            ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: isSidebarExpanded ? 0 : -sidebarWidth,
            top: 0,
            bottom: 0,
            width: sidebarWidth,
            child: CustomSidebar(
              onChatItemTapped: onChatTapped,
              onSettingsTapped: onOpenSettings,
              onProjectsTapped: onOpenProjects,
              selectedChatIndex: selectedChatIndex,
              isCompactMode: true,
            ),
          ),
          Positioned(
            top: kTopInitialSpacing,
            left: kFixedLeftPadding,
            child: IconButton(
              icon: Icon(Icons.menu, color: iconColor, size: 24),
              onPressed: onToggleSidebar,
            ),
          ),
          Positioned(
            top: kTopInitialSpacing + (kMenuButtonHeight - kButtonVisualHeight) / 2,
            left: kFixedLeftPadding + kMenuButtonHeight + 16,
            child: _AnimatedTitle(
              iconColor: iconColor,
              isSidebarExpanded: isSidebarExpanded,
            ),
          ),
          if (isSidebarExpanded)
            Positioned(
              top: kTopInitialSpacing + kMenuButtonHeight + kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: _TopActionButton(
                icon: Icons.edit_square,
                label: 'New chat',
                iconColor: iconColor,
                showLabel: true,
                onTap: onNewChat,
              ),
            ),
          if (isSidebarExpanded)
            Positioned(
              top: kTopInitialSpacing +
                  kMenuButtonHeight +
                  kSpacingBetweenTopButtons +
                  kButtonVisualHeight +
                  kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: _TopActionButton(
                icon: Icons.folder_open,
                label: 'Projects',
                iconColor: iconColor,
                showLabel: true,
                onTap: onOpenProjects,
              ),
            ),
        ],
      ),
    );
  }
}

class _TopActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconColor;
  final bool showLabel;
  final VoidCallback onTap;

  const _TopActionButton({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.showLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: kButtonVisualHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: iconColor),
            if (showLabel)
              Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: Text(
                  label,
                  style: TextStyle(color: iconColor, fontSize: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedTitle extends StatelessWidget {
  final Color iconColor;
  final bool isSidebarExpanded;

  const _AnimatedTitle({
    required this.iconColor,
    required this.isSidebarExpanded,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: kButtonVisualHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: isSidebarExpanded ? 100 : 0,
              constraints: BoxConstraints(
                minWidth: isSidebarExpanded ? 100 : 0,
              ),
              child: ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: isSidebarExpanded
                      ? Padding(
                          padding: const EdgeInsets.only(left: 10.0),
                          child: Text(
                            'chuk.chat',
                            style: TextStyle(color: iconColor, fontSize: 16),
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
