// main.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;

import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';
import 'package:ui_elements_flutter/pages/projects_page.dart';
import 'package:ui_elements_flutter/pages/settings_page.dart';
import 'package:ui_elements_flutter/pages/root_layout_desktop.dart';
import 'package:ui_elements_flutter/pages/root_layout_mobile.dart';
import 'package:ui_elements_flutter/chat/chat_ui.dart';
import 'package:ui_elements_flutter/utils/color_extensions.dart'; // Import for hex conversion

/* ---------- MAIN ---------- */
void main() => runApp(ChukChatApp()); // Removed const here as it's stateful

class ChukChatApp extends StatefulWidget {
  const ChukChatApp({Key? key}) : super(key: key);

  @override
  State<ChukChatApp> createState() => _ChukChatAppState();
}

class _ChukChatAppState extends State<ChukChatApp> {
  // Theme state managed by ChukChatApp
  Brightness _currentThemeMode = kDefaultThemeMode;
  Color _currentAccentColor = kDefaultAccentColor;
  Color _currentIconFgColor = kDefaultIconFgColor;
  Color _currentBgColor = kDefaultBgColor; // Managed here

  // Key for SharedPreferences
  static const String _kThemeModeKey = 'themeMode';
  static const String _kAccentColorKey = 'accentColor';
  static const String _kIconFgColorKey = 'iconFgColor';
  static const String _kBgColorKey = 'bgColor'; // Key for background color

  @override
  void initState() {
    super.initState();
    _loadThemeSettings();
    ChatStorageService.loadChats();
    ChatStorageService.loadSavedChatsForSidebar();
  }

  Future<void> _loadThemeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentThemeMode = (prefs.getString(_kThemeModeKey) == 'light')
          ? Brightness.light
          : kDefaultThemeMode; // Default to dark if not explicitly light
      _currentAccentColor = ColorExtension.fromHexString(
          prefs.getString(_kAccentColorKey) ?? kDefaultAccentColor.toHexString());
      _currentIconFgColor = ColorExtension.fromHexString(
          prefs.getString(_kIconFgColorKey) ?? kDefaultIconFgColor.toHexString());
      _currentBgColor = ColorExtension.fromHexString(
          prefs.getString(_kBgColorKey) ?? kDefaultBgColor.toHexString());
    });
  }

  // Callbacks for ThemePage to update settings
  void _setThemeMode(Brightness newMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeModeKey, newMode == Brightness.light ? 'light' : 'dark');
    setState(() {
      _currentThemeMode = newMode;
    });
  }

  void _setAccentColor(Color newColor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccentColorKey, newColor.toHexString());
    setState(() {
      _currentAccentColor = newColor;
    });
  }

  void _setIconFgColor(Color newColor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIconFgColorKey, newColor.toHexString());
    setState(() {
      _currentIconFgColor = newColor;
    });
  }

  void _setBgColor(Color newColor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBgColorKey, newColor.toHexString());
    setState(() {
      _currentBgColor = newColor;
    });
  }


  @override
  Widget build(BuildContext context) {
    // Construct the theme data dynamically
    final appTheme = buildAppTheme(
      accent: _currentAccentColor,
      iconFg: _currentIconFgColor,
      bg: _currentBgColor, // Use the current background color
      brightness: _currentThemeMode,
    );

    return MaterialApp(
      title: 'chuk.chat',
      debugShowCheckedModeBanner: false,
      theme: appTheme, // Use the dynamically built theme
      home: RootWrapper(
        currentThemeMode: _currentThemeMode,
        currentAccentColor: _currentAccentColor,
        currentIconFgColor: _currentIconFgColor,
        currentBgColor: _currentBgColor,
        setThemeMode: _setThemeMode,
        setAccentColor: _setAccentColor,
        setIconFgColor: _setIconFgColor,
        setBgColor: _setBgColor, // Pass new callback
      ),
    );
  }
}

/* ---------- ROOT WRAPPER ---------- */
class RootWrapper extends StatefulWidget {
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;
  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor; // New

  const RootWrapper({
    Key? key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor, // New
  }) : super(key: key);

  @override
  State<RootWrapper> createState() => _RootWrapperState();
}

class _RootWrapperState extends State<RootWrapper> {
  // Sidebar ist standardmäßig geschlossen
  bool _isSidebarExpanded = false;

  final GlobalKey<ChukChatUIState> _chatUIKey = GlobalKey();

  void _startNewChat() {
    _chatUIKey.currentState?.newChat();
    if (_isSidebarExpanded) {
      _toggleSidebar();
    }
  }

  @override
  void initState() {
    super.initState();
  }

  void _openSettingsPage() {
    if (_isSidebarExpanded) _toggleSidebar(); // Sidebar schließen, wenn offen
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(
        currentThemeMode: widget.currentThemeMode,
        currentAccentColor: widget.currentAccentColor,
        currentIconFgColor: widget.currentIconFgColor,
        currentBgColor: widget.currentBgColor,
        setThemeMode: widget.setThemeMode,
        setAccentColor: widget.setAccentColor,
        setIconFgColor: widget.setIconFgColor,
        setBgColor: widget.setBgColor, // Pass new callback
      ),
    ));
  }

  void _openProjectsPage() {
    if (_isSidebarExpanded) _toggleSidebar(); // Sidebar schließen, wenn offen
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ProjectsPage()));
  }

  void _handleChatTapped(int index) {
    setState(() {
      ChatStorageService.selectedChatIndex = index;
    });
    print('Loading chat at index: $index');
    if (_isSidebarExpanded) _toggleSidebar(); // Sidebar schließen, wenn Chat ausgewählt
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final Color iconFg = Theme.of(context).iconTheme.color!; // Get iconFg from current theme

    // Definiert, ob der Kompaktmodus aktiv sein soll
    final bool isCompactMode = screenWidth < kCompactModeBreakpoint;

    // Responsive Sidebar-Breite: 80% der Bildschirmbreite auf kleinen Geräten, sonst 280px
    final double sidebarVisibleWidth = isCompactMode ? screenWidth * 0.8 : 280.0;
    // Sicherstellen, dass die Sidebar nicht breiter als der Bildschirm ist
    final double effectiveSidebarWidth = math.min(screenWidth, sidebarVisibleWidth);

    if (isCompactMode) {
      return MobileRootScaffold(
        chatUIKey: _chatUIKey,
        iconColor: iconFg,
        isSidebarExpanded: _isSidebarExpanded,
        onChatTapped: _handleChatTapped,
        onNewChat: _startNewChat,
        onOpenProjects: _openProjectsPage,
        onOpenSettings: _openSettingsPage,
        onToggleSidebar: _toggleSidebar,
        selectedChatIndex: ChatStorageService.selectedChatIndex,
        sidebarWidth: effectiveSidebarWidth,
      );
    }

    return DesktopRootScaffold(
      chatUIKey: _chatUIKey,
      iconColor: iconFg,
      isSidebarExpanded: _isSidebarExpanded,
      onChatTapped: _handleChatTapped,
      onNewChat: _startNewChat,
      onOpenProjects: _openProjectsPage,
      onOpenSettings: _openSettingsPage,
      onToggleSidebar: _toggleSidebar,
      selectedChatIndex: ChatStorageService.selectedChatIndex,
      sidebarWidth: effectiveSidebarWidth,
    );
  }
}