// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For defaultTargetPlatform
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_mobile.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import for hex conversion
import 'package:chuk_chat/utils/grain_overlay.dart'; // Film grain overlay
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/theme_settings_service.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _InitialThemeData {
  const _InitialThemeData({
    required this.themeMode,
    required this.accentColor,
    required this.iconColor,
    required this.backgroundColor,
    required this.grainEnabled,
    required this.loadedFromSupabase,
  });

  final Brightness themeMode;
  final Color accentColor;
  final Color iconColor;
  final Color backgroundColor;
  final bool grainEnabled;
  final bool loadedFromSupabase;
}

Future<_InitialThemeData> _bootstrapThemeSettings() async {
  final prefs = await SharedPreferences.getInstance();

  Brightness themeMode =
      (prefs.getString(_ChukChatAppState._kThemeModeKey) == 'light')
      ? Brightness.light
      : kDefaultThemeMode;
  Color accentColor = ColorExtension.fromHexString(
    prefs.getString(_ChukChatAppState._kAccentColorKey) ??
        kDefaultAccentColor.toHexString(),
  );
  Color iconColor = ColorExtension.fromHexString(
    prefs.getString(_ChukChatAppState._kIconFgColorKey) ??
        kDefaultIconFgColor.toHexString(),
  );
  Color backgroundColor = ColorExtension.fromHexString(
    prefs.getString(_ChukChatAppState._kBgColorKey) ??
        kDefaultBgColor.toHexString(),
  );
  bool grainEnabled =
      prefs.getBool(_ChukChatAppState._kGrainEnabledKey) ??
      kDefaultGrainEnabled;

  bool loadedFromSupabase = false;

  if (SupabaseService.auth.currentSession != null) {
    try {
      final settings = await const ThemeSettingsService().loadOrCreate();
      themeMode = settings.themeMode;
      accentColor = settings.accentColor;
      iconColor = settings.iconColor;
      backgroundColor = settings.backgroundColor;
      grainEnabled = settings.grainEnabled;
      loadedFromSupabase = true;

      await prefs.setString(
        _ChukChatAppState._kThemeModeKey,
        themeMode == Brightness.light ? 'light' : 'dark',
      );
      await prefs.setString(
        _ChukChatAppState._kAccentColorKey,
        accentColor.toHexString(),
      );
      await prefs.setString(
        _ChukChatAppState._kIconFgColorKey,
        iconColor.toHexString(),
      );
      await prefs.setString(
        _ChukChatAppState._kBgColorKey,
        backgroundColor.toHexString(),
      );
      await prefs.setBool(_ChukChatAppState._kGrainEnabledKey, grainEnabled);
    } catch (_) {
      // Ignore remote load errors and fall back to locally stored values.
    }
  }

  return _InitialThemeData(
    themeMode: themeMode,
    accentColor: accentColor,
    iconColor: iconColor,
    backgroundColor: backgroundColor,
    grainEnabled: grainEnabled,
    loadedFromSupabase: loadedFromSupabase,
  );
}

/* ---------- MAIN ---------- */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.initialize();
  if (SupabaseService.auth.currentSession != null) {
    try {
      await EncryptionService.tryLoadKey();
    } catch (error, stackTrace) {
      debugPrint('Initial encryption key load failed: $error');
      debugPrint('$stackTrace');
      await EncryptionService.clearKey();
    }
  }
  final initialTheme = await _bootstrapThemeSettings();
  runApp(ChukChatApp(initialTheme: initialTheme));
}

class ChukChatApp extends StatefulWidget {
  const ChukChatApp({Key? key, required this.initialTheme}) : super(key: key);

  final _InitialThemeData initialTheme;

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

  StreamSubscription<AuthState>? _authSubscription;
  bool _hasAppliedSupabaseTheme = false;

