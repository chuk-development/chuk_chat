import 'package:flutter/material.dart';

import 'demo_data.dart';
import 'variants/variant_1_minimal.dart';
import 'variants/variant_2_glass.dart';
import 'variants/variant_3_dense.dart';
import 'variants/variant_4_playful.dart';
import 'variants/variant_5_bento.dart';

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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sidebar Demos',
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: const Color(0xFF7C3AED),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF7C3AED),
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
  int _variant = 0;
  FrameMode _mode = FrameMode.desktop;
  String? _selected = '1';
  String _query = '';

  static const _variantNames = [
    '1. Minimal',
    '2. Glass',
    '3. Dense Pro',
    '4. Playful',
    '5. Bento',
  ];

  static const _variantDescriptions = [
    'Hairline dividers, monochrome, generous whitespace. Quiet UI.',
    'Translucent panel with blur, gradient mesh background, glow accents.',
    'IDE-style compact rows, monospace timestamps, tabs, status bar.',
    'Rounded bubbles, soft shadows, project chips, friendly greeting.',
    'Bento grid cards: identity, quick actions, pinned, recents in separate tiles.',
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
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = isDark ? const Color(0xFF050507) : const Color(0xFFEDEEF0);
    final stage = isDark ? const Color(0xFF0F0F12) : const Color(0xFFE2E4E8);

    return Scaffold(
      backgroundColor: pageBg,
      body: SafeArea(
        child: Column(
          children: [
            _toolbar(isDark),
            Expanded(
              child: Container(
                color: pageBg,
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: _stage(stage, isDark),
                ),
              ),
            ),
            _description(isDark),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF111114) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.black.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Row(
        children: [
          Text('Sidebar redesign demos',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black,
              )),
          const SizedBox(width: 24),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < _variantNames.length; i++) ...[
                    _tabChip(_variantNames[i], _variant == i, () {
                      setState(() => _variant = i);
                    }, isDark),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          _segmented(isDark),
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Toggle theme',
            onPressed: widget.onToggleTheme,
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabChip(String label, bool selected, VoidCallback onTap, bool isDark) {
    final fg = isDark ? Colors.white : Colors.black;
    return Material(
      color: selected
          ? (isDark ? Colors.white : Colors.black)
          : (isDark ? Colors.white12 : Colors.black12),
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
                    ? (isDark ? Colors.black : Colors.white)
                    : fg.withValues(alpha: 0.85),
              )),
        ),
      ),
    );
  }

  Widget _segmented(bool isDark) {
    Color seg(bool active) => active
        ? (isDark ? Colors.white : Colors.black)
        : Colors.transparent;
    Color txt(bool active) => active
        ? (isDark ? Colors.black : Colors.white)
        : (isDark ? Colors.white : Colors.black);
    Widget seg2(String label, IconData icon, FrameMode m) {
      final active = _mode == m;
      return InkWell(
        onTap: () => setState(() => _mode = m),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: seg(active),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(icon, size: 14, color: txt(active)),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: txt(active))),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black12,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg2('Desktop', Icons.desktop_windows, FrameMode.desktop),
          const SizedBox(width: 2),
          seg2('Mobile', Icons.smartphone, FrameMode.mobile),
        ],
      ),
    );
  }

  Widget _stage(Color stage, bool isDark) {
    if (_mode == FrameMode.desktop) {
      return _desktopFrame(stage, isDark);
    }
    return _mobileFrame(stage, isDark);
  }

  Widget _desktopFrame(Color stage, bool isDark) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 720),
      decoration: BoxDecoration(
        color: stage,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 30,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: [
            _windowChrome(isDark),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: 300, child: _sidebar()),
                  Container(
                    width: 1,
                    color: Colors.black.withValues(alpha: 0.15),
                  ),
                  Expanded(child: _fakeChatArea(isDark)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileFrame(Color stage, bool isDark) {
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
          color: stage,
          child: Column(
            children: [
              Container(
                height: 28,
                alignment: Alignment.center,
                color: Colors.black,
                child: Container(
                  width: 110, height: 22,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(20),
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

  Widget _windowChrome(bool isDark) {
    return Container(
      height: 36,
      color: isDark ? const Color(0xFF1A1A1F) : const Color(0xFFEDEEF0),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _dot(const Color(0xFFEF4444)),
          const SizedBox(width: 6),
          _dot(const Color(0xFFF59E0B)),
          const SizedBox(width: 6),
          _dot(const Color(0xFF22C55E)),
          const Spacer(),
          Text('chuk — Variant ${_variant + 1}',
              style: TextStyle(
                fontSize: 11.5,
                color: isDark ? Colors.white70 : Colors.black54,
              )),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 11, height: 11,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );

  Widget _fakeChatArea(bool isDark) {
    final bg = isDark ? const Color(0xFF111114) : Colors.white;
    final fg = isDark ? Colors.white : Colors.black;
    final muted = fg.withValues(alpha: 0.5);
    final selected = DemoData.chats()
        .firstWhere((c) => c.id == _selected, orElse: () => DemoData.chats().first);
    return Container(
      color: bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: fg.withValues(alpha: 0.08)),
              ),
            ),
            child: Row(
              children: [
                Text(selected.title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: fg)),
                const Spacer(),
                Icon(Icons.more_horiz, color: muted, size: 18),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.chat_bubble_outline,
                        size: 48, color: muted),
                    const SizedBox(height: 12),
                    Text('Chat content (mock)',
                        style: TextStyle(
                            fontSize: 13, color: muted)),
                    const SizedBox(height: 4),
                    Text('Selected: ${selected.title}',
                        style: TextStyle(
                            fontSize: 11, color: muted)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _description(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF111114) : Colors.white,
        border: Border(
          top: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? Colors.white12 : Colors.black12,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(_variantNames[_variant],
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                )),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _variantDescriptions[_variant],
              style: TextStyle(
                fontSize: 12,
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
