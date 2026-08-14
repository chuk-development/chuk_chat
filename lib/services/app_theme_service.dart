// lib/services/app_theme_service.dart
// Manages application theme state and persistence

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/theme_settings_service.dart';
import 'package:chuk_chat/services/customization_preferences_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

/// Callback type for theme changes
typedef ThemeChangedCallback = void Function();

/// Service for managing application theme state, persistence, and Supabase sync
class AppThemeService extends ChangeNotifier {
  AppThemeService._();

  static final AppThemeService _instance = AppThemeService._();
  static AppThemeService get instance => _instance;

  // Theme state
  Brightness _themeMode = kDefaultThemeMode;
  Color _accentColor = kDefaultAccentColor;
  Color _iconFgColor = kDefaultIconFgColor;
  Color _bgColor = kDefaultBgColor;
  bool _dynamicColorEnabled = kDefaultDynamicColorEnabled;

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

  // AI context preferences
  bool _includeRecentImagesInHistory = true;
  bool _includeAllImagesInHistory = false;
  bool _includeReasoningInHistory = false;
  bool _includeToolResultsInHistory = kDefaultIncludeToolResultsInHistory;

  // Tool-calling preferences
  bool _toolCallingEnabled = kDefaultToolCallingEnabled;
  bool _toolDiscoveryMode = kDefaultToolDiscoveryMode;
  bool _showToolCalls = kDefaultShowToolCalls;
  bool _allowMarkdownToolCalls = kDefaultAllowMarkdownToolCalls;

  // UI locale
  String _uiLocale = kDefaultUiLocale;

  // Chat body font size
  double _chatFontSize = kDefaultChatFontSize;

  // Chat body font family identifier
  String _chatFontFamily = kDefaultChatFontFamily;

  // UI scale (applies to entire app via MediaQuery textScaler)
  double _uiScale = kDefaultUiScale;

  // Onboarding completion. Per-user: cached locally under a user-scoped key
  // and synced to Supabase (customization_preferences.onboarding_completed)
  // so the tour shows once per account, not once per device.
  bool _onboardingCompleted = false;

  // Keys for SharedPreferences
  static const String _kThemeModeKey = 'themeMode';
  static const String _kAccentColorKey = 'accentColor';
  static const String _kIconFgColorKey = 'iconFgColor';
  static const String _kBgColorKey = 'bgColor';
  static const String _kDynamicColorEnabledKey = 'dynamicColorEnabled';
  static const String _kShowReasoningTokensKey = 'showReasoningTokens';
  static const String _kShowModelInfoKey = 'showModelInfo';
  static const String _kShowTpsKey = 'showTps';
  static const String _kAutoSendVoiceTranscriptionKey =
      'autoSendVoiceTranscription';
  static const String _kImageGenEnabledKey = 'imageGenEnabled';
  static const String _kImageGenDefaultSizeKey = 'imageGenDefaultSize';
  static const String _kImageGenCustomWidthKey = 'imageGenCustomWidth';
  static const String _kImageGenCustomHeightKey = 'imageGenCustomHeight';
  static const String _kImageGenUseCustomSizeKey = 'imageGenUseCustomSize';
  static const String _kIncludeRecentImagesInHistoryKey =
      'includeRecentImagesInHistory';
  static const String _kIncludeAllImagesInHistoryKey =
      'includeAllImagesInHistory';
  static const String _kIncludeReasoningInHistoryKey =
      'includeReasoningInHistory';
  static const String _kIncludeToolResultsInHistoryKey =
      'includeToolResultsInHistory';
  static const String _kToolCallingEnabledKey = 'toolCallingEnabled';
  static const String _kToolDiscoveryModeKey = 'toolDiscoveryMode';
  static const String _kShowToolCallsKey = 'showToolCalls';
  static const String _kAllowMarkdownToolCallsKey = 'allowMarkdownToolCalls';
  static const String _kUiLocaleKey = 'uiLocale';
  static const String _kChatFontSizeKey = 'chatFontSize';
  static const String _kChatFontFamilyKey = 'chatFontFamily';
  static const String _kUiScaleKey = 'uiScale';
  // Legacy device-global onboarding key. Migrated to the per-user key (and
  // Supabase) on the first Supabase load after update, then removed.
  static const String _kOnboardingCompletedKey = 'onboardingCompleted';

  static String _onboardingKeyFor(String userId) =>
      '$_kOnboardingCompletedKey:$userId';

  // Performance optimizations
  SharedPreferences? _cachedPrefs;
  Timer? _syncDebounce;
  ThemeData? _cachedThemeData;
  // The resolved colours the cached theme was built with. These differ from
  // _accentColor/_bgColor/_iconFgColor when Material You / dynamic colour is
  // overriding the whole palette, so the cache is keyed on all three.
  Color? _cachedThemeAccent;
  Color? _cachedThemeBg;
  Color? _cachedThemeIconFg;
  bool _hasAppliedSupabaseTheme = false;
  Future<void>? _supabaseLoadInFlight;
  DateTime? _lastSupabaseLoadAt;
  static const Duration _supabaseLoadTtl = Duration(seconds: 20);

  // Getters
  Brightness get themeMode => _themeMode;
  Color get accentColor => _accentColor;
  Color get iconFgColor => _iconFgColor;
  Color get bgColor => _bgColor;
  bool get dynamicColorEnabled => _dynamicColorEnabled;
  bool get showReasoningTokens => _showReasoningTokens;
  bool get showModelInfo => _showModelInfo;
  bool get showTps => _showTps;
  bool get autoSendVoiceTranscription => _autoSendVoiceTranscription;
  bool get imageGenEnabled => _imageGenEnabled;
  String get imageGenDefaultSize => _imageGenDefaultSize;
  int get imageGenCustomWidth => _imageGenCustomWidth;
  int get imageGenCustomHeight => _imageGenCustomHeight;
  bool get imageGenUseCustomSize => _imageGenUseCustomSize;
  bool get includeRecentImagesInHistory => _includeRecentImagesInHistory;
  bool get includeAllImagesInHistory => _includeAllImagesInHistory;
  bool get includeReasoningInHistory => _includeReasoningInHistory;
  bool get includeToolResultsInHistory => _includeToolResultsInHistory;
  bool get toolCallingEnabled => _toolCallingEnabled;
  bool get toolDiscoveryMode => _toolDiscoveryMode;
  bool get showToolCalls => _showToolCalls;
  bool get allowMarkdownToolCalls => _allowMarkdownToolCalls;
  String get uiLocale => _uiLocale;
  double get chatFontSize => _chatFontSize;
  String get chatFontFamily => _chatFontFamily;
  double get uiScale => _uiScale;
  bool get onboardingCompleted => _onboardingCompleted;
  bool get hasAppliedSupabaseTheme => _hasAppliedSupabaseTheme;

  ThemeData? get cachedThemeData => _cachedThemeData;

