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

  // AI context preferences
  bool _includeRecentImagesInHistory = true;
  bool _includeAllImagesInHistory = false;
  bool _includeReasoningInHistory = false;

  // Keys for SharedPreferences
  static const String _kThemeModeKey = 'themeMode';
  static const String _kAccentColorKey = 'accentColor';
  static const String _kIconFgColorKey = 'iconFgColor';
  static const String _kBgColorKey = 'bgColor';
  static const String _kGrainEnabledKey = 'grainEnabled';
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

  // Performance optimizations
  SharedPreferences? _cachedPrefs;
  Timer? _syncDebounce;
  ThemeData? _cachedThemeData;
  bool _hasAppliedSupabaseTheme = false;

  // Getters
  Brightness get themeMode => _themeMode;
  Color get accentColor => _accentColor;
  Color get iconFgColor => _iconFgColor;
  Color get bgColor => _bgColor;
  bool get grainEnabled => _grainEnabled;
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
    _grainEnabled = prefs.getBool(_kGrainEnabledKey) ?? kDefaultGrainEnabled;
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

    _cachedThemeData = null;
    notifyListeners();
  }

  /// Load theme from Supabase in background
  Future<void> loadFromSupabaseAsync() async {
    try {
      await _loadFromSupabase();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Theme load from Supabase failed: $e');
      }
    }
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

    _themeMode = settings.themeMode;
    _accentColor = settings.accentColor;
    _iconFgColor = settings.iconColor;
    _bgColor = settings.backgroundColor;
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
    _includeRecentImagesInHistory =
        customizationPrefs.includeRecentImagesInHistory;
    _includeAllImagesInHistory = customizationPrefs.includeAllImagesInHistory;
    _includeReasoningInHistory = customizationPrefs.includeReasoningInHistory;
    _hasAppliedSupabaseTheme = true;
    _cachedThemeData = null;

    notifyListeners();

    // Persist to prefs in background
    unawaited(_persistToPrefs());
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
      prefs.setBool(_kGrainEnabledKey, _grainEnabled),
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
      grainEnabled: _grainEnabled,
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
    );

    try {
      await const CustomizationPreferencesService().save(preferences);
      await _persistToPrefs();
    } catch (_) {
      // Ignore sync failures; preferences remain updated locally.
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

  void setGrainEnabled(bool enabled) {
    _grainEnabled = enabled;
    notifyListeners();
    _debouncedSyncTheme();
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

  void resetSupabaseThemeFlag() {
    _hasAppliedSupabaseTheme = false;
  }

  /// Build the ThemeData from current settings
  ThemeData buildTheme() {
    _cachedThemeData ??= buildAppTheme(
      accent: _accentColor,
      iconFg: _iconFgColor,
      bg: _bgColor,
      brightness: _themeMode,
    );
    return _cachedThemeData!;
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    super.dispose();
  }
}
