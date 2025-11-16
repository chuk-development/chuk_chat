// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/platform_specific/root_wrapper.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import for hex conversion
import 'package:chuk_chat/utils/grain_overlay.dart'; // Film grain overlay
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/theme_settings_service.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/* ---------- MAIN ---------- */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase in background - don't block UI
  unawaited(_initializeServicesAsync());

  // Use default theme immediately - load preferences async after first frame
  runApp(const ChukChatApp());
}

Future<void> _initializeServicesAsync() async {
  try {
    await SupabaseService.initialize();

    // After Supabase is ready, load other stuff
    if (SupabaseService.auth.currentSession != null) {
      unawaited(
        EncryptionService.tryLoadKey().catchError((error, stackTrace) async {
          debugPrint('Initial encryption key load failed: $error');
          debugPrint('$stackTrace');
          await EncryptionService.clearKey();
          return false;
        }),
      );
      unawaited(ModelPrefetchService.prefetch());
    }
  } catch (error) {
    debugPrint('Service initialization failed: $error');
  }
}

class ChukChatApp extends StatefulWidget {
  const ChukChatApp({super.key});

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

  // Message display preferences
  bool _showReasoningTokens = kDefaultShowReasoningTokens;
  bool _showModelInfo = kDefaultShowModelInfo;

  // Keys for SharedPreferences
  static const String _kThemeModeKey = 'themeMode';
  static const String _kAccentColorKey = 'accentColor';
  static const String _kIconFgColorKey = 'iconFgColor';
  static const String _kBgColorKey = 'bgColor';
  static const String _kGrainEnabledKey = 'grainEnabled';
  static const String _kShowReasoningTokensKey = 'showReasoningTokens';
  static const String _kShowModelInfoKey = 'showModelInfo';

  StreamSubscription<AuthState>? _authSubscription;
  bool _hasAppliedSupabaseTheme = false;

  // Performance optimizations
  SharedPreferences? _cachedPrefs;
  Timer? _themeSyncDebounce;
  ThemeData? _cachedThemeData;

  @override
  void initState() {
    super.initState();

    // Wait for Supabase to initialize, then set up everything
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAfterSupabase();
    });
  }

  Future<void> _initializeAfterSupabase() async {
    // Wait for Supabase to be ready
    await _waitForSupabase();

    if (!mounted) return;

    // Now we can safely access Supabase
    _authSubscription = SupabaseService.auth.onAuthStateChange.listen((
      event,
    ) async {
      if (event.session != null) {
        final user = event.session!.user;
        try {
          final shouldForceLogout =
              await PasswordRevisionService.hasRevisionMismatch(user);
          if (shouldForceLogout) {
            await PasswordRevisionService.clearCachedRevision(userId: user.id);
            await SupabaseService.auth.signOut();
            await EncryptionService.clearKey();
            await ChatStorageService.reset();
            _hasAppliedSupabaseTheme = false;
            _loadThemeSettingsFromPrefs();
            return;
          }
          await PasswordRevisionService.ensureRevisionSeeded(user);
        } catch (error, stackTrace) {
          debugPrint('Password revision sync failed: $error');
          debugPrint('$stackTrace');
          await PasswordRevisionService.clearCachedRevision(userId: user.id);
        }

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
            await ChatStorageService.reset();
          }
        } catch (error, stackTrace) {
          debugPrint('Encryption key load failed: $error');
          debugPrint('$stackTrace');
          await EncryptionService.clearKey();
          await ChatStorageService.reset();
        }
        _loadThemeSettingsFromSupabase();
        unawaited(ModelPrefetchService.prefetch());
      } else {
        await EncryptionService.clearKey();
        await ChatStorageService.reset();
        _hasAppliedSupabaseTheme = false;
        _loadThemeSettingsFromPrefs();
        await PasswordRevisionService.clearCachedRevision();
      }
    });

    // Load theme and chats after auth subscription is set up
    await _loadThemeSettingsFromPrefs();
    unawaited(_loadChatsAsync());

    // Load theme from Supabase if logged in
    try {
      if (SupabaseService.auth.currentSession != null &&
          !_hasAppliedSupabaseTheme) {
        _loadThemeSettingsFromSupabase();
      }
    } catch (error) {
      debugPrint('Error checking session for theme: $error');
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _themeSyncDebounce?.cancel();
    super.dispose();
  }

  // Performance: Cache SharedPreferences instance
  Future<SharedPreferences> _getPrefs() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  Future<void> _waitForSupabase() async {
    // Wait for Supabase to initialize (max 5 seconds)
    for (int i = 0; i < 50; i++) {
      try {
        // Try to access auth - if it doesn't throw, we're initialized
        SupabaseService.auth;
        return; // Initialized successfully
      } catch (_) {
        // Not yet initialized, wait a bit
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> _loadChatsAsync() async {
    try {
      await ChatStorageService.loadSavedChatsForSidebar();
      if (mounted) setState(() {});
    } catch (error) {
      debugPrint('Failed to load chats: $error');
    }
  }

  Future<void> _loadThemeSettingsFromPrefs() async {
    final prefs = await _getPrefs();

    // Check if we should skip loading (Supabase theme already applied)
    try {
      if (SupabaseService.auth.currentSession != null &&
          _hasAppliedSupabaseTheme) {
        return;
      }
    } catch (_) {
      // Supabase not ready yet, continue with local theme
    }

    if (!mounted) return;
    // Performance: Batch all theme updates into single setState
    setState(() {
      _currentThemeMode = (prefs.getString(_kThemeModeKey) == 'light')
          ? Brightness.light
          : kDefaultThemeMode;
      _currentAccentColor = ColorExtension.fromHexString(
        prefs.getString(_kAccentColorKey),
        fallback: kDefaultAccentColor,
      );
      _currentIconFgColor = ColorExtension.fromHexString(
        prefs.getString(_kIconFgColorKey),
        fallback: kDefaultIconFgColor,
      );
      _currentBgColor = ColorExtension.fromHexString(
        prefs.getString(_kBgColorKey),
        fallback: kDefaultBgColor,
      );
      _grainEnabled = prefs.getBool(_kGrainEnabledKey) ?? kDefaultGrainEnabled;
      _showReasoningTokens = prefs.getBool(_kShowReasoningTokensKey) ?? kDefaultShowReasoningTokens;
      _showModelInfo = prefs.getBool(_kShowModelInfoKey) ?? kDefaultShowModelInfo;
      _cachedThemeData = null; // Invalidate theme cache
    });
  }

  // Callbacks for ThemePage to update settings
  void _setThemeMode(Brightness newMode) async {
    final prefs = await _getPrefs();
    await prefs.setString(
      _kThemeModeKey,
      newMode == Brightness.light ? 'light' : 'dark',
    );
    setState(() {
      _currentThemeMode = newMode;
      _cachedThemeData = null; // Invalidate cache
    });
    _debouncedSyncThemeSettings();
  }

  void _setAccentColor(Color newColor) async {
    final prefs = await _getPrefs();
    await prefs.setString(_kAccentColorKey, newColor.toHexString());
    setState(() {
      _currentAccentColor = newColor;
      _cachedThemeData = null; // Invalidate cache
    });
    _debouncedSyncThemeSettings();
  }

  void _setIconFgColor(Color newColor) async {
    final prefs = await _getPrefs();
    await prefs.setString(_kIconFgColorKey, newColor.toHexString());
    setState(() {
      _currentIconFgColor = newColor;
      _cachedThemeData = null; // Invalidate cache
    });
    _debouncedSyncThemeSettings();
  }

  void _setBgColor(Color newColor) async {
    final prefs = await _getPrefs();
    await prefs.setString(_kBgColorKey, newColor.toHexString());
    setState(() {
      _currentBgColor = newColor;
      _cachedThemeData = null; // Invalidate cache
    });
    _debouncedSyncThemeSettings();
  }

  void _setGrainEnabled(bool enabled) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kGrainEnabledKey, enabled);
    setState(() {
      _grainEnabled = enabled;
    });
    _debouncedSyncThemeSettings();
  }

  void _setShowReasoningTokens(bool show) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kShowReasoningTokensKey, show);
    setState(() {
      _showReasoningTokens = show;
    });
    _debouncedSyncThemeSettings();
  }

  void _setShowModelInfo(bool show) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kShowModelInfoKey, show);
    setState(() {
      _showModelInfo = show;
    });
    _debouncedSyncThemeSettings();
  }

  // Performance: Debounce theme sync to avoid excessive Supabase calls
  void _debouncedSyncThemeSettings() {
    _themeSyncDebounce?.cancel();
    _themeSyncDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_syncThemeSettings());
    });
  }

  Future<void> _loadThemeSettingsFromSupabase() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    try {
      final settings = await const ThemeSettingsService().loadOrCreate();
      if (!mounted) return;
      // Performance: Batch all updates into single setState
      setState(() {
        _currentThemeMode = settings.themeMode;
        _currentAccentColor = settings.accentColor;
        _currentIconFgColor = settings.iconColor;
        _currentBgColor = settings.backgroundColor;
        _grainEnabled = settings.grainEnabled;
        _showReasoningTokens = settings.showReasoningTokens;
        _showModelInfo = settings.showModelInfo;
        _hasAppliedSupabaseTheme = true;
        _cachedThemeData = null; // Invalidate cache
      });
      await _persistThemeSettingsToPrefs();
    } catch (_) {
      // Ignore remote load errors; keep existing local settings.
    }
  }

  Future<void> _persistThemeSettingsToPrefs() async {
    final prefs = await _getPrefs();
    await prefs.setString(
      _kThemeModeKey,
      _currentThemeMode == Brightness.light ? 'light' : 'dark',
    );
    await prefs.setString(_kAccentColorKey, _currentAccentColor.toHexString());
    await prefs.setString(_kIconFgColorKey, _currentIconFgColor.toHexString());
    await prefs.setString(_kBgColorKey, _currentBgColor.toHexString());
    await prefs.setBool(_kGrainEnabledKey, _grainEnabled);
    await prefs.setBool(_kShowReasoningTokensKey, _showReasoningTokens);
    await prefs.setBool(_kShowModelInfoKey, _showModelInfo);
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
      showReasoningTokens: _showReasoningTokens,
      showModelInfo: _showModelInfo,
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
    // Performance: Cache theme data to avoid rebuilding on every frame
    _cachedThemeData ??= buildAppTheme(
      accent: _currentAccentColor,
      iconFg: _currentIconFgColor,
      bg: _currentBgColor,
      brightness: _currentThemeMode,
    );

    return MaterialApp(
      title: 'chuk.chat',
      debugShowCheckedModeBanner: false,
      theme: _cachedThemeData,
      // 👇 Apply film grain to EVERY route/page
      builder: (context, child) {
        // Performance: Use const where possible
        if (child == null) return const SizedBox.shrink();

        if (!_grainEnabled) return child;

        return Stack(
          children: [
            child,
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
          // RootWrapper automatically selects the correct platform implementation
          return RootWrapper(
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
            showReasoningTokens: _showReasoningTokens,
            setShowReasoningTokens: _setShowReasoningTokens,
            showModelInfo: _showModelInfo,
            setShowModelInfo: _setShowModelInfo,
          );
        },
      ),
    );
  }
}
