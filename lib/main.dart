// main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Falls LogicalKeyboardKey benötigt wird
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';
import 'package:ui_elements_flutter/chat/chat_ui.dart';
import 'package:ui_elements_flutter/sidebar.dart';
import 'package:ui_elements_flutter/pages/projects_page.dart';
import 'package:ui_elements_flutter/pages/settings_page.dart';

/* ---------- MAIN ---------- */
void main() => runApp(const ChukChatApp());

class ChukChatApp extends StatelessWidget {
  const ChukChatApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'chuk.chat',
        debugShowCheckedModeBanner: false,
        theme: appTheme,
        home: const RootWrapper(),
      );
}

/* ---------- ROOT WRAPPER ---------- */
class RootWrapper extends StatefulWidget {
  const RootWrapper({Key? key}) : super(key: key);
  @override
  State<RootWrapper> createState() => _RootWrapperState();
}

class _RootWrapperState extends State<RootWrapper> {
  // Sidebar ist standardmäßig geschlossen
  bool _isSidebarExpanded = false;

  final GlobalKey<ChukChatUIState> _chatUIKey = GlobalKey();

  // Konstanten für die Positionierung
  static const double _fixedLeftPadding = 8.0; // Abstand von der linken Wand für alle Icons
  static const double _topInitialSpacing = 16.0; // Abstand vom oberen Bildschirmrand
  static const double _menuButtonHeight = 48.0; // Höhe des IconButtons (Standard 48x48)
  static const double _buttonVisualHeight = 40.0; // Höhe der "New Chat"/"Projects"-Buttons
  static const double _spacingBetweenTopButtons = 8.0; // Abstand zwischen den oberen Elementen

  @override
  void initState() {
    super.initState();
    ChatStorageService.loadChats();
    ChatStorageService.loadSavedChatsForSidebar();
  }

  void _openSettingsPage() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  void _openProjectsPage() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ProjectsPage()));
  }

  void _handleChatTapped(int index) {
    setState(() {
      ChatStorageService.selectedChatIndex = index;
    });
    print('Loading chat at index: $index');
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    const double sidebarVisibleWidth = 280.0; // Breite der angezeigten Sidebar

    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: Haupt-Chat-UI, die nach rechts verschoben wird
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? sidebarVisibleWidth : 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: ChukChatUI(
              key: _chatUIKey,
              onToggleSidebar: () {}, // Dummy, da der Button hier behandelt wird
              selectedChatIndex: ChatStorageService.selectedChatIndex,
              isSidebarExpanded: _isSidebarExpanded,
            ),
          ),

          // Layer 2: Animierte Sidebar, die über die Chat-UI schiebt
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? 0 : -sidebarVisibleWidth, // Schiebt von links herein
            top: 0,
            bottom: 0,
            width: sidebarVisibleWidth,
            child: CustomSidebar(
              onChatItemTapped: _handleChatTapped,
              onSettingsTapped: _openSettingsPage,
              onProjectsTapped: _openProjectsPage,
              selectedChatIndex: ChatStorageService.selectedChatIndex,
            ),
          ),

          // Layer 3: Hamburger-Menü als einfacher IconButton mit gleichem Abstand zur linken Wand
          Positioned(
            top: _topInitialSpacing,
            left: _fixedLeftPadding,
            child: IconButton(
              icon: Icon(Icons.menu, color: iconFg, size: 24),
              onPressed: _toggleSidebar,
            ),
          ),

          // Layer 4: "chuk.chat"-Titel neben dem Hamburger-Menü
          // Hier wurde der linke Offset öfters erhöht (statt +12 nun +16)
          Positioned(
            top: _topInitialSpacing + (_menuButtonHeight - _buttonVisualHeight) / 2,
            left: _fixedLeftPadding + _menuButtonHeight + 16, // 16px Abstand vom Hamburger-Menü
            child: InkWell(
              onTap: () {}, // Keine Aktion, rein als Titel
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: _buttonVisualHeight,
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

          // Layer 5: "New Chat"-Button (immer unter der Menü-/Titelzeile)
          Positioned(
            top:
                _topInitialSpacing + _menuButtonHeight + _spacingBetweenTopButtons,
            left: _fixedLeftPadding,
            child: InkWell(
              onTap: () {
                _chatUIKey.currentState?.newChat(); // Ruft die neue Chat-Methode auf
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: _buttonVisualHeight,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.edit_square, color: iconFg),
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

          // Layer 6: "Projects"-Button (oben-level, unter dem "New Chat"-Button)
          Positioned(
            top: _topInitialSpacing +
                _menuButtonHeight +
                _spacingBetweenTopButtons +
                _buttonVisualHeight +
                _spacingBetweenTopButtons,
            left: _fixedLeftPadding,
            child: InkWell(
              onTap: _openProjectsPage,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: _buttonVisualHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_open, color: iconFg),
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