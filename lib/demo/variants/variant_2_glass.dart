import 'dart:ui';
import 'package:flutter/material.dart';
import '../demo_data.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? const Color(0xFF0E0B1A) : const Color(0xFFEDE9FE);
    final fg = isDark ? Colors.white : const Color(0xFF1E1B4B);
    final muted = fg.withValues(alpha: 0.6);

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? const [Color(0xFF1E1B4B), Color(0xFF0F172A), Color(0xFF312E81)]
                  : const [Color(0xFFE0E7FF), Color(0xFFFCE7F3), Color(0xFFDDD6FE)],
            ),
          ),
        ),
        Positioned(
          top: -40, left: -40,
          child: _blob(220, const Color(0xFF7C3AED).withValues(alpha: 0.55)),
        ),
        Positioned(
          bottom: -60, right: -50,
          child: _blob(260, const Color(0xFFEC4899).withValues(alpha: 0.45)),
        ),
        Positioned(
          top: 200, right: -80,
          child: _blob(200, const Color(0xFF06B6D4).withValues(alpha: 0.4)),
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: Container(
            color: base.withValues(alpha: 0.35),
            child: Column(
              children: [
                _header(fg, muted),
                _search(fg, muted, isDark),
                const SizedBox(height: 6),
                Expanded(
                  child: ListView(
                    padding:
                        const EdgeInsets.fromLTRB(10, 4, 10, 8),
                    children: [
                      for (final c in chats) _card(c, fg, muted, isDark),
                    ],
                  ),
                ),
                _footer(fg, muted, isDark),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _blob(double s, Color c) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c,
        ),
      );

  Widget _header(Color fg, Color muted) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 10, 12),
      child: Row(
        children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              gradient: const LinearGradient(
                colors: [Color(0xFF7C3AED), Color(0xFFEC4899)],
              ),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.bolt, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text('chuk',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: fg,
              )),
          const Spacer(),
          _gButton(Icons.add, 'New chat', cb.onNewChat, fg),
        ],
      ),
    );
  }

  Widget _gButton(IconData i, String tip, VoidCallback onTap, Color fg) {
    return Material(
      color: Colors.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Tooltip(
          message: tip,
          child: Container(
            width: 34, height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25), width: 1),
            ),
            child: Icon(i, size: 18, color: fg),
          ),
        ),
      ),
    );
  }

  Widget _search(Color fg, Color muted, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: TextField(
              onChanged: cb.onSearch,
              style: TextStyle(fontSize: 13.5, color: fg),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 17, color: muted),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 38, minHeight: 38),
                hintText: 'Search chats...',
                hintStyle: TextStyle(color: muted, fontSize: 13.5),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: InputBorder.none,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(DemoChat c, Color fg, Color muted, bool isDark) {
    final selected = c.id == selectedId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Material(
            color: Colors.white
                .withValues(alpha: selected ? (isDark ? 0.16 : 0.55) : (isDark ? 0.05 : 0.25)),
            child: InkWell(
              onTap: () => cb.onChatTap(c.id),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white
                        .withValues(alpha: selected ? 0.45 : 0.18),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 30, height: 30,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            c.accent,
                            c.accent.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        c.emoji ?? c.title.characters.first,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: fg,
                                  ),
                                ),
                              ),
                              Text(DemoData.relativeTime(c.time),
                                  style: TextStyle(
                                      fontSize: 10.5, color: muted)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(c.preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5, color: muted)),
                        ],
                      ),
                    ),
                    if (c.unread > 0)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF7C3AED), Color(0xFFEC4899)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('${c.unread}',
                            style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(Color fg, Color muted, bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: isDark ? 0.1 : 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFF7C3AED), Color(0xFFEC4899)],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Text('C',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Claude',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: fg)),
                      Text('claude@chuk.dev',
                          style: TextStyle(fontSize: 11, color: muted)),
                    ],
                  ),
                ),
                IconButton(
                  splashRadius: 18,
                  onPressed: cb.onSettings,
                  icon: Icon(Icons.settings_outlined,
                      size: 18, color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
