// Shared building blocks for all sidebar variants.
// Each variant composes these instead of duplicating row/footer/search/etc.
import 'package:flutter/material.dart';
import 'app_palette.dart';
import 'demo_data.dart';
import 'package:chuk_chat/constants.dart';

/// Brand row: optional logo square + name. Trailing widget on the right.
class SbBrand extends StatelessWidget {
  final Widget? trailing;
  final EdgeInsets padding;
  final String label;
  final bool showLogo;
  const SbBrand({
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 10, 12),
    this.label = 'chuk',
    this.showLogo = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (showLogo) ...[
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: p.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text('C',
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                      color: p.isDark ? Colors.black : Colors.white)),
            ),
            const SizedBox(width: 10),
          ],
          Text(label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: p.fg,
              )),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// Accent pill "New chat" button — used in top-right or as full-width.
class SbNewChatPill extends StatelessWidget {
  final VoidCallback onTap;
  final String label;
  final IconData icon;
  final bool wide;
  final String? hint;
  const SbNewChatPill({
    super.key,
    required this.onTap,
    this.label = 'New',
    this.icon = Icons.edit_outlined,
    this.wide = false,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final onAccent = p.isDark ? Colors.black : Colors.white;
    final pad = wide
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 11)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 7);
    return Material(
      color: p.accent,
      borderRadius: BorderRadius.circular(wide ? 12 : 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(wide ? 12 : 10),
        onTap: onTap,
        child: Padding(
          padding: pad,
          child: Row(
            mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Icon(icon, size: wide ? 17 : 15, color: onAccent),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                    fontSize: wide ? 14 : 12.5,
                    fontWeight: FontWeight.w700,
                    color: onAccent,
                  )),
              if (wide && hint != null) ...[
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: onAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(hint!,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: onAccent)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Generic search field with bordered surface.
class SbSearch extends StatelessWidget {
  final ValueChanged<String> onChanged;
  final String hint;
  final EdgeInsets padding;
  final double radius;
  final bool bordered;
  const SbSearch({
    super.key,
    required this.onChanged,
    this.hint = 'Search old chats...',
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 8),
    this.radius = 10,
    this.bordered = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: padding,
      child: Container(
        decoration: BoxDecoration(
          color: p.surfaceLow,
          borderRadius: BorderRadius.circular(radius),
          border: bordered ? Border.all(color: p.hairline) : null,
        ),
        child: TextField(
          onChanged: onChanged,
          style: TextStyle(fontSize: 14, color: p.fg),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 17, color: p.muted),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 38, minHeight: 38),
            hintText: hint,
            hintStyle: TextStyle(color: p.muted, fontSize: 14),
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }
}

/// Uppercase section header (PINNED, RECENT, etc.).
class SbSectionLabel extends StatelessWidget {
  final String label;
  final int? count;
  final EdgeInsets padding;
  final Color? color;
  const SbSectionLabel({
    super.key,
    required this.label,
    this.count,
    this.padding = const EdgeInsets.fromLTRB(18, 12, 18, 4),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final c = color ?? p.muted;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: c)),
          if (count != null) ...[
            const Spacer(),
            Text('$count',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.withValues(alpha: 0.75))),
          ],
        ],
      ),
    );
  }
}

/// Full-width flat chat row with selection tint, pin icon, unread dot, time.
class SbChatRow extends StatelessWidget {
  final DemoChat chat;
  final bool selected;
  final VoidCallback onTap;
  final EdgeInsets padding;
  final double radius;
  final bool showPin;
  const SbChatRow({
    super.key,
    required this.chat,
    required this.selected,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    this.radius = 0,
    this.showPin = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: selected ? p.accent.withValues(alpha: 0.12) : null,
        borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
      ),
      child: Row(
        children: [
          if (showPin && chat.pinned) ...[
            Icon(Icons.push_pin, size: 13, color: p.accent),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(chat.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: selected ? p.accent : p.fg)),
          ),
          if (chat.unread > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              width: 6, height: 6,
              decoration:
                  BoxDecoration(color: p.accent, shape: BoxShape.circle),
            ),
          const SizedBox(width: 8),
          Text(DemoData.relativeTime(chat.time),
              style: TextStyle(fontSize: 11, color: p.muted)),
        ],
      ),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
      child: content,
    );
  }
}

