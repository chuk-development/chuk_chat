import 'package:flutter/material.dart';
import '../demo_data.dart';

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
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0B0B0E) : const Color(0xFFFAFAFA);
    final fg = isDark ? Colors.white : const Color(0xFF111111);
    final muted = fg.withValues(alpha: 0.55);
    final hair = fg.withValues(alpha: 0.07);

    final grouped = <String, List<DemoChat>>{};
    for (final c in chats) {
      grouped.putIfAbsent(DemoData.groupOf(c.time), () => []).add(c);
    }

    return Container(
      color: bg,
      child: Column(
        children: [
          _header(context, fg, muted, hair),
          _search(context, fg, muted, hair),
          const SizedBox(height: 4),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final entry in grouped.entries) ...[
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(20, 14, 20, 6),
                    child: Text(
                      entry.key.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ),
                  for (final c in entry.value) _row(c, fg, muted, cs),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: hair),
          _footer(fg, muted),
        ],
      ),
    );
  }

  Widget _header(BuildContext ctx, Color fg, Color muted, Color hair) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
      child: Row(
        children: [
          Text('chuk',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                color: fg,
              )),
          const Spacer(),
          _iconBtn(Icons.add, fg, cb.onNewChat, 'New'),
        ],
      ),
    );
  }

  Widget _search(BuildContext ctx, Color fg, Color muted, Color hair) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        onChanged: cb.onSearch,
        style: TextStyle(fontSize: 13.5, color: fg),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Icon(Icons.search, size: 16, color: muted),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
          hintText: 'Search',
          hintStyle: TextStyle(color: muted, fontSize: 13.5),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: hair),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: hair),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: fg.withValues(alpha: 0.25)),
          ),
        ),
      ),
    );
  }

  Widget _row(DemoChat c, Color fg, Color muted, ColorScheme cs) {
    final selected = c.id == selectedId;
    return InkWell(
      onTap: () => cb.onChatTap(c.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        color: selected ? fg.withValues(alpha: 0.05) : Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: Text(
                c.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
              ),
            ),
            if (c.unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: fg,
                  shape: BoxShape.circle,
                ),
              ),
            const SizedBox(width: 8),
            Text(DemoData.relativeTime(c.time),
                style: TextStyle(fontSize: 11, color: muted)),
          ],
        ),
      ),
    );
  }

  Widget _footer(Color fg, Color muted) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 14),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fg.withValues(alpha: 0.08),
            ),
            alignment: Alignment.center,
            child: Text('C',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: fg, fontSize: 13)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('claude@chuk.dev',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: fg)),
          ),
          _iconBtn(Icons.settings_outlined, muted, cb.onSettings, 'Settings',
              small: true),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData i, Color c, VoidCallback onTap, String tip,
      {bool small = false}) {
    return IconButton(
      onPressed: onTap,
      tooltip: tip,
      splashRadius: 18,
      icon: Icon(i, size: small ? 17 : 19, color: c),
    );
  }
}
