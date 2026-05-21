// Mix F: Final mix — original top stack + Pinned bento + classic list.
// Desktop: vertical nav stack (New chat / Workspaces / Media) like current app.
// Mobile: New chat sits top-right (matches current mobile UX);
//         Workspaces + Media still shown in the stack below.
// Search lives behind a header icon button to avoid layout shift.
// Account + settings live at the bottom in a footer (both platforms).
import 'package:flutter/material.dart';
import '../app_palette.dart';
import '../demo_data.dart';
import '../shared_widgets.dart';

class VariantFinal extends StatelessWidget {
  final List<DemoChat> chats;
  final String? selectedId;
  final SidebarCallbacks cb;
  final bool mobile;
  const VariantFinal({
    super.key,
    required this.chats,
    required this.selectedId,
    required this.cb,
    required this.mobile,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final split = ChatSplit.from(chats);

    return Container(
      color: p.bg,
      child: Column(
        children: [
          SbBrand(
            label: 'chuk chat',
            showLogo: false,
            padding: EdgeInsets.fromLTRB(16, mobile ? 14 : 18, 10, mobile ? 10 : 14),
            trailing: Row(
              children: [
                _SearchTrigger(onTap: () => cb.onSearch('')),
                if (mobile) ...[
                  const SizedBox(width: 6),
                  SbNewChatPill(onTap: cb.onNewChat),
                ],
              ],
            ),
          ),
          if (!mobile)
            SbNavItem(
              icon: Icons.edit_square,
              label: 'New chat',
              onTap: cb.onNewChat,
              primary: true,
            ),
          SbNavItem(
            icon: Icons.folder_open,
            label: 'Workspaces',
            onTap: cb.onWorkspaces,
          ),
          SbNavItem(
            icon: Icons.image_outlined,
            label: 'Media',
            onTap: cb.onMedia,
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(height: 1, color: p.hairline),
          ),
          const SizedBox(height: 8),
          if (split.pinned.isNotEmpty)
            SbPinnedBento(
              pinned: split.pinned,
              selectedId: selectedId,
              onTap: cb.onChatTap,
            ),
          const SizedBox(height: 10),
          SbSectionLabel(
            label: 'Recent',
            count: split.rest.length,
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: split.rest.length,
              itemBuilder: (_, i) {
                final c = split.rest[i];
                return SbChatRow(
                  chat: c,
                  selected: c.id == selectedId,
                  onTap: () => cb.onChatTap(c.id),
                );
              },
            ),
          ),
          const SbHairline(),
          SbFooter(onSettings: cb.onSettings),
        ],
      ),
    );
  }
}

/// Subtle search icon button. No layout shift, no inline bar.
class _SearchTrigger extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchTrigger({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 14, color: p.muted),
              const SizedBox(width: 6),
              Text('Search',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: p.muted,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}