  // Performance: Cache SharedPreferences instance
  Future<SharedPreferences> _getPrefs() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  /// Load theme settings from local SharedPreferences
  Future<void> loadFromPrefs() async {
    final prefs = await _getPrefs();

    _themeMode = (prefs.getString(_kThemeModeKey) == 'light')
        ? Brightness.light
        : kDefaultThemeMode;
    _accentColor = ColorExtension.fromHexString(
      prefs.getString(_kAccentColorKey),
      fallback: kDefaultAccentColor,
    );
    _iconFgColor = ColorExtension.fromHexString(
      prefs.getString(_kIconFgColorKey),
      fallback: kDefaultIconFgColor,
    );
    _bgColor = ColorExtension.fromHexString(
      prefs.getString(_kBgColorKey),
      fallback: kDefaultBgColor,
    );
    _dynamicColorEnabled =
        prefs.getBool(_kDynamicColorEnabledKey) ?? kDefaultDynamicColorEnabled;
    _showReasoningTokens =
        prefs.getBool(_kShowReasoningTokensKey) ?? kDefaultShowReasoningTokens;
    _showModelInfo = prefs.getBool(_kShowModelInfoKey) ?? kDefaultShowModelInfo;
    _showTps = prefs.getBool(_kShowTpsKey) ?? kDefaultShowTps;
    _autoSendVoiceTranscription =
        prefs.getBool(_kAutoSendVoiceTranscriptionKey) ?? false;
    _imageGenEnabled = prefs.getBool(_kImageGenEnabledKey) ?? false;
    _imageGenDefaultSize =
        prefs.getString(_kImageGenDefaultSizeKey) ?? 'landscape_4_3';
    _imageGenCustomWidth = prefs.getInt(_kImageGenCustomWidthKey) ?? 1024;
    _imageGenCustomHeight = prefs.getInt(_kImageGenCustomHeightKey) ?? 768;
    _imageGenUseCustomSize = prefs.getBool(_kImageGenUseCustomSizeKey) ?? false;
    _includeRecentImagesInHistory =
        prefs.getBool(_kIncludeRecentImagesInHistoryKey) ?? true;
    _includeAllImagesInHistory =
        prefs.getBool(_kIncludeAllImagesInHistoryKey) ?? false;
    _includeReasoningInHistory =
        prefs.getBool(_kIncludeReasoningInHistoryKey) ?? false;
    _includeToolResultsInHistory =
        prefs.getBool(_kIncludeToolResultsInHistoryKey) ??
        kDefaultIncludeToolResultsInHistory;
    _toolCallingEnabled =
        prefs.getBool(_kToolCallingEnabledKey) ?? kDefaultToolCallingEnabled;
    _toolDiscoveryMode =
        prefs.getBool(_kToolDiscoveryModeKey) ?? kDefaultToolDiscoveryMode;
    _showToolCalls = prefs.getBool(_kShowToolCallsKey) ?? kDefaultShowToolCalls;
    _allowMarkdownToolCalls =
        prefs.getBool(_kAllowMarkdownToolCallsKey) ??
        kDefaultAllowMarkdownToolCalls;
    _uiLocale = prefs.getString(_kUiLocaleKey) ?? kDefaultUiLocale;
    _chatFontSize = _clampChatFontSize(
      prefs.getDouble(_kChatFontSizeKey) ?? kDefaultChatFontSize,
    );
    _chatFontFamily = _sanitizeChatFontFamily(
      prefs.getString(_kChatFontFamilyKey),
    );
    _uiScale = _clampUiScale(prefs.getDouble(_kUiScaleKey) ?? kDefaultUiScale);
    _onboardingCompleted = _readLocalOnboarding(prefs);

    _cachedThemeData = null;
    notifyListeners();
  }

  /// Reads the locally cached onboarding state for the signed-in user,
  /// falling back to the legacy device-global key from older app versions.
  bool _readLocalOnboarding(SharedPreferences prefs) {
    final user =
        SupabaseService.isInitialized ? SupabaseService.auth.currentUser : null;
    if (user == null) {
      return prefs.getBool(_kOnboardingCompletedKey) ?? false;
    }
    return prefs.getBool(_onboardingKeyFor(user.id)) ??
        prefs.getBool(_kOnboardingCompletedKey) ??
        false;
  }

  double _clampChatFontSize(double v) =>
      v.clamp(kMinChatFontSize, kMaxChatFontSize);

  double _clampUiScale(double v) => v.clamp(kMinUiScale, kMaxUiScale);

  String _sanitizeChatFontFamily(String? id) {
    if (id == null || !kSupportedChatFontFamilies.contains(id)) {
      return kDefaultChatFontFamily;
    }
    return id;
  }

  /// Load theme from Supabase in background
  Future<void> loadFromSupabaseAsync({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _lastSupabaseLoadAt != null &&
        now.difference(_lastSupabaseLoadAt!) < _supabaseLoadTtl) {
      return;
    }

    if (_supabaseLoadInFlight != null) {
      return _supabaseLoadInFlight!;
    }

    Future<void> run() async {
      try {
        await _loadFromSupabase();
        _lastSupabaseLoadAt = DateTime.now();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Theme load from Supabase failed: $e');
        }
      }
    }

    _supabaseLoadInFlight = run();
    await _supabaseLoadInFlight!.whenComplete(() {
      _supabaseLoadInFlight = null;
    });
  }

  Future<void> _loadFromSupabase() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    // Load both settings in PARALLEL for faster startup
    final results = await Future.wait([
      const ThemeSettingsService().loadOrCreate(),
      const CustomizationPreferencesService().loadOrCreate(),
    ]);
    final settings = results[0] as ThemeSettings;
    final customizationPrefs = results[1] as CustomizationPreferences;
    final bool hasVisualOrBehaviorChange =
        _themeMode != settings.themeMode ||
        _accentColor != settings.accentColor ||
        _iconFgColor != settings.iconColor ||
        _bgColor != settings.backgroundColor ||
        _showReasoningTokens != customizationPrefs.showReasoningTokens ||
        _showModelInfo != customizationPrefs.showModelInfo ||
        _showTps != customizationPrefs.showTps ||
        _autoSendVoiceTranscription !=
            customizationPrefs.autoSendVoiceTranscription ||
        _imageGenEnabled != customizationPrefs.imageGenEnabled ||
        _imageGenDefaultSize != customizationPrefs.imageGenDefaultSize ||
        _imageGenCustomWidth != customizationPrefs.imageGenCustomWidth ||
        _imageGenCustomHeight != customizationPrefs.imageGenCustomHeight ||
        _imageGenUseCustomSize != customizationPrefs.imageGenUseCustomSize ||
        _includeRecentImagesInHistory !=
            customizationPrefs.includeRecentImagesInHistory ||
        _includeAllImagesInHistory !=
            customizationPrefs.includeAllImagesInHistory ||
        _includeReasoningInHistory !=
            customizationPrefs.includeReasoningInHistory ||
        _includeToolResultsInHistory !=
            customizationPrefs.includeToolResultsInHistory ||
        _toolCallingEnabled != customizationPrefs.toolCallingEnabled ||
        _toolDiscoveryMode != customizationPrefs.toolDiscoveryMode ||
        _showToolCalls != customizationPrefs.showToolCalls ||
        _allowMarkdownToolCalls != customizationPrefs.allowMarkdownToolCalls ||
        _uiLocale != customizationPrefs.uiLocale ||
        _chatFontSize != _clampChatFontSize(customizationPrefs.chatFontSize) ||
        _chatFontFamily !=
            _sanitizeChatFontFamily(customizationPrefs.chatFontFamily);

    _themeMode = settings.themeMode;
    _accentColor = settings.accentColor;
    _iconFgColor = settings.iconColor;
    _bgColor = settings.backgroundColor;
    _showReasoningTokens = customizationPrefs.showReasoningTokens;
    _showModelInfo = customizationPrefs.showModelInfo;
    _showTps = customizationPrefs.showTps;
    _autoSendVoiceTranscription = customizationPrefs.autoSendVoiceTranscription;
    _imageGenEnabled = customizationPrefs.imageGenEnabled;
    _imageGenDefaultSize = customizationPrefs.imageGenDefaultSize;
    _imageGenCustomWidth = customizationPrefs.imageGenCustomWidth;
    _imageGenCustomHeight = customizationPrefs.imageGenCustomHeight;
    _imageGenUseCustomSize = customizationPrefs.imageGenUseCustomSize;
    _includeRecentImagesInHistory =
        customizationPrefs.includeRecentImagesInHistory;
    _includeAllImagesInHistory = customizationPrefs.includeAllImagesInHistory;
    _includeReasoningInHistory = customizationPrefs.includeReasoningInHistory;
    _includeToolResultsInHistory =
        customizationPrefs.includeToolResultsInHistory;
    _toolCallingEnabled = customizationPrefs.toolCallingEnabled;
    _toolDiscoveryMode = customizationPrefs.toolDiscoveryMode;
    _showToolCalls = customizationPrefs.showToolCalls;
    _allowMarkdownToolCalls = customizationPrefs.allowMarkdownToolCalls;
    _uiLocale = customizationPrefs.uiLocale;
    _chatFontSize = _clampChatFontSize(customizationPrefs.chatFontSize);
    _chatFontFamily = _sanitizeChatFontFamily(
      customizationPrefs.chatFontFamily,
    );
    _hasAppliedSupabaseTheme = true;
    _cachedThemeData = null;

    await _reconcileOnboarding(user.id, customizationPrefs.onboardingCompleted);

    if (hasVisualOrBehaviorChange) {
      notifyListeners();
      // Persist to prefs in background only if state changed.
      unawaited(_persistToPrefs());
    }
  }

  /// Merges the per-user Supabase onboarding flag with the local cache.
  /// Completion wins on either side: a locally completed tour (legacy key or
  /// offline completion) is pushed up; a server-side completion is cached
  /// down so fresh installs don't re-show the tour. The legacy device-global
  /// key is removed after the first reconcile so later accounts on the same
  /// device still get their own tour.
  Future<void> _reconcileOnboarding(String userId, bool serverCompleted) async {
    final prefs = await _getPrefs();
    final localCompleted = _readLocalOnboarding(prefs);
    _onboardingCompleted = localCompleted || serverCompleted;
    await prefs.setBool(_onboardingKeyFor(userId), _onboardingCompleted);
    if (prefs.containsKey(_kOnboardingCompletedKey)) {
      await prefs.remove(_kOnboardingCompletedKey);
    }
    if (localCompleted && !serverCompleted) {
      _debouncedSyncCustomization();
    }
  }

  Future<void> _persistToPrefs() async {
    final prefs = await _getPrefs();
    // Parallelize all SharedPreferences writes to reduce blocking time
    await Future.wait([
      prefs.setString(
        _kThemeModeKey,
        _themeMode == Brightness.light ? 'light' : 'dark',
      ),
      prefs.setString(_kAccentColorKey, _accentColor.toHexString()),
      prefs.setString(_kIconFgColorKey, _iconFgColor.toHexString()),
      prefs.setString(_kBgColorKey, _bgColor.toHexString()),
      prefs.setBool(_kShowReasoningTokensKey, _showReasoningTokens),
      prefs.setBool(_kShowModelInfoKey, _showModelInfo),
      prefs.setBool(_kShowTpsKey, _showTps),
      prefs.setBool(
        _kAutoSendVoiceTranscriptionKey,
        _autoSendVoiceTranscription,
      ),
      prefs.setBool(_kImageGenEnabledKey, _imageGenEnabled),
      prefs.setString(_kImageGenDefaultSizeKey, _imageGenDefaultSize),
      prefs.setInt(_kImageGenCustomWidthKey, _imageGenCustomWidth),
      prefs.setInt(_kImageGenCustomHeightKey, _imageGenCustomHeight),
      prefs.setBool(_kImageGenUseCustomSizeKey, _imageGenUseCustomSize),
      prefs.setBool(
        _kIncludeRecentImagesInHistoryKey,
        _includeRecentImagesInHistory,
      ),
      prefs.setBool(_kIncludeAllImagesInHistoryKey, _includeAllImagesInHistory),
      prefs.setBool(_kIncludeReasoningInHistoryKey, _includeReasoningInHistory),
      prefs.setBool(
        _kIncludeToolResultsInHistoryKey,
        _includeToolResultsInHistory,
      ),
      prefs.setBool(_kToolCallingEnabledKey, _toolCallingEnabled),
      prefs.setBool(_kToolDiscoveryModeKey, _toolDiscoveryMode),
      prefs.setBool(_kShowToolCallsKey, _showToolCalls),
      prefs.setBool(_kAllowMarkdownToolCallsKey, _allowMarkdownToolCalls),
      prefs.setString(_kUiLocaleKey, _uiLocale),
      prefs.setDouble(_kChatFontSizeKey, _chatFontSize),
      prefs.setString(_kChatFontFamilyKey, _chatFontFamily),
      prefs.setDouble(_kUiScaleKey, _uiScale),
    ]);
  }

  // Debounced sync to avoid excessive Supabase calls
  void _debouncedSyncTheme() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_syncThemeToSupabase());
    });
  }

  void _debouncedSyncCustomization() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_syncCustomizationToSupabase());
    });
  }

  Future<void> _syncThemeToSupabase() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    final settings = ThemeSettings(
      userId: user.id,
      themeMode: _themeMode,
      accentColor: _accentColor,
      iconColor: _iconFgColor,
      backgroundColor: _bgColor,
    );

    try {
      await const ThemeSettingsService().save(settings);
      await _persistToPrefs();
    } catch (_) {
      // Ignore sync failures; preferences remain updated locally.
    }
  }

  Future<void> _syncCustomizationToSupabase() async {
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
      includeRecentImagesInHistory: _includeRecentImagesInHistory,
      includeAllImagesInHistory: _includeAllImagesInHistory,
      includeReasoningInHistory: _includeReasoningInHistory,
      includeToolResultsInHistory: _includeToolResultsInHistory,
      toolCallingEnabled: _toolCallingEnabled,
      toolDiscoveryMode: _toolDiscoveryMode,
      showToolCalls: _showToolCalls,
      allowMarkdownToolCalls: _allowMarkdownToolCalls,
      uiLocale: _uiLocale,
      chatFontSize: _chatFontSize,
      chatFontFamily: _chatFontFamily,
      onboardingCompleted: _onboardingCompleted,
    );

    try {
      await const CustomizationPreferencesService().save(preferences);
      await _persistToPrefs();
    } catch (e) {
      // Keep local preferences, but surface sync failures in debug builds.
      if (kDebugMode) {
        debugPrint('Customization sync to Supabase failed: $e');
      }
    }
  }

  // Setters with persistence
  void setThemeMode(Brightness mode) {
    _themeMode = mode;
    _cachedThemeData = null;
    notifyListeners();
    _debouncedSyncTheme();
  }

  void setAccentColor(Color color) {
    _accentColor = color;
    _cachedThemeData = null;
    notifyListeners();
    _debouncedSyncTheme();
  }

  void setIconFgColor(Color color) {
    _iconFgColor = color;
    _cachedThemeData = null;
    notifyListeners();
    _debouncedSyncTheme();
  }

  void setBgColor(Color color) {
    _bgColor = color;
    _cachedThemeData = null;
    notifyListeners();
    _debouncedSyncTheme();
  }

  /// Material You / dynamic colour is a per-device display preference (it
  /// depends on the OS exposing a dynamic palette), so — like [setUiScale] —
  /// it is persisted to SharedPreferences only and NOT synced to Supabase.
  Future<void> setDynamicColorEnabled(bool enabled) async {
    if (_dynamicColorEnabled == enabled) return;
    _dynamicColorEnabled = enabled;
    _cachedThemeData = null;
    notifyListeners();
    final prefs = await _getPrefs();
    await prefs.setBool(_kDynamicColorEnabledKey, _dynamicColorEnabled);
  }

  void setShowReasoningTokens(bool show) {
    _showReasoningTokens = show;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setShowModelInfo(bool show) {
    _showModelInfo = show;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setShowTps(bool show) {
    _showTps = show;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setAutoSendVoiceTranscription(bool autoSend) {
    _autoSendVoiceTranscription = autoSend;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setImageGenEnabled(bool enabled) {
    _imageGenEnabled = enabled;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setImageGenDefaultSize(String size) {
    _imageGenDefaultSize = size;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setImageGenCustomWidth(int width) {
    _imageGenCustomWidth = width;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setImageGenCustomHeight(int height) {
    _imageGenCustomHeight = height;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setImageGenUseCustomSize(bool useCustom) {
    _imageGenUseCustomSize = useCustom;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setIncludeRecentImagesInHistory(bool value) {
    _includeRecentImagesInHistory = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setIncludeAllImagesInHistory(bool value) {
    _includeAllImagesInHistory = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setIncludeReasoningInHistory(bool value) {
    _includeReasoningInHistory = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setIncludeToolResultsInHistory(bool value) {
    _includeToolResultsInHistory = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setToolCallingEnabled(bool value) {
    _toolCallingEnabled = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setToolDiscoveryMode(bool value) {
    _toolDiscoveryMode = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setShowToolCalls(bool value) {
    _showToolCalls = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setAllowMarkdownToolCalls(bool value) {
    _allowMarkdownToolCalls = value;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setUiLocale(String locale) {
    _uiLocale = locale;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setChatFontSize(double size) {
    final clamped = _clampChatFontSize(size);
    if (_chatFontSize == clamped) return;
    _chatFontSize = clamped;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  void setChatFontFamily(String id) {
    final sanitized = _sanitizeChatFontFamily(id);
    if (_chatFontFamily == sanitized) return;
    _chatFontFamily = sanitized;
    notifyListeners();
    _debouncedSyncCustomization();
  }

  /// UI scale is a device-local display preference and is NOT synced to
  /// Supabase. Persists to SharedPreferences on each change.
  Future<void> setUiScale(double scale) async {
    final clamped = _clampUiScale(scale);
    if (_uiScale == clamped) return;
    _uiScale = clamped;
    notifyListeners();
    final prefs = await _getPrefs();
    await prefs.setDouble(_kUiScaleKey, _uiScale);
  }

  /// Onboarding completion is per-user: cached locally under a user-scoped
  /// key and synced to Supabase so other devices skip the tour too.
  Future<void> setOnboardingCompleted(bool completed) async {
    if (_onboardingCompleted == completed) return;
    _onboardingCompleted = completed;
    notifyListeners();
    final prefs = await _getPrefs();
    final user =
        SupabaseService.isInitialized ? SupabaseService.auth.currentUser : null;
    if (user != null) {
      await prefs.setBool(_onboardingKeyFor(user.id), _onboardingCompleted);
      _debouncedSyncCustomization();
    } else {
      // No signed-in user (shouldn't happen — the tour only runs signed in).
      // Fall back to the legacy device-global key so the state isn't lost.
      await prefs.setBool(_kOnboardingCompletedKey, _onboardingCompleted);
    }
  }

  void resetSupabaseThemeFlag() {
    _hasAppliedSupabaseTheme = false;
  }

  /// Build the ThemeData from current settings.
  ///
  /// When [dynamicColorEnabled] is on and the platform exposes a Material You
  /// palette, the [lightDynamic]/[darkDynamic] schemes (provided by
  /// `DynamicColorBuilder`) drive the *entire* palette — accent (from
  /// `primary`), background (from `surface`) and icon/foreground (from
  /// `onSurface`) — instead of the user-picked colours. The surface ladder and
  /// containers are then derived from those in [buildAppTheme], so a wallpaper
  /// or system-accent change re-tints the whole app, not just the accent.
  ///
  /// The cache is keyed on all three *resolved* colours so that when the
  /// system palette changes (e.g. the user changes their wallpaper), a fresh
  /// theme is rebuilt automatically.
  ThemeData buildTheme({ColorScheme? lightDynamic, ColorScheme? darkDynamic}) {
    final ColorScheme? dynamicScheme = _resolveDynamicScheme(
      lightDynamic: lightDynamic,
      darkDynamic: darkDynamic,
    );
    final Color accent = dynamicScheme?.primary ?? _accentColor;
    final Color bg = dynamicScheme?.surface ?? _bgColor;
    final Color iconFg = dynamicScheme?.onSurface ?? _iconFgColor;

    if (_cachedThemeData != null &&
        _cachedThemeAccent == accent &&
        _cachedThemeBg == bg &&
        _cachedThemeIconFg == iconFg) {
      return _cachedThemeData!;
    }
    _cachedThemeAccent = accent;
    _cachedThemeBg = bg;
    _cachedThemeIconFg = iconFg;
    _cachedThemeData = buildAppTheme(
      accent: accent,
      iconFg: iconFg,
      bg: bg,
      brightness: _themeMode,
    );
    return _cachedThemeData!;
  }

  /// The dynamic scheme for the active brightness, or `null` when Material You
  /// is off or the platform exposes no dynamic palette (so callers fall back
  /// to the user-picked colours).
  ColorScheme? _resolveDynamicScheme({
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    if (!_dynamicColorEnabled) return null;
    return _themeMode == Brightness.dark ? darkDynamic : lightDynamic;
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    super.dispose();
  }
}
