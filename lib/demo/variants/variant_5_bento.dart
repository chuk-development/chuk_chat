// Mix E: Pinned bento + flat minimal list + big Media/Workspaces tiles.
import 'package:flutter/material.dart';
import '../app_palette.dart';
import '../demo_data.dart';
import '../shared_widgets.dart';

class VariantBento extends StatelessWidget {
  final List<DemoChat> chats;
  final String? selectedId;
  final SidebarCallbacks cb;
  final bool mobile;
  const VariantBento({
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
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            trailing: IconButton(
              tooltip: 'Settings',
              onPressed: cb.onSettings,
              splashRadius: 16,
              icon: Icon(Icons.tune, size: 18, color: p.muted),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SbNewChatPill(
              onTap: cb.onNewChat,
              wide: true,
              label: 'New chat',
              hint: '⌘N',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: SbQuickTile(
                    icon: Icons.image_outlined,
                    title: 'Media',
                    subtitle: 'Photos & files',
                    onTap: cb.onMedia,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SbQuickTile(
                    icon: Icons.folder_outlined,
                    title: 'Workspaces',
                    subtitle: '${DemoData.projects().length} projects',
                    onTap: cb.onWorkspaces,
                  ),
                ),
              ],
            ),
          ),
          SbSearch(
            onChanged: cb.onSearch,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            radius: 12,
          ),
          if (split.pinned.isNotEmpty) ...[
            const SizedBox(height: 8),
            SbPinnedBento(
              pinned: split.pinned,
              selectedId: selectedId,
              onTap: cb.onChatTap,
            ),
          ],
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
          SbFooter(onSettings: cb.onSettings, showName: false),
        ],
      ),
    );
  }
}
