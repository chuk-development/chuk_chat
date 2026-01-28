// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/chat_preload_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/platform_specific/root_wrapper.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import for hex conversion
import 'package:chuk_chat/utils/grain_overlay.dart'; // Film grain overlay
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/password_revision_service.dart';
import 'package:chuk_chat/services/session_tracking_service.dart';
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/streaming_foreground_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/notification_service.dart';
import 'package:chuk_chat/services/theme_settings_service.dart';
import 'package:chuk_chat/services/customization_preferences_service.dart';
import 'package:chuk_chat/widgets/auth_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/* ---------- MAIN ---------- */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-initialize SharedPreferences BEFORE runApp for instant cache access
  // This is fast (~10ms) and critical for sidebar performance
  await initChatStorageCache();

  // Initialize Supabase in background - don't block UI
  unawaited(_initializeServicesAsync());

  // Use default theme immediately - load preferences async after first frame
  runApp(const ChukChatApp());
}

Future<void> _initializeServicesAsync() async {
  try {
    // Initialize foreground service for Android (non-blocking)
    unawaited(StreamingForegroundService.initialize());

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

class _ChukChatAppState extends State<ChukChatApp> with WidgetsBindingObserver {
  // Navigator key for deep linking from notifications
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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
  bool _showTps = kDefaultShowTps;

  // Customization preferences
  bool _autoSendVoiceTranscription = false;

  // Image generation preferences
  bool _imageGenEnabled = false;
  String _imageGenDefaultSize = 'landscape_4_3';
  int _imageGenCustomWidth = 1024;
  int _imageGenCustomHeight = 768;
  bool _imageGenUseCustomSize = false;

  // Keys for SharedPreferences
  static const String _kThemeModeKey = 'themeMode';
  static const String _kAccentColorKey = 'accentColor';
  static const String _kIconFgColorKey = 'iconFgColor';
  static const String _kBgColorKey = 'bgColor';
  static const String _kGrainEnabledKey = 'grainEnabled';
  static const String _kShowReasoningTokensKey = 'showReasoningTokens';
  static const String _kShowModelInfoKey = 'showModelInfo';
  static const String _kShowTpsKey = 'showTps';
  static const String _kAutoSendVoiceTranscriptionKey = 'autoSendVoiceTranscription';
  static const String _kImageGenEnabledKey = 'imageGenEnabled';
  static const String _kImageGenDefaultSizeKey = 'imageGenDefaultSize';
  static const String _kImageGenCustomWidthKey = 'imageGenCustomWidth';
  static const String _kImageGenCustomHeightKey = 'imageGenCustomHeight';
  static const String _kImageGenUseCustomSizeKey = 'imageGenUseCustomSize';

  StreamSubscription<AuthState>? _authSubscription;
  bool _hasAppliedSupabaseTheme = false;

  // Performance optimizations
  SharedPreferences? _cachedPrefs;
  Timer? _themeSyncDebounce;
  ThemeData? _cachedThemeData;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Wait for Supabase to initialize, then set up everything
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAfterSupabase();
    });
  }

  Future<void> _initializeAfterSupabase() async {
    // Wait for Supabase to be ready
    await _waitForSupabase();

    if (!mounted) return;

    // Initialize notification service for completion notifications
    await NotificationService.initialize(navigatorKey);
    // Check if app was launched from a notification
    await NotificationService.checkLaunchNotification();

    // Now we can safely access Supabase
    _authSubscription = SupabaseService.auth.onAuthStateChange.listen((
      event,
    ) async {
      if (event.session != null) {
        final user = event.session!.user;
        debugPrint('✨ [Auth] Session active - starting background init (UI NOT blocked)');

        // STEP 1: Start ALL background operations in parallel - DON'T BLOCK UI!
        // Each operation runs independently and updates UI when ready
        unawaited(_initUserSession(user));

        // STEP 2: Load theme from Supabase in background
        unawaited(_loadThemeSettingsFromSupabaseAsync());

        // STEP 3: Register device session + other background tasks
        unawaited(SessionTrackingService.registerSession());
        unawaited(_checkPasswordRevision(user));
        unawaited(ModelPrefetchService.prefetch());

        debugPrint('✨ [Auth] All background tasks launched - UI is FREE');
      } else {
        // Session is null - check if this is a real logout or just offline
        final isOnline = await NetworkStatusService.hasInternetConnection(
          useCache: false,  // Force fresh check
        );

        if (isOnline) {
          // User actually logged out - stop sync and clear data
          debugPrint('🔐 [Auth] User logged out (online) - clearing data');
          ChatSyncService.stop();
          ChatPreloadService.reset();
          await EncryptionService.clearKey();
          await ChatStorageService.reset();
            await ProjectStorageService.reset();
          _hasAppliedSupabaseTheme = false;
          await _loadThemeSettingsFromPrefs();
          await PasswordRevisionService.clearCachedRevision();
        } else {
          // We're offline - don't treat this as logout
          // Keep cached data so user can still view chats offline
          debugPrint('📴 [Auth] Session unavailable but offline - keeping cache');
          ChatSyncService.stop();
          // DON'T clear encryption key or chat cache!
          // User can still view cached chats offline
        }
      }
    });

    // Load theme after auth subscription is set up
    // Note: Chats are loaded in onAuthStateChange when user is signed in
    await _loadThemeSettingsFromPrefs();

    // Note: Supabase theme loading is handled by _loadThemeSettingsFromSupabaseAsync()
    // which is called in the auth listener when session is active (line 145)
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _themeSyncDebounce?.cancel();
    ChatSyncService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        // App came to foreground - check network status first, then resume sync
        // This prevents false "offline" states when unlocking the phone
        unawaited(_onAppResumed());
        // Notify streaming manager - stop foreground service if running
        StreamingManager().onAppLifecycleChanged(isInBackground: false);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App went to background - pause sync to save battery
        // DON'T change network status - we're not offline, just backgrounded
        ChatSyncService.pause();
        // Notify streaming manager - start foreground service if streams active
        StreamingManager().onAppLifecycleChanged(isInBackground: true);
        break;
    }
  }

  Future<void> _onAppResumed() async {
    // Reset failure count to give network a fresh chance
    NetworkStatusService.resetFailureCount();
    // Check network status immediately (don't use cache - it may be stale)
    final isOnline = await NetworkStatusService.hasInternetConnection(
      useCache: false,
      timeout: const Duration(seconds: 3),
    );
    debugPrint('📱 [Lifecycle] App resumed, network status: ${isOnline ? "ONLINE" : "OFFLINE"}');
    // Resume sync after network status is updated
    ChatSyncService.resume();
    // Update session last-seen timestamp
    if (isOnline) {
      unawaited(SessionTrackingService.updateLastSeen());
    }
  }

  /// Initialize user session - encryption key, chats, projects
  /// Runs in background to not block UI
  Future<void> _initUserSession(User user) async {
    final stopwatch = Stopwatch()..start();
    debugPrint('🚀 [Init] Starting user session init...');

    try {
      final hasKey = await EncryptionService.tryLoadKey();
      debugPrint('🔑 [Init] Encryption key loaded in ${stopwatch.elapsedMilliseconds}ms');

      if (hasKey) {
        // Load chats from cache - this notifies UI immediately when cache is loaded
        unawaited(ChatStorageService.loadSavedChatsForSidebar().then((_) {
          debugPrint('📦 [Init] Chats loaded in ${stopwatch.elapsedMilliseconds}ms');
          // Start background sync AFTER cache is loaded
          ChatSyncService.start();
          // Start background preload of all chat messages for search/export
          unawaited(ChatPreloadService.startBackgroundPreload());
        }).catchError((error, stackTrace) {
          debugPrint('Chat loading failed: $error');
          debugPrint('$stackTrace');
        }));

        // Load projects in parallel
        unawaited(ProjectStorageService.loadProjects());
      } else {
        debugPrint('Encryption key not available - user may need to re-authenticate');
        ChatSyncService.stop();
      }
    } catch (error, stackTrace) {
      debugPrint('Encryption key load failed: $error');
      debugPrint('$stackTrace');
      ChatSyncService.stop();
    }
  }

  /// Load theme from Supabase in background - doesn't block UI
  Future<void> _loadThemeSettingsFromSupabaseAsync() async {
    try {
      await _loadThemeSettingsFromSupabase();
    } catch (e) {
      debugPrint('Theme load from Supabase failed: $e');
    }
  }

  /// Check password revision in background - force logout if password changed elsewhere
  /// This runs async to not block the initial UI load
  Future<void> _checkPasswordRevision(User user) async {
    try {
      final shouldForceLogout =
          await PasswordRevisionService.hasRevisionMismatch(user);
      if (shouldForceLogout) {
        debugPrint('🔐 [Auth] Password revision mismatch - forcing logout');
        await SessionTrackingService.setRemotelySignedOut();
        await PasswordRevisionService.clearCachedRevision(userId: user.id);
        await SupabaseService.auth.signOut();
        await EncryptionService.clearKey();
        await ChatStorageService.reset();
        await ProjectStorageService.reset();
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
      _showTps = prefs.getBool(_kShowTpsKey) ?? kDefaultShowTps;
      _autoSendVoiceTranscription = prefs.getBool(_kAutoSendVoiceTranscriptionKey) ?? false;
      _imageGenEnabled = prefs.getBool(_kImageGenEnabledKey) ?? false;
      _imageGenDefaultSize = prefs.getString(_kImageGenDefaultSizeKey) ?? 'landscape_4_3';
      _imageGenCustomWidth = prefs.getInt(_kImageGenCustomWidthKey) ?? 1024;
      _imageGenCustomHeight = prefs.getInt(_kImageGenCustomHeightKey) ?? 768;
      _imageGenUseCustomSize = prefs.getBool(_kImageGenUseCustomSizeKey) ?? false;
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
    _debouncedSyncCustomizationSettings();
  }

  void _setShowModelInfo(bool show) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kShowModelInfoKey, show);
    setState(() {
      _showModelInfo = show;
    });
    _debouncedSyncCustomizationSettings();
  }

  void _setShowTps(bool show) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kShowTpsKey, show);
    setState(() {
      _showTps = show;
    });
    _debouncedSyncCustomizationSettings();
  }

  void _setAutoSendVoiceTranscription(bool autoSend) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kAutoSendVoiceTranscriptionKey, autoSend);
    setState(() {
      _autoSendVoiceTranscription = autoSend;
    });
    _debouncedSyncCustomizationSettings();
  }

  void _setImageGenEnabled(bool enabled) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kImageGenEnabledKey, enabled);
    setState(() {
      _imageGenEnabled = enabled;
    });
    _debouncedSyncCustomizationSettings();
  }

  void _setImageGenDefaultSize(String size) async {
    final prefs = await _getPrefs();
    await prefs.setString(_kImageGenDefaultSizeKey, size);
    setState(() {
      _imageGenDefaultSize = size;
    });
    _debouncedSyncCustomizationSettings();
  }

  void _setImageGenCustomWidth(int width) async {
    final prefs = await _getPrefs();
    await prefs.setInt(_kImageGenCustomWidthKey, width);
    setState(() {
      _imageGenCustomWidth = width;
    });
    _debouncedSyncCustomizationSettings();
  }

  void _setImageGenCustomHeight(int height) async {
    final prefs = await _getPrefs();
    await prefs.setInt(_kImageGenCustomHeightKey, height);
    setState(() {
      _imageGenCustomHeight = height;
    });
    _debouncedSyncCustomizationSettings();
  }

  void _setImageGenUseCustomSize(bool useCustom) async {
    final prefs = await _getPrefs();
    await prefs.setBool(_kImageGenUseCustomSizeKey, useCustom);
    setState(() {
      _imageGenUseCustomSize = useCustom;
    });
    _debouncedSyncCustomizationSettings();
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
      // Load both settings in PARALLEL for faster startup
      final results = await Future.wait([
        const ThemeSettingsService().loadOrCreate(),
        const CustomizationPreferencesService().loadOrCreate(),
      ]);
      final settings = results[0] as ThemeSettings;
      final customizationPrefs = results[1] as CustomizationPreferences;

      if (!mounted) return;
      // Performance: Batch all updates into single setState
      setState(() {
        _currentThemeMode = settings.themeMode;
        _currentAccentColor = settings.accentColor;
        _currentIconFgColor = settings.iconColor;
        _currentBgColor = settings.backgroundColor;
        _grainEnabled = settings.grainEnabled;
        _showReasoningTokens = customizationPrefs.showReasoningTokens;
        _showModelInfo = customizationPrefs.showModelInfo;
        _showTps = customizationPrefs.showTps;
        _autoSendVoiceTranscription = customizationPrefs.autoSendVoiceTranscription;
        _imageGenEnabled = customizationPrefs.imageGenEnabled;
        _imageGenDefaultSize = customizationPrefs.imageGenDefaultSize;
        _imageGenCustomWidth = customizationPrefs.imageGenCustomWidth;
        _imageGenCustomHeight = customizationPrefs.imageGenCustomHeight;
        _imageGenUseCustomSize = customizationPrefs.imageGenUseCustomSize;
        _hasAppliedSupabaseTheme = true;
        _cachedThemeData = null; // Invalidate cache
      });
      // Persist to prefs in background
      unawaited(_persistThemeSettingsToPrefs());
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
    await prefs.setBool(_kAutoSendVoiceTranscriptionKey, _autoSendVoiceTranscription);
    await prefs.setBool(_kImageGenEnabledKey, _imageGenEnabled);
    await prefs.setString(_kImageGenDefaultSizeKey, _imageGenDefaultSize);
    await prefs.setInt(_kImageGenCustomWidthKey, _imageGenCustomWidth);
    await prefs.setInt(_kImageGenCustomHeightKey, _imageGenCustomHeight);
    await prefs.setBool(_kImageGenUseCustomSizeKey, _imageGenUseCustomSize);
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

  // Performance: Debounce customization sync to avoid excessive Supabase calls
  void _debouncedSyncCustomizationSettings() {
    _themeSyncDebounce?.cancel();
    _themeSyncDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_syncCustomizationSettings());
    });
  }

  Future<void> _syncCustomizationSettings() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    final preferences = CustomizationPreferences(
      userId: user.id,
      autoSendVoiceTranscription: _autoSendVoiceTranscription,
      showReasoningTokens: _showReasoningTokens,
      showModelInfo: _showModelInfo,
      showTps: _showTps,
      imageGenEnabled: _imageGenEnabled,
      imageGenDefaultSize: _imageGenDefaultSize,
      imageGenCustomWidth: _imageGenCustomWidth,
      imageGenCustomHeight: _imageGenCustomHeight,
      imageGenUseCustomSize: _imageGenUseCustomSize,
    );

    try {
      await const CustomizationPreferencesService().save(preferences);
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
      navigatorKey: navigatorKey,
      title: 'Chuk Chat',
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
            showTps: _showTps,
            setShowTps: _setShowTps,
            autoSendVoiceTranscription: _autoSendVoiceTranscription,
            setAutoSendVoiceTranscription: _setAutoSendVoiceTranscription,
            imageGenEnabled: _imageGenEnabled,
            setImageGenEnabled: _setImageGenEnabled,
            imageGenDefaultSize: _imageGenDefaultSize,
            setImageGenDefaultSize: _setImageGenDefaultSize,
            imageGenCustomWidth: _imageGenCustomWidth,
            setImageGenCustomWidth: _setImageGenCustomWidth,
            imageGenCustomHeight: _imageGenCustomHeight,
            setImageGenCustomHeight: _setImageGenCustomHeight,
            imageGenUseCustomSize: _imageGenUseCustomSize,
            setImageGenUseCustomSize: _setImageGenUseCustomSize,
          );
        },
      ),
    );
  }
}
