// lib/models/app_shell_config.dart
import 'package:flutter/material.dart';

/// Bundles all theme, display, image-generation, and AI-context settings
/// that are passed through the widget tree from main.dart down to
/// RootWrapper → SettingsPage / ChatUI / etc.
///
/// Replaces 34 individual required parameters with a single config object.
class AppShellConfig {
  // ── Theme ──────────────────────────────────────────────────
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;
  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor;

  // ── Material You / dynamic colour ──────────────────────────
  final bool dynamicColorEnabled;
  final Future<void> Function(bool) setDynamicColorEnabled;

  // ── Contrast (surface/outline separation strength) ─────────
  final double contrast;
  final Future<void> Function(double) setContrast;

  // ── UI (app-chrome) font family ────────────────────────────
  final String uiFontFamily;
  final Future<void> Function(String) setUiFontFamily;

  // ── Display toggles ────────────────────────────────────────
  final bool showReasoningTokens;
  final Function(bool) setShowReasoningTokens;
  final bool showModelInfo;
  final Function(bool) setShowModelInfo;
  final bool showTps;
  final Function(bool) setShowTps;

  // ── Customization ──────────────────────────────────────────
  final bool autoSendVoiceTranscription;
  final Function(bool) setAutoSendVoiceTranscription;

  // ── Image generation ───────────────────────────────────────
  final bool imageGenEnabled;
  final Function(bool) setImageGenEnabled;
  final String imageGenDefaultSize;
  final Function(String) setImageGenDefaultSize;
  final int imageGenCustomWidth;
  final Function(int) setImageGenCustomWidth;
  final int imageGenCustomHeight;
  final Function(int) setImageGenCustomHeight;
  final bool imageGenUseCustomSize;
  final Function(bool) setImageGenUseCustomSize;

  // ── AI context ─────────────────────────────────────────────
  final bool includeRecentImagesInHistory;
  final Function(bool) setIncludeRecentImagesInHistory;
  final bool includeAllImagesInHistory;
  final Function(bool) setIncludeAllImagesInHistory;
  final bool includeReasoningInHistory;
  final Function(bool) setIncludeReasoningInHistory;
  final bool includeToolResultsInHistory;
  final Function(bool) setIncludeToolResultsInHistory;

  // ── Tool calling ───────────────────────────────────────────
  final bool toolCallingEnabled;
  final Function(bool) setToolCallingEnabled;
  final bool toolDiscoveryMode;
  final Function(bool) setToolDiscoveryMode;
  final bool showToolCalls;
  final Function(bool) setShowToolCalls;

  // ── UI locale ──────────────────────────────────────────────
  final String uiLocale;
  final Function(String) setUiLocale;

  // ── Chat font size ─────────────────────────────────────────
  final double chatFontSize;
  final Function(double) setChatFontSize;

  // ── Chat font family ───────────────────────────────────────
  final String chatFontFamily;
  final Function(String) setChatFontFamily;

  // ── UI scale ───────────────────────────────────────────────
  final double uiScale;
  final Future<void> Function(double) setUiScale;

  const AppShellConfig({
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor,
    required this.dynamicColorEnabled,
    required this.setDynamicColorEnabled,
    required this.contrast,
    required this.setContrast,
    required this.uiFontFamily,
    required this.setUiFontFamily,
    required this.showReasoningTokens,
    required this.setShowReasoningTokens,
    required this.showModelInfo,
    required this.setShowModelInfo,
    required this.showTps,
    required this.setShowTps,
    required this.autoSendVoiceTranscription,
    required this.setAutoSendVoiceTranscription,
    required this.imageGenEnabled,
    required this.setImageGenEnabled,
    required this.imageGenDefaultSize,
    required this.setImageGenDefaultSize,
    required this.imageGenCustomWidth,
    required this.setImageGenCustomWidth,
    required this.imageGenCustomHeight,
    required this.setImageGenCustomHeight,
    required this.imageGenUseCustomSize,
    required this.setImageGenUseCustomSize,
    required this.includeRecentImagesInHistory,
    required this.setIncludeRecentImagesInHistory,
    required this.includeAllImagesInHistory,
    required this.setIncludeAllImagesInHistory,
    required this.includeReasoningInHistory,
    required this.setIncludeReasoningInHistory,
    required this.includeToolResultsInHistory,
    required this.setIncludeToolResultsInHistory,
    required this.toolCallingEnabled,
    required this.setToolCallingEnabled,
    required this.toolDiscoveryMode,
    required this.setToolDiscoveryMode,
    required this.showToolCalls,
    required this.setShowToolCalls,
    required this.uiLocale,
    required this.setUiLocale,
    required this.chatFontSize,
    required this.setChatFontSize,
    required this.chatFontFamily,
    required this.setChatFontFamily,
    required this.uiScale,
    required this.setUiScale,
  });
}
