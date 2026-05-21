import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'demo_data.dart';
import 'variants/variant_1_minimal.dart';
import 'variants/variant_2_glass.dart';
import 'variants/variant_3_dense.dart';
import 'variants/variant_4_playful.dart';
import 'variants/variant_5_bento.dart';
import 'variants/variant_6_final.dart';

const double kSidebarWidth = 320;

void main() {
  runApp(const SidebarDemoApp());
}

class SidebarDemoApp extends StatefulWidget {
  const SidebarDemoApp({super.key});
  @override
  State<SidebarDemoApp> createState() => _SidebarDemoAppState();
}

class _SidebarDemoAppState extends State<SidebarDemoApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFA8C7FA);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sidebar Mix Demos',
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: accent,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: accent,
      ),
      home: DemoHome(
        themeMode: _themeMode,
        onToggleTheme: () => setState(() {
          _themeMode = _themeMode == ThemeMode.dark
              ? ThemeMode.light
              : ThemeMode.dark;
        }),
      ),
    );
  }
}

enum FrameMode { desktop, mobile }

class DemoHome extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  const DemoHome({
    super.key,
    required this.themeMode,
    required this.onToggleTheme,
  });
  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  int _variant = 5;
  FrameMode _mode = FrameMode.desktop;
  String? _selected = '1';
  String _query = '';

  static const _variantNames = [
    'A · Classic+',
    'B · Bento header',
    'C · Single bento',
    'D · Full bento',
    'E · Pinned bento',
    'F · Final mix',
  ];

  static const _variantDescriptions = [
    'Classic ListTile look refined. Hairline section headers. Closest to current sidebar — just cleaner.',
    'Top: bento cards for identity + New chat + Media + Search. Bottom: classic list with section headers.',
    'Everything wrapped in one rounded surface card. Minimal hairline rows inside. Clean unified container.',
    'Full bento: every section (identity, actions, search, pinned, recents) is its own rounded card.',
    'Flat identity + big accent New chat button. Pinned chats in a small accent-tinted bento card. Flat minimal list of recents.',
    'FINAL: original top-left stack (New chat / Workspaces / Media stacked vertically) + accent Pinned bento + flat classic recents. Mobile keeps New chat top-right.',
  ];

  List<DemoChat> get _chats {
    final all = DemoData.chats();
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all
        .where((c) =>
            c.title.toLowerCase().contains(q) ||
            c.preview.toLowerCase().contains(q))
        .toList();
  }

  SidebarCallbacks _cb() => SidebarCallbacks(
        onChatTap: (id) => setState(() => _selected = id),
        onNewChat: () => _toast('New chat'),
        onSettings: () => _toast('Settings'),
        onMedia: () => _toast('Media'),
        onWorkspaces: () => _toast('Workspaces'),
        onSearch: (q) => setState(() => _query = q),
      );

  void _toast(String msg) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _sidebar() {
    final cb = _cb();
    final isMobile = _mode == FrameMode.mobile;
    switch (_variant) {
      case 0:
        return VariantMinimal(
            chats: _chats, selectedId: _selected, cb: cb, mobile: isMobile);
      case 1:
        return VariantGlass(
            chats: _chats, selectedId: _selected, cb: cb, mobile: isMobile);
      case 2:
        return VariantDense(
            chats: _chats, selectedId: _selected, cb: cb, mobile: isMobile);
      case 3:
        return VariantPlayful(
            chats: _chats, selectedId: _selected, cb: cb, mobile: isMobile);
      case 4:
        return VariantBento(
            chats: _chats, selectedId: _selected, cb: cb, mobile: isMobile);
      case 5:
        return VariantFinal(
            chats: _chats, selectedId: _selected, cb: cb, mobile: isMobile);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            _toolbar(p),
            Expanded(
              child: Container(
                color: p.bg,
                padding: const EdgeInsets.all(20),
                child: Center(child: _stage(p)),
              ),
            ),
            _description(p),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(AppPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: p.surfaceLow,
        border: Border(bottom: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          Text('Sidebar mixes',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.fg,
              )),
          const SizedBox(width: 16),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('${kSidebarWidth.toInt()}px',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: p.accentText,
                )),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < _variantNames.length; i++) ...[
                    _tabChip(_variantNames[i], _variant == i,
                        () => setState(() => _variant = i), p),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          _segmented(p),
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Toggle theme',
            onPressed: widget.onToggleTheme,
            icon: Icon(
              p.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              color: p.fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabChip(
      String label, bool selected, VoidCallback onTap, AppPalette p) {
    return Material(
      color: selected ? p.accent : p.surfaceHigh,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? (p.isDark ? Colors.black : Colors.white)
                    : p.fg.withValues(alpha: 0.85),
              )),
        ),
      ),
    );
  }

  Widget _segmented(AppPalette p) {
    Widget seg(String label, IconData icon, FrameMode m) {
      final active = _mode == m;
      return InkWell(
        onTap: () => setState(() => _mode = m),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 14,
                  color: active
                      ? (p.isDark ? Colors.black : Colors.white)
                      : p.fg),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? (p.isDark ? Colors.black : Colors.white)
                          : p.fg)),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.surfaceHigh,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('Desktop', Icons.desktop_windows, FrameMode.desktop),
          const SizedBox(width: 2),
          seg('Mobile', Icons.smartphone, FrameMode.mobile),
        ],
      ),
    );
  }

  Widget _stage(AppPalette p) {
    return _mode == FrameMode.desktop ? _desktopFrame(p) : _mobileFrame(p);
  }

  Widget _desktopFrame(AppPalette p) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 760),
      decoration: BoxDecoration(
        color: p.surfaceLow,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 36,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: [
            _windowChrome(p),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: kSidebarWidth, child: _sidebar()),
                  Container(width: 1, color: p.hairline),
                  Expanded(child: _mockChatArea(p)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileFrame(AppPalette p) {
    return Container(
      width: 380,
      height: 720,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(40),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 40,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(33),
        child: Container(
          color: p.bg,
          child: Column(
            children: [
              Container(
                height: 24,
                color: Colors.black,
                alignment: Alignment.center,
                child: Container(
                  width: 110, height: 18,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
              Expanded(child: _sidebar()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _windowChrome(AppPalette p) {
    return Container(
      height: 36,
      color: p.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _dot(const Color(0xFFEF4444)),
          const SizedBox(width: 6),
          _dot(const Color(0xFFF59E0B)),
          const SizedBox(width: 6),
          _dot(const Color(0xFF22C55E)),
          const Spacer(),
          Text('chuk — ${_variantNames[_variant]}',
              style: TextStyle(fontSize: 11.5, color: p.muted)),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 11, height: 11,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );

  Widget _mockChatArea(AppPalette p) {
    final selected = DemoData.chats().firstWhere(
        (c) => c.id == _selected,
        orElse: () => DemoData.chats().first);
    return Container(
      color: p.bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.hairline)),
            ),
            child: Row(
              children: [
                Text(selected.title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.fg)),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Claude Sonnet 4.6',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: p.accentText)),
                ),
                const Spacer(),
                Icon(Icons.tune, color: p.muted, size: 18),
                const SizedBox(width: 14),
                Icon(Icons.more_horiz, color: p.muted, size: 20),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              children: [
                _msgUser(
                    'Can you redesign the sidebar so it feels more like the rest of the app?',
                    p),
                const SizedBox(height: 14),
                _msgAssistant(
                    'Here are 5 mixes — blends of bento layout, minimal styling, and the current ListTile look. They all use the app palette (${p.accent.toARGB32().toRadixString(16).substring(2).toUpperCase()}) and a 320px width which matches Gemini\'s current layout. Pick whichever lands best.',
                    p),
              ],
            ),
          ),
          _composer(p),
        ],
      ),
    );
  }

  Widget _msgUser(String text, AppPalette p) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(text,
                style: TextStyle(fontSize: 13.5, color: p.fg, height: 1.4)),
          ),
        ),
      ],
    );
  }

  Widget _msgAssistant(String text, AppPalette p) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.auto_awesome, size: 15, color: p.accent),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(text,
              style: TextStyle(fontSize: 13.5, color: p.fg, height: 1.5)),
        ),
      ],
    );
  }

  Widget _composer(AppPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
      child: Container(
        decoration: BoxDecoration(
          color: p.surfaceLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.hairline),
        ),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.add_circle_outline, color: p.muted, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Ask anything…',
                  style: TextStyle(color: p.muted, fontSize: 14)),
            ),
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: p.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_upward,
                  color: p.isDark ? Colors.black : Colors.white, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _description(AppPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: p.surfaceLow,
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(_variantNames[_variant],
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: p.accentText,
                )),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _variantDescriptions[_variant],
              style: TextStyle(
                fontSize: 12.5,
                color: p.fg.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
