// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'; // For defaultTargetPlatform
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_mobile.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import for hex conversion
import 'package:chuk_chat/utils/grain_overlay.dart';   // Film grain overlay

/* ---------- MAIN ---------- */
void main() => runApp(const ChukChatApp());

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

      home: Builder( // Use Builder to get a context that has MediaQuery
        builder: (context) {
          final double screenWidth = MediaQuery.of(context).size.width;
          final TargetPlatform platform = defaultTargetPlatform;

          // Check if it's a mobile platform (Android/iOS) AND below tablet breakpoint
          final bool isMobilePhone =
              (platform == TargetPlatform.android || platform == TargetPlatform.iOS) &&
              screenWidth < kTabletBreakpoint;

          // If it's a mobile phone, use the mobile wrapper. Otherwise, use desktop wrapper.
          if (isMobilePhone) {
            return RootWrapperMobile(
              currentThemeMode: _currentThemeMode,
              currentAccentColor: _currentAccentColor,
              currentIconFgColor: _currentIconFgColor,
              currentBgColor: _currentBgColor,
              setThemeMode: _setThemeMode,
              setAccentColor: _setAccentColor,
              setIconFgColor: _setIconFgColor,
              setBgColor: _setBgColor,
              grainEnabled: _grainEnabled,
              setGrainEnabled: _setGrainEnabled,
            );
          } else {
            // This applies to desktop (Linux, Windows, macOS), web, and tablets (Android/iOS >= kTabletBreakpoint)
            return RootWrapperDesktop(
              currentThemeMode: _currentThemeMode,
              currentAccentColor: _currentAccentColor,
              currentIconFgColor: _currentIconFgColor,
              currentBgColor: _currentBgColor,
              setThemeMode: _setThemeMode,
              setAccentColor: _setAccentColor,
              setIconFgColor: _setIconFgColor,
              setBgColor: _setBgColor,
              grainEnabled: _grainEnabled,
              setGrainEnabled: _setGrainEnabled,
            );
          }
        },
      ),
    );
  }
}