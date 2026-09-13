import 'package:flutter/material.dart';

import 'package:chuk_chat/models/app_shell_config.dart';

/// An [AppShellConfig] for widget tests.
///
/// The imported chuk_chat settings surfaces all take one, and it carries 55
/// required members — the live values plus their setters. In the app they come
/// from `AgentsApp._buildShellConfig`, which is wired to `AppThemeService` and
/// SharedPreferences; a test wants neither. This builds the same shape with the
/// defaults the app starts on and setters that record instead of persisting.
///
/// Pass [onSet] to assert that a settings row actually wrote something: it is
/// called with the field name and the new value for every setter.
AppShellConfig testShellConfig({
  void Function(String field, Object? value)? onSet,
  Brightness themeMode = Brightness.dark,
  bool showReasoningTokens = false,
  bool showModelInfo = false,
  bool showTps = false,
  String uiLocale = 'en',
}) {
  void record(String field, Object? value) => onSet?.call(field, value);
  Future<void> recordAsync(String field, Object? value) async =>
      record(field, value);

  return AppShellConfig(
    currentThemeMode: themeMode,
    currentAccentColor: const Color(0xFF7C9CF5),
    currentIconFgColor: const Color(0xFFE6E6E6),
    currentBgColor: const Color(0xFF101012),
    setThemeMode: (v) => record('themeMode', v),
    setAccentColor: (v) => record('accentColor', v),
    setIconFgColor: (v) => record('iconFgColor', v),
    setBgColor: (v) => record('bgColor', v),
    dynamicColorEnabled: false,
    setDynamicColorEnabled: (v) => recordAsync('dynamicColorEnabled', v),
    contrast: 0,
    setContrast: (v) => recordAsync('contrast', v),
    uiFontFamily: 'system',
    setUiFontFamily: (v) => recordAsync('uiFontFamily', v),
    showReasoningTokens: showReasoningTokens,
    setShowReasoningTokens: (v) => record('showReasoningTokens', v),
    showModelInfo: showModelInfo,
    setShowModelInfo: (v) => record('showModelInfo', v),
    showTps: showTps,
    setShowTps: (v) => record('showTps', v),
    autoSendVoiceTranscription: false,
    setAutoSendVoiceTranscription: (v) =>
        record('autoSendVoiceTranscription', v),
    imageGenEnabled: false,
    setImageGenEnabled: (v) => record('imageGenEnabled', v),
    imageGenDefaultSize: '1024x1024',
    setImageGenDefaultSize: (v) => record('imageGenDefaultSize', v),
    imageGenCustomWidth: 1024,
    setImageGenCustomWidth: (v) => record('imageGenCustomWidth', v),
    imageGenCustomHeight: 1024,
    setImageGenCustomHeight: (v) => record('imageGenCustomHeight', v),
    imageGenUseCustomSize: false,
    setImageGenUseCustomSize: (v) => record('imageGenUseCustomSize', v),
    includeRecentImagesInHistory: false,
    setIncludeRecentImagesInHistory: (v) =>
        record('includeRecentImagesInHistory', v),
    includeAllImagesInHistory: false,
    setIncludeAllImagesInHistory: (v) =>
        record('includeAllImagesInHistory', v),
    includeReasoningInHistory: false,
    setIncludeReasoningInHistory: (v) =>
        record('includeReasoningInHistory', v),
    includeToolResultsInHistory: false,
    setIncludeToolResultsInHistory: (v) =>
        record('includeToolResultsInHistory', v),
    // The host runs every tool; the client must never dispatch one.
    toolCallingEnabled: false,
    setToolCallingEnabled: (v) => record('toolCallingEnabled', v),
    toolDiscoveryMode: false,
    setToolDiscoveryMode: (v) => record('toolDiscoveryMode', v),
    showToolCalls: false,
    setShowToolCalls: (v) => record('showToolCalls', v),
    uiLocale: uiLocale,
    setUiLocale: (v) => record('uiLocale', v),
    chatFontSize: 15,
    setChatFontSize: (v) => record('chatFontSize', v),
    chatFontFamily: 'arimo',
    setChatFontFamily: (v) => record('chatFontFamily', v),
    uiScale: 1,
    setUiScale: (v) => recordAsync('uiScale', v),
  );
}
