// Mix B: Bento header + classic list.
import 'package:flutter/material.dart';
import '../app_palette.dart';
import '../demo_data.dart';
import '../shared_widgets.dart';

class VariantGlass extends StatelessWidget {
  final List<DemoChat> chats;
  final String? selectedId;
  final SidebarCallbacks cb;
  final bool mobile;
  const VariantGlass({
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
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
            child: Column(
              children: [
                SbBento(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(
                          color: p.accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Icon(Icons.bolt, size: 16, color: p.accent),
                      ),
                      const SizedBox(width: 10),
                      Text('chuk',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: p.fg,
                          )),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Workspaces',
                        onPressed: cb.onWorkspaces,
                        splashRadius: 16,
                        icon: Icon(Icons.folder_outlined,
                            size: 18, color: p.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SbQuickTile(
                        icon: Icons.edit_outlined,
                        title: 'New chat',
                        onTap: cb.onNewChat,
                        primary: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SbQuickTile(
                        icon: Icons.image_outlined,
                        title: 'Media',
                        onTap: cb.onMedia,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SbSearch(
                  onChanged: cb.onSearch,
                  padding: EdgeInsets.zero,
                  radius: 14,
                ),
              ],
            ),
          ),
          const SbHairline(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 6),
              children: [
                if (split.pinned.isNotEmpty) ...[
                  const SbSectionLabel(label: 'Pinned'),
                  for (final c in split.pinned)
                    SbChatRow(
                        chat: c,
                        selected: c.id == selectedId,
                        onTap: () => cb.onChatTap(c.id)),
                  const SizedBox(height: 4),
                ],
                const SbSectionLabel(label: 'Recent'),
                for (final c in split.rest)
                  SbChatRow(
                      chat: c,
                      selected: c.id == selectedId,
                      onTap: () => cb.onChatTap(c.id)),
              ],
            ),
          ),
          const SbHairline(),
          SbFooter(onSettings: cb.onSettings, showName: false),
        ],
      ),
    );
  }
}
