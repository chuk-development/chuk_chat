// Mix C: Single bento — whole sidebar wrapped in one rounded surface.
import 'package:flutter/material.dart';
import '../app_palette.dart';
import '../demo_data.dart';
import '../shared_widgets.dart';

class VariantDense extends StatelessWidget {
  final List<DemoChat> chats;
  final String? selectedId;
  final SidebarCallbacks cb;
  final bool mobile;
  const VariantDense({
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
      child: Container(
        decoration: BoxDecoration(
          color: p.surfaceLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.hairline),
        ),
        child: Column(
          children: [
            SbBrand(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
              trailing: Row(
                children: [
                  IconButton(
                    tooltip: 'New chat',
                    onPressed: cb.onNewChat,
                    splashRadius: 16,
                    icon: Icon(Icons.edit_outlined, size: 18, color: p.fg),
                  ),
                  IconButton(
                    tooltip: 'Media',
                    onPressed: cb.onMedia,
                    splashRadius: 16,
                    icon: Icon(Icons.image_outlined,
                        size: 18, color: p.muted),
                  ),
                ],
              ),
            ),
            const SbHairline(),
            SbSearch(
              onChanged: cb.onSearch,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              bordered: false,
            ),
            const SbHairline(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 6, bottom: 8),
                children: [
                  if (split.pinned.isNotEmpty) ...[
                    const SbSectionLabel(
                        label: 'Pinned',
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 4)),
                    for (final c in split.pinned)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        child: SbChatRow(
                          chat: c,
                          selected: c.id == selectedId,
                          onTap: () => cb.onChatTap(c.id),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 9),
                          radius: 10,
                        ),
                      ),
                    const SizedBox(height: 4),
                  ],
                  const SbSectionLabel(
                      label: 'Recent',
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4)),
                  for (final c in split.rest)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      child: SbChatRow(
                        chat: c,
                        selected: c.id == selectedId,
                        onTap: () => cb.onChatTap(c.id),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 9),
                        radius: 10,
                      ),
                    ),
                ],
              ),
            ),
            const SbHairline(),
            SbFooter(onSettings: cb.onSettings, showName: false),
          ],
        ),
      ),
    );
  }
}