  @override
  void initState() {
    super.initState();
    final initialTheme = widget.initialTheme;
    _currentThemeMode = initialTheme.themeMode;
    _currentAccentColor = initialTheme.accentColor;
    _currentIconFgColor = initialTheme.iconColor;
    _currentBgColor = initialTheme.backgroundColor;
    _grainEnabled = initialTheme.grainEnabled;
    _hasAppliedSupabaseTheme = initialTheme.loadedFromSupabase;

    unawaited(ChatStorageService.loadSavedChatsForSidebar());
    _authSubscription = SupabaseService.auth.onAuthStateChange.listen((
      event,
    ) async {
      if (event.session != null) {
        try {
          final hasKey = await EncryptionService.tryLoadKey();
          if (hasKey) {
            try {
              await ChatStorageService.loadSavedChatsForSidebar();
            } catch (error, stackTrace) {
              debugPrint('Chat loading failed: $error');
              debugPrint('$stackTrace');
              // Keep the key so a transient chat load issue does not force re-authentication.
            }
          } else {
            await EncryptionService.clearKey();
            ChatStorageService.reset();
          }
        } catch (error, stackTrace) {
          debugPrint('Encryption key load failed: $error');
          debugPrint('$stackTrace');
          await EncryptionService.clearKey();
          ChatStorageService.reset();
        }
        _loadThemeSettingsFromSupabase();
      } else {
        unawaited(EncryptionService.clearKey());
        ChatStorageService.reset();
        _hasAppliedSupabaseTheme = false;
        _loadThemeSettingsFromPrefs();
      }
    });

    if (SupabaseService.auth.currentSession != null &&
        !_hasAppliedSupabaseTheme) {
      _loadThemeSettingsFromSupabase();
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadThemeSettingsFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (SupabaseService.auth.currentSession != null &&
        _hasAppliedSupabaseTheme) {
      return;
    }
    setState(() {
      _currentThemeMode = (prefs.getString(_kThemeModeKey) == 'light')
          ? Brightness.light
          : kDefaultThemeMode; // Default to dark if not explicitly light
      _currentAccentColor = ColorExtension.fromHexString(
        prefs.getString(_kAccentColorKey) ?? kDefaultAccentColor.toHexString(),
      );
      _currentIconFgColor = ColorExtension.fromHexString(
        prefs.getString(_kIconFgColorKey) ?? kDefaultIconFgColor.toHexString(),
      );
      _currentBgColor = ColorExtension.fromHexString(
        prefs.getString(_kBgColorKey) ?? kDefaultBgColor.toHexString(),
      );
      _grainEnabled = prefs.getBool(_kGrainEnabledKey) ?? kDefaultGrainEnabled;
    });
  }

  // Callbacks for ThemePage to update settings
  void _setThemeMode(Brightness newMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kThemeModeKey,
      newMode == Brightness.light ? 'light' : 'dark',
    );
    setState(() {
      _currentThemeMode = newMode;
    });
    await _syncThemeSettings();
  }

  void _setAccentColor(Color newColor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccentColorKey, newColor.toHexString());
    setState(() {
      _currentAccentColor = newColor;
    });
    await _syncThemeSettings();
  }

  void _setIconFgColor(Color newColor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIconFgColorKey, newColor.toHexString());
    setState(() {
      _currentIconFgColor = newColor;
    });
    await _syncThemeSettings();
  }

  void _setBgColor(Color newColor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBgColorKey, newColor.toHexString());
    setState(() {
      _currentBgColor = newColor;
    });
    await _syncThemeSettings();
  }

  void _setGrainEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGrainEnabledKey, enabled);
    setState(() {
      _grainEnabled = enabled;
    });
    await _syncThemeSettings();
  }

  Future<void> _loadThemeSettingsFromSupabase() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    try {
      final settings = await const ThemeSettingsService().loadOrCreate();
      if (!mounted) return;
      setState(() {
        _currentThemeMode = settings.themeMode;
        _currentAccentColor = settings.accentColor;
        _currentIconFgColor = settings.iconColor;
        _currentBgColor = settings.backgroundColor;
        _grainEnabled = settings.grainEnabled;
        _hasAppliedSupabaseTheme = true;
      });
      await _persistThemeSettingsToPrefs();
    } catch (_) {
      // Ignore remote load errors; keep existing local settings.
    }
  }

  Future<void> _persistThemeSettingsToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kThemeModeKey,
      _currentThemeMode == Brightness.light ? 'light' : 'dark',
    );
    await prefs.setString(_kAccentColorKey, _currentAccentColor.toHexString());
    await prefs.setString(_kIconFgColorKey, _currentIconFgColor.toHexString());
    await prefs.setString(_kBgColorKey, _currentBgColor.toHexString());
    await prefs.setBool(_kGrainEnabledKey, _grainEnabled);
  }

  Future<void> _syncThemeSettings() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    final settings = ThemeSettings(
      userId: user.id,
      themeMode: _currentThemeMode,
      accentColor: _currentAccentColor,
      iconColor: _currentIconFgColor,
      backgroundColor: _currentBgColor,
      grainEnabled: _grainEnabled,
    );

    try {
      await const ThemeSettingsService().save(settings);
      await _persistThemeSettingsToPrefs();
    } catch (_) {
      // Ignore sync failures; preferences remain updated locally.
    }
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
        loadingBuilder: (context) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
        signedOutBuilder: (context) => const LoginPage(),
        signedInBuilder: (context) {
          return Builder(
            builder: (context) {
              final double screenWidth = MediaQuery.of(context).size.width;
              final TargetPlatform platform = defaultTargetPlatform;

              final bool isMobilePhone =
                  (platform == TargetPlatform.android ||
                      platform == TargetPlatform.iOS) &&
                  screenWidth < kTabletBreakpoint;

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
              }

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
            },
          );
        },
      ),
    );
  }
}
