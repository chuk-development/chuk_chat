import 'package:flutter/material.dart';
import '../demo_data.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF15171C) : const Color(0xFFF5F6F8);
    final panel = isDark ? const Color(0xFF1B1E25) : Colors.white;
    final fg = isDark ? const Color(0xFFE6E8EE) : const Color(0xFF1A1D24);
    final muted = fg.withValues(alpha: 0.55);
    final hair = fg.withValues(alpha: 0.08);
    final accent = const Color(0xFF22D3EE);

    final grouped = <String, List<DemoChat>>{};
    for (final c in chats) {
      grouped.putIfAbsent(DemoData.groupOf(c.time), () => []).add(c);
    }

    const mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Courier']);

    return Container(
      color: bg,
      child: Column(
        children: [
          Container(
            color: panel,
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              children: [
                Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  alignment: Alignment.center,
                  child: const Text('c',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: Colors.black)),
                ),
                const SizedBox(width: 8),
                Text('chuk', style: TextStyle(
                  color: fg, fontWeight: FontWeight.w700, fontSize: 13,
                )),
                const SizedBox(width: 6),
                Text('v1.0.92',
                    style: mono.copyWith(
                        fontSize: 10, color: muted)),
                const Spacer(),
                _btn(Icons.add, 'New chat (Ctrl+N)', cb.onNewChat, fg, hair),
                const SizedBox(width: 4),
                _btn(Icons.filter_list, 'Filter', () {}, fg, hair),
                const SizedBox(width: 4),
                _btn(Icons.sort, 'Sort', () {}, fg, hair),
              ],
            ),
          ),
          Container(height: 1, color: hair),
          // Search bar
          Container(
            color: panel,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: SizedBox(
              height: 28,
              child: TextField(
                onChanged: cb.onSearch,
                style: mono.copyWith(fontSize: 12, color: fg),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 14, color: muted),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  suffixIcon: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text('⌘K',
                        style: mono.copyWith(fontSize: 10, color: muted)),
                  ),
                  suffixIconConstraints:
                      const BoxConstraints(minWidth: 36, minHeight: 28),
                  hintText: 'filter chats',
                  hintStyle: mono.copyWith(color: muted, fontSize: 12),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 4),
                  filled: true,
                  fillColor: bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: hair),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: hair),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: accent),
                  ),
                ),
              ),
            ),
          ),
          Container(height: 1, color: hair),
          // Tab strip
          Container(
            color: panel,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                _tab('ALL', true, fg, muted, accent),
                _tab('PINNED', false, fg, muted, accent),
                _tab('UNREAD', false, fg, muted, accent),
                _tab('PROJECTS', false, fg, muted, accent),
              ],
            ),
          ),
          Container(height: 1, color: hair),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final entry in grouped.entries) ...[
                  Container(
                    color: bg,
                    padding:
                        const EdgeInsets.fromLTRB(10, 6, 10, 4),
                    child: Row(
                      children: [
                        Text('▸ ${entry.key}',
                            style: mono.copyWith(
                                fontSize: 10.5,
                                color: muted,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5)),
                        const Spacer(),
                        Text('${entry.value.length}',
                            style: mono.copyWith(
                                fontSize: 10.5, color: muted)),
                      ],
                    ),
                  ),
                  for (final c in entry.value)
                    _row(c, fg, muted, hair, accent, mono),
                ],
              ],
            ),
          ),
          Container(height: 1, color: hair),
          // Status bar
          Container(
            height: 22,
            color: panel,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF22C55E),
                  ),
                ),
                const SizedBox(width: 6),
                Text('online',
                    style: mono.copyWith(fontSize: 10, color: muted)),
                const SizedBox(width: 12),
                Text('${chats.length} chats',
                    style: mono.copyWith(fontSize: 10, color: muted)),
                const Spacer(),
                Text('claude@chuk.dev',
                    style: mono.copyWith(fontSize: 10, color: muted)),
                const SizedBox(width: 8),
                InkWell(
                  onTap: cb.onSettings,
                  child: Icon(Icons.settings, size: 13, color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(String label, bool active, Color fg, Color muted, Color accent) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: () {},
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? accent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: active ? accent.withValues(alpha: 0.5) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: active ? accent : muted)),
        ),
      ),
    );
  }

  Widget _btn(IconData i, String tip, VoidCallback onTap, Color fg, Color hair) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 26, height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: hair),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Icon(i, size: 13, color: fg),
        ),
      ),
    );
  }

  Widget _row(DemoChat c, Color fg, Color muted, Color hair, Color accent,
      TextStyle mono) {
    final selected = c.id == selectedId;
    return InkWell(
      onTap: () => cb.onChatTap(c.id),
      hoverColor: fg.withValues(alpha: 0.04),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.10) : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 4, height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                c.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(
                  fontSize: 12,
                  color: fg,
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (c.unread > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text('${c.unread}',
                    style: mono.copyWith(
                        fontSize: 9,
                        color: Colors.black,
                        fontWeight: FontWeight.w900)),
              ),
              const SizedBox(width: 6),
            ],
            Text(DemoData.relativeTime(c.time).padLeft(3),
                style: mono.copyWith(fontSize: 10, color: muted)),
          ],
        ),
      ),
    );
  }
}
