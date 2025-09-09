// main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Falls LogicalKeyboardKey benötigt wird
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math; // Import for math.min

import 'package:ui_elements_flutter/constants.dart'; // Import der neuen Konstanten
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

  // Konstanten für die Positionierung sind jetzt in constants.dart global verfügbar

  @override
  void initState() {
    super.initState();
    ChatStorageService.loadChats();
    ChatStorageService.loadSavedChatsForSidebar();
  }

  void _openSettingsPage() {
    if (_isSidebarExpanded) _toggleSidebar(); // Sidebar schließen, wenn offen
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
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