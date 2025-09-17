// main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;

import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';
import 'package:ui_elements_flutter/chat/chat_ui.dart';
import 'package:ui_elements_flutter/sidebar.dart';
import 'package:ui_elements_flutter/pages/projects_page.dart';
import 'package:ui_elements_flutter/pages/settings_page.dart';
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

    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: Haupt-Chat-UI, die nach rechts verschoben wird oder verschwindet
          Visibility(
            // Auf kompakten Bildschirmen ist die Chat-UI unsichtbar, wenn die Sidebar geöffnet ist.
            // Ansonsten (großer Bildschirm ODER Sidebar geschlossen) ist sie sichtbar.
            visible: !isCompactMode || !_isSidebarExpanded,
            child: AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              // Verschiebt die Chat-UI um die Breite der Sidebar, wenn Sidebar offen und KEIN Kompaktmodus
              left: (!isCompactMode && _isSidebarExpanded) ? effectiveSidebarWidth : 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: _isSidebarExpanded ? _toggleSidebar : null, // Sidebar schließen bei Tap außerhalb
                child: AbsorbPointer( // Interaktionen mit Chat-UI blockieren, wenn Sidebar offen ist
                  absorbing: _isSidebarExpanded,
                  child: ChukChatUI(
                    key: _chatUIKey,
                    onToggleSidebar: _toggleSidebar, // Dummy, da der Button hier behandelt wird
                    selectedChatIndex: ChatStorageService.selectedChatIndex,
                    isSidebarExpanded: _isSidebarExpanded,
                    isCompactMode: isCompactMode, // Übergebe den Kompaktmodus-Flag an die ChatUI
                  ),
                ),
              ),
            ),
          ),

          // Layer 2: Animierte Sidebar, die über die Chat-UI schiebt
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? 0 : -effectiveSidebarWidth, // Schiebt von links herein
            top: 0,
            bottom: 0,
            width: effectiveSidebarWidth,
            child: CustomSidebar(
              onChatItemTapped: _handleChatTapped,
              onSettingsTapped: _openSettingsPage,
              onProjectsTapped: _openProjectsPage,
              selectedChatIndex: ChatStorageService.selectedChatIndex,
              isCompactMode: isCompactMode, // Übergebe den Kompaktmodus an die Sidebar
            ),
          ),

          // Layer 3: Hamburger-Menü als einfacher IconButton mit gleichem Abstand zur linken Wand
          Positioned(
            top: kTopInitialSpacing,
            left: kFixedLeftPadding,
            child: IconButton(
              icon: Icon(Icons.menu, color: iconFg, size: 24),
              onPressed: _toggleSidebar,
            ),
          ),

          // Layer 4: "chuk.chat"-Titel neben dem Hamburger-Menü
          // Titel ist immer sichtbar, Breite passt sich an Sidebar-Status an.
          Positioned(
            top: kTopInitialSpacing + (kMenuButtonHeight - kButtonVisualHeight) / 2,
            left: kFixedLeftPadding + kMenuButtonHeight + 16, // 16px Abstand vom Hamburger-Menü
            child: InkWell(
              onTap: () {}, // Keine Aktion, rein als Titel
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: kButtonVisualHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      width: _isSidebarExpanded ? 100 : 0, // Text sichtbar, wenn Sidebar offen
                      constraints: BoxConstraints(
                        minWidth: _isSidebarExpanded ? 100 : 0,
                      ),
                      child: ClipRect(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10.0),
                          child: Text(
                            'chuk.chat',
                            style: TextStyle(color: iconFg, fontSize: 16),
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Layer 5: "New Chat"-Button
          // Nur sichtbar, wenn NICHT im Kompaktmodus ODER die Sidebar geöffnet ist.
          if (!isCompactMode || _isSidebarExpanded)
            Positioned(
              top:
                  kTopInitialSpacing + kMenuButtonHeight + kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: InkWell(
                onTap: () {
                  _chatUIKey.currentState?.newChat(); // Ruft die neue Chat-Methode auf
                  if (_isSidebarExpanded) _toggleSidebar(); // Sidebar schließen, wenn neuer Chat erstellt
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: kButtonVisualHeight,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_square, color: iconFg),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: _isSidebarExpanded ? 100 : 0, // Text erweitert sich mit der Sidebar
                        constraints: BoxConstraints(
                          minWidth: _isSidebarExpanded ? 100 : 0,
                        ),
                        child: ClipRect(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12.0),
                            child: Text(
                              'New chat',
                              style: TextStyle(color: iconFg, fontSize: 16),
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Layer 6: "Projects"-Button
          // Nur sichtbar, wenn NICHT im Kompaktmodus ODER die Sidebar geöffnet ist.
          if (!isCompactMode || _isSidebarExpanded)
            Positioned(
              top: kTopInitialSpacing +
                  kMenuButtonHeight +
                  kSpacingBetweenTopButtons +
                  kButtonVisualHeight +
                  kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: InkWell(
                onTap: _openProjectsPage,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: kButtonVisualHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_open, color: iconFg),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: _isSidebarExpanded ? 100 : 0, // Text erweitert sich mit der Sidebar
                        constraints: BoxConstraints(
                          minWidth: _isSidebarExpanded ? 100 : 0,
                        ),
                        child: ClipRect(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12.0),
                            child: Text(
                              'Projects',
                              style: TextStyle(color: iconFg, fontSize: 16),
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}