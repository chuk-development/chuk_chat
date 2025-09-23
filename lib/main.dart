// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math' as math;

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/stripe_billing_service.dart';
import 'package:chuk_chat/chat/chat_ui.dart';
import 'package:chuk_chat/pages/auth_gate.dart';
import 'package:chuk_chat/sidebar.dart';
import 'package:chuk_chat/pages/projects_page.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import for hex conversion
import 'package:chuk_chat/utils/grain_overlay.dart';   // Film grain overlay

/* ---------- MAIN ---------- */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    await dotenv.load(fileName: '.env.example');
  }

  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];

  if (supabaseUrl == null || supabaseUrl.isEmpty || supabaseAnonKey == null || supabaseAnonKey.isEmpty) {
    throw const FormatException('Missing Supabase credentials. Update .env with SUPABASE_URL and SUPABASE_ANON_KEY.');
  }

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  StripeBillingService.instance.configureStripe();

  runApp(const ChukChatApp());
}

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

  // Film grain
  bool _grainEnabled = kDefaultGrainEnabled;

  // Keys for SharedPreferences
  static const String _kThemeModeKey = 'themeMode';
  static const String _kAccentColorKey = 'accentColor';
  static const String _kIconFgColorKey = 'iconFgColor';
  static const String _kBgColorKey = 'bgColor';
  static const String _kGrainEnabledKey = 'grainEnabled';

  @override
  void initState() {
    super.initState();
    _loadThemeSettings();
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
      _grainEnabled = prefs.getBool(_kGrainEnabledKey) ?? kDefaultGrainEnabled;
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

  void _setGrainEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGrainEnabledKey, enabled);
    setState(() {
      _grainEnabled = enabled;
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

      // 👇 Apply film grain to EVERY route/page
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            if (_grainEnabled)
              const Positioned.fill(
                child: IgnorePointer(
                  child: GrainOverlay(
                    opacity: 0.10,
                    speedMs: 160,
                    noiseSize: 140,
                    blendMode: BlendMode.overlay,
                  ),
                ),
              ),
          ],
        );
      },

      home: AuthGate(
        child: RootWrapper(
          currentThemeMode: _currentThemeMode,
          currentAccentColor: _currentAccentColor,
          currentIconFgColor: _currentIconFgColor,
          currentBgColor: _currentBgColor,
          setThemeMode: _setThemeMode,
          setAccentColor: _setAccentColor,
          setIconFgColor: _setIconFgColor,
          setBgColor: _setBgColor,
          // film grain
          grainEnabled: _grainEnabled,
          setGrainEnabled: _setGrainEnabled,
        ),
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
  final Function(Color) setBgColor;

  // Film grain
  final bool grainEnabled;
  final Function(bool) setGrainEnabled;

  const RootWrapper({
    Key? key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor,
    required this.grainEnabled,
    required this.setGrainEnabled,
  }) : super(key: key);

  @override
  State<RootWrapper> createState() => _RootWrapperState();
}

class _RootWrapperState extends State<RootWrapper> {
  // Sidebar ist standardmäßig geschlossen
  bool _isSidebarExpanded = false;

  final GlobalKey<ChukChatUIState> _chatUIKey = GlobalKey();

  Future<void> _openSubscriptionCheckout() async {
    try {
      await StripeBillingService.instance.startSubscriptionCheckout();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open billing: $error')),
      );
    }
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
        setBgColor: widget.setBgColor,
        // pass grain toggle through
        grainEnabled: widget.grainEnabled,
        setGrainEnabled: widget.setGrainEnabled,
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
    final double statusBarPadding = MediaQuery.of(context).padding.top;
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
            visible: !isCompactMode || !_isSidebarExpanded,
            child: AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              left: (!isCompactMode && _isSidebarExpanded) ? effectiveSidebarWidth : 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: _isSidebarExpanded ? _toggleSidebar : null,
                child: AbsorbPointer(
                  absorbing: _isSidebarExpanded,
                  child: ChukChatUI(
                    key: _chatUIKey,
                    onToggleSidebar: _toggleSidebar,
                    selectedChatIndex: ChatStorageService.selectedChatIndex,
                    isSidebarExpanded: _isSidebarExpanded,
                    isCompactMode: isCompactMode,
                  ),
                ),
              ),
            ),
          ),

          // Layer 2: Animierte Sidebar, die über die Chat-UI schiebt
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _isSidebarExpanded ? 0 : -effectiveSidebarWidth,
            top: 0,
            bottom: 0,
            width: effectiveSidebarWidth,
            child: CustomSidebar(
              onChatItemTapped: _handleChatTapped,
              onSettingsTapped: _openSettingsPage,
              onProjectsTapped: _openProjectsPage,
              selectedChatIndex: ChatStorageService.selectedChatIndex,
              isCompactMode: isCompactMode,
            ),
          ),

          // Layer 2.5: Subscription reminder banner
          ValueListenableBuilder<bool>(
            valueListenable: StripeBillingService.instance.subscriptionActive,
            builder: (context, active, _) {
              if (active) return const SizedBox.shrink();
              return Positioned(
                top: statusBarPadding + 12,
                left: 16,
                right: 16,
                child: Card(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Unlock encrypted cloud backups by activating your subscription.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: _openSubscriptionCheckout,
                          child: const Text('Subscribe'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),

          // Layer 3: Hamburger-Menü
          Positioned(
            top: kTopInitialSpacing,
            left: kFixedLeftPadding,
            child: IconButton(
              icon: Icon(Icons.menu, color: iconFg, size: 24),
              onPressed: _toggleSidebar,
            ),
          ),

          // Layer 4: Title
          Positioned(
            top: kTopInitialSpacing + (kMenuButtonHeight - kButtonVisualHeight) / 2,
            left: kFixedLeftPadding + kMenuButtonHeight + 16,
            child: InkWell(
              onTap: () {},
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
                      width: _isSidebarExpanded ? 100 : 0,
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

          // Layer 5: New Chat
          if (!isCompactMode || _isSidebarExpanded)
            Positioned(
              top: kTopInitialSpacing + kMenuButtonHeight + kSpacingBetweenTopButtons,
              left: kFixedLeftPadding,
              child: InkWell(
                onTap: () {
                  _chatUIKey.currentState?.newChat();
                  if (_isSidebarExpanded) _toggleSidebar();
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: kButtonVisualHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_square, color: iconFg),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: _isSidebarExpanded ? 100 : 0,
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

          // Layer 6: Projects
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
                        width: _isSidebarExpanded ? 100 : 0,
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
