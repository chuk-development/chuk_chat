import 'package:flutter/material.dart';
import '../demo_data.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1A1623) : const Color(0xFFFFF7ED);
    final card = isDark ? const Color(0xFF231B33) : Colors.white;
    final fg = isDark ? const Color(0xFFFDF4FF) : const Color(0xFF1F2937);
    final muted = fg.withValues(alpha: 0.55);

    return Container(
      color: bg,
      child: Column(
        children: [
          _header(fg, muted, card, isDark),
          const SizedBox(height: 8),
          _search(fg, muted, card),
          const SizedBox(height: 10),
          _projects(fg, muted),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                  child: Row(
                    children: [
                      Text('Recent',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: fg)),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFB923C)
                              .withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('${chats.length}',
                            style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFEA580C))),
                      ),
                    ],
                  ),
                ),
                for (final c in chats) _bubble(c, fg, muted, card, isDark),
              ],
            ),
          ),
          _footer(fg, muted, card, isDark),
        ],
      ),
    );
  }

  Widget _header(Color fg, Color muted, Color card, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 12, 4),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFB923C), Color(0xFFF43F5E)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFB923C).withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.chat_bubble_rounded,
                color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hey, Claude 👋',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    )),
                Text('Ready to chat?',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: muted,
                    )),
              ],
            ),
          ),
          Material(
            color: const Color(0xFFFB923C),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: cb.onNewChat,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 9),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, color: Colors.white, size: 16),
                    SizedBox(width: 4),
                    Text('New',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _search(Color fg, Color muted, Color card) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: TextField(
          onChanged: cb.onSearch,
          style: TextStyle(color: fg, fontSize: 13.5),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18, color: muted),
            hintText: 'Find a chat...',
            hintStyle: TextStyle(color: muted, fontSize: 13.5),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }

  Widget _projects(Color fg, Color muted) {
    final projects = DemoData.projects();
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: projects.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          if (i == projects.length) {
            return _projectChip('+', null, muted, fg, dashed: true);
          }
          final p = projects[i];
          return _projectChip(p.name, p.color, muted, fg, count: p.chatCount);
        },
      ),
    );
  }

  Widget _projectChip(String label, Color? color, Color muted, Color fg,
      {int? count, bool dashed = false}) {
    return Container(
      width: 86,
      decoration: BoxDecoration(
        color: (color ?? fg).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: dashed
            ? Border.all(
                color: muted.withValues(alpha: 0.4),
                width: 1.5,
                style: BorderStyle.solid,
              )
            : null,
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(
              color: color ?? Colors.transparent,
              shape: BoxShape.circle,
              border: dashed
                  ? Border.all(color: muted.withValues(alpha: 0.6))
                  : null,
            ),
            alignment: Alignment.center,
            child: dashed
                ? Icon(Icons.add, size: 14, color: muted)
                : null,
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  )),
              if (count != null)
                Text('$count chats',
                    style: TextStyle(fontSize: 10, color: muted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bubble(DemoChat c, Color fg, Color muted, Color card, bool isDark) {
    final selected = c.id == selectedId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? c.accent.withValues(alpha: 0.18) : card,
        borderRadius: BorderRadius.circular(16),
        elevation: selected ? 0 : 1,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => cb.onChatTap(c.id),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: selected
                  ? Border.all(color: c.accent.withValues(alpha: 0.5), width: 1.5)
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(c.emoji ?? '💬',
                      style: const TextStyle(fontSize: 18)),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (c.pinned) ...[
                            Icon(Icons.push_pin,
                                size: 11, color: c.accent),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: fg,
                                )),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(c.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(DemoData.relativeTime(c.time),
                        style: TextStyle(fontSize: 10.5, color: muted)),
                    const SizedBox(height: 4),
                    if (c.unread > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.accent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('${c.unread}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800)),
                      )
                    else
                      const SizedBox(height: 16),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(Color fg, Color muted, Color card, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Stack(
            children: [
              Container(
                width: 34, height: 34,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFFFB923C), Color(0xFFF43F5E)],
                  ),
                ),
                alignment: Alignment.center,
                child: const Text('C',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800)),
              ),
              Positioned(
                bottom: 0, right: 0,
                child: Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E),
                    shape: BoxShape.circle,
                    border: Border.all(color: card, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Claude',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: fg)),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFB923C)
                            .withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('PRO',
                          style: TextStyle(
                              fontSize: 9,
                              color: Color(0xFFEA580C),
                              fontWeight: FontWeight.w900)),
                    ),
                    const SizedBox(width: 6),
                    Text('1,240 credits',
                        style: TextStyle(fontSize: 10.5, color: muted)),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: cb.onSettings,
            icon: Icon(Icons.tune, size: 18, color: fg),
          ),
        ],
      ),
    );
  }
}