/// Compact pinned row variant (smaller padding/font, used inside Pinned bento).
class SbPinnedRow extends StatelessWidget {
  final DemoChat chat;
  final bool selected;
  final VoidCallback onTap;
  const SbPinnedRow({
    super.key,
    required this.chat,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? p.accent.withValues(alpha: 0.20)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(chat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? p.accent : p.fg)),
            ),
            Text(DemoData.relativeTime(chat.time),
                style: TextStyle(fontSize: 10.5, color: p.muted)),
          ],
        ),
      ),
    );
  }
}

/// Account footer (avatar + name + email + settings icon).
class SbFooter extends StatelessWidget {
  final VoidCallback onSettings;
  final bool showName;
  const SbFooter({
    super.key,
    required this.onSettings,
    this.showName = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      child: Row(
        children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.accent.withValues(alpha: 0.18),
            ),
            alignment: Alignment.center,
            child: Text('C',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: p.accent)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: showName
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Claude',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: p.fg)),
                      Text('claude@chuk.dev',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: p.muted)),
                    ],
                  )
                : Text('claude@chuk.dev',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: p.fg)),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: onSettings,
            splashRadius: 18,
            icon: Icon(Icons.settings_outlined, size: 18, color: p.muted),
          ),
        ],
      ),
    );
  }
}

/// Sidebar nav row (icon + label, vertically stacked). Like original top stack.
class SbNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final String? hint;
  const SbNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final iconColor = primary ? p.accent : p.fg.withValues(alpha: 0.85);
    final textColor = primary ? p.fg : p.fg.withValues(alpha: 0.92);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: kBorderRadiusRow,
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 19, color: iconColor),
              const SizedBox(width: 14),
              Text(label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight:
                        primary ? FontWeight.w700 : FontWeight.w500,
                    color: textColor,
                  )),
              if (hint != null) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: p.surfaceHigh,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(hint!,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: p.muted)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Generic rounded surface "bento" card.
class SbBento extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Color? color;
  final Color? borderColor;
  final double radius;
  const SbBento({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 10),
    this.margin = EdgeInsets.zero,
    this.color,
    this.borderColor,
    this.radius = 14,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.surfaceLow,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? p.hairline),
      ),
      child: child,
    );
  }
}

/// Accent-tinted pinned bento card with header + rows.
class SbPinnedBento extends StatelessWidget {
  final List<DemoChat> pinned;
  final String? selectedId;
  final ValueChanged<String> onTap;
  final EdgeInsets margin;
  const SbPinnedBento({
    super.key,
    required this.pinned,
    required this.selectedId,
    required this.onTap,
    this.margin = const EdgeInsets.symmetric(horizontal: 10),
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: p.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.accent.withValues(alpha: 0.28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
              child: Row(
                children: [
                  Icon(Icons.push_pin, size: 13, color: p.accent),
                  const SizedBox(width: 6),
                  Text('PINNED',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                          color: p.accent)),
                  const Spacer(),
                  Text('${pinned.length}',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: p.accent.withValues(alpha: 0.7))),
                ],
              ),
            ),
            for (final c in pinned)
              SbPinnedRow(
                chat: c,
                selected: c.id == selectedId,
                onTap: () => onTap(c.id),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bento quick tile (icon + title + subtitle).
class SbQuickTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool primary;
  const SbQuickTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final bg = primary ? p.accent : p.surfaceLow;
    final onBg = primary ? (p.isDark ? Colors.black : Colors.white) : p.fg;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: primary ? null : Border.all(color: p.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30, height: 30,
                decoration: BoxDecoration(
                  color: primary
                      ? onBg.withValues(alpha: 0.18)
                      : p.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Icon(icon,
                    size: 17, color: primary ? onBg : p.accent),
              ),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: onBg)),
              if (subtitle != null) ...[
                const SizedBox(height: 1),
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: primary
                            ? onBg.withValues(alpha: 0.75)
                            : p.muted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Hairline divider matching app palette.
class SbHairline extends StatelessWidget {
  const SbHairline({super.key});
  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Container(height: 1, color: p.hairline);
  }
}

/// Splits chats into pinned + rest. Convenience for variants.
class ChatSplit {
  final List<DemoChat> pinned;
  final List<DemoChat> rest;
  const ChatSplit(this.pinned, this.rest);

  factory ChatSplit.from(List<DemoChat> chats) => ChatSplit(
        chats.where((c) => c.pinned).toList(),
        chats.where((c) => !c.pinned).toList(),
      );
}
