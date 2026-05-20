import 'package:flutter/material.dart';
import '../demo_data.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFE5E7EB);
    final card = isDark ? const Color(0xFF18181B) : Colors.white;
    final fg = isDark ? const Color(0xFFFAFAFA) : const Color(0xFF18181B);
    final muted = fg.withValues(alpha: 0.55);
    final accent = const Color(0xFF84CC16);

    final pinned = chats.where((c) => c.pinned).toList();
    final rest = chats.where((c) => !c.pinned).toList();

    return Container(
      color: bg,
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          // Bento 1: identity + new chat
          _bento(card, EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: const Text('C',
                          style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                              color: Colors.black)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('chuk',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: fg,
                                  letterSpacing: -0.5)),
                          Text('claude@chuk.dev',
                              style:
                                  TextStyle(fontSize: 10.5, color: muted)),
                        ],
                      ),
                    ),
                    InkWell(
                      onTap: cb.onSettings,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        child:
                            Icon(Icons.tune, size: 16, color: muted),
                      ),
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 8),
          // Bento 2: 2x grid quick actions
          Row(
            children: [
              Expanded(
                child: _bento(
                  accent,
                  const EdgeInsets.all(12),
                  height: 76,
                  onTap: cb.onNewChat,
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(Icons.add, color: Colors.black, size: 18),
                      Text('New chat',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          )),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _bento(
                  card,
                  const EdgeInsets.all(12),
                  height: 76,
                  onTap: cb.onMedia,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(Icons.image_outlined, color: fg, size: 18),
                      Text('Media',
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          )),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Bento 3: search
          _bento(card, EdgeInsets.zero,
              child: TextField(
                onChanged: cb.onSearch,
                style: TextStyle(color: fg, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon:
                      Icon(Icons.search, size: 17, color: muted),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 38, minHeight: 36),
                  hintText: 'Search chats',
                  hintStyle: TextStyle(color: muted, fontSize: 13),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12),
                  border: InputBorder.none,
                ),
              )),
          if (pinned.isNotEmpty) ...[
            const SizedBox(height: 8),
            _bento(card, const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.push_pin,
                            size: 13, color: accent),
                        const SizedBox(width: 6),
                        Text('Pinned',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                color: fg)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final c in pinned) _pinnedRow(c, fg, muted, accent),
                  ],
                )),
          ],
          const SizedBox(height: 8),
          // Bento 4: recent list scrollable
          Expanded(
            child: _bento(card, EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: Row(
                        children: [
                          Text('Recent',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                  color: fg)),
                          const Spacer(),
                          Text('${rest.length}',
                              style:
                                  TextStyle(fontSize: 11, color: muted)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                        itemCount: rest.length,
                        itemBuilder: (_, i) =>
                            _row(rest[i], fg, muted, accent),
                      ),
                    ),
                  ],
                )),
          ),
        ],
      ),
    );
  }

  Widget _bento(Color color, EdgeInsets padding,
      {required Widget child, double? height, VoidCallback? onTap}) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: height,
          padding: padding,
          child: child,
        ),
      ),
    );
  }

  Widget _pinnedRow(DemoChat c, Color fg, Color muted, Color accent) {
    final selected = c.id == selectedId;
    return InkWell(
      onTap: () => cb.onChatTap(c.id),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(c.emoji ?? '•',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: fg)),
            ),
            Text(DemoData.relativeTime(c.time),
                style: TextStyle(fontSize: 10, color: muted)),
          ],
        ),
      ),
    );
  }

  Widget _row(DemoChat c, Color fg, Color muted, Color accent) {
    final selected = c.id == selectedId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => cb.onChatTap(c.id),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(c.emoji ?? '•',
                      style: const TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: fg)),
                      Text(c.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(DemoData.relativeTime(c.time),
                        style: TextStyle(fontSize: 10, color: muted)),
                    if (c.unread > 0)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('${c.unread}',
                            style: const TextStyle(
                                fontSize: 9.5,
                                color: Colors.black,
                                fontWeight: FontWeight.w900)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
