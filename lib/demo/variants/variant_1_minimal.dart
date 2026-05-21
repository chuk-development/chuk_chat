// Mix A: Classic+ — current ListTile look, refined.
import 'package:flutter/material.dart';
import '../app_palette.dart';
import '../demo_data.dart';
import '../shared_widgets.dart';

class VariantMinimal extends StatelessWidget {
  final List<DemoChat> chats;
  final String? selectedId;
  final SidebarCallbacks cb;
  final bool mobile;
  const VariantMinimal({
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
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
            trailing: Row(
              children: [
                IconButton(
                  tooltip: 'Media',
                  onPressed: cb.onMedia,
                  splashRadius: 16,
                  icon: Icon(Icons.image_outlined,
                      size: 18, color: p.fg.withValues(alpha: 0.85)),
                ),
                IconButton(
                  tooltip: 'Workspaces',
                  onPressed: cb.onWorkspaces,
                  splashRadius: 16,
                  icon: Icon(Icons.folder_outlined,
                      size: 18, color: p.fg.withValues(alpha: 0.85)),
                ),
                const SizedBox(width: 4),
                SbNewChatPill(onTap: cb.onNewChat),
              ],
            ),
          ),
          SbSearch(onChanged: cb.onSearch),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              children: [
                if (split.pinned.isNotEmpty) ...[
                  const SbSectionLabel(label: 'Pinned'),
                  for (final c in split.pinned)
                    SbChatRow(
                        chat: c,
                        selected: c.id == selectedId,
                        onTap: () => cb.onChatTap(c.id)),
                  const SizedBox(height: 6),
                ],
                const SbSectionLabel(label: 'Recent chats'),
                for (final c in split.rest)
                  SbChatRow(
                      chat: c,
                      selected: c.id == selectedId,
                      onTap: () => cb.onChatTap(c.id)),
              ],
            ),
          ),
          const SbHairline(),
          SbFooter(onSettings: cb.onSettings),
        ],
      ),
    );
  }
}
