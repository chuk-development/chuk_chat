// Mix D: Full bento — every section is its own card.
import 'package:flutter/material.dart';
import '../app_palette.dart';
import '../demo_data.dart';
import '../shared_widgets.dart';

class VariantPlayful extends StatelessWidget {
  final List<DemoChat> chats;
  final String? selectedId;
  final SidebarCallbacks cb;
  final bool mobile;
  const VariantPlayful({
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
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          SbBento(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    color: p.accent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Text('C',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        color: p.isDark ? Colors.black : Colors.white,
                      )),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('chuk',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: p.fg)),
                      Text('claude@chuk.dev',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: p.muted)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: cb.onSettings,
                  splashRadius: 16,
                  icon: Icon(Icons.settings_outlined,
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
          SbBento(
            padding: EdgeInsets.zero,
            radius: 16,
            child: SbSearch(
              onChanged: cb.onSearch,
              padding: EdgeInsets.zero,
              bordered: false,
              radius: 16,
            ),
          ),
          if (split.pinned.isNotEmpty) ...[
            const SizedBox(height: 8),
            SbPinnedBento(
              pinned: split.pinned,
              selectedId: selectedId,
              onTap: cb.onChatTap,
              margin: EdgeInsets.zero,
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: SbBento(
              padding: EdgeInsets.zero,
              radius: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SbSectionLabel(
                    label: 'Recent',
                    count: split.rest.length,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding:
                          const EdgeInsets.fromLTRB(6, 0, 6, 8),
                      itemCount: split.rest.length,
                      itemBuilder: (_, i) {
                        final c = split.rest[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          child: SbChatRow(
                            chat: c,
                            selected: c.id == selectedId,
                            onTap: () => cb.onChatTap(c.id),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            radius: 10,
                          ),
                        );
                      },
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
}
