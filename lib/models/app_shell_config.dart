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

  // ── Film grain ─────────────────────────────────────────────
  final bool grainEnabled;
  final Function(bool) setGrainEnabled;

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

  // ── Tool calling ───────────────────────────────────────────
  final bool toolCallingEnabled;
  final Function(bool) setToolCallingEnabled;
  final bool toolDiscoveryMode;
  final Function(bool) setToolDiscoveryMode;
  final bool showToolCalls;
  final Function(bool) setShowToolCalls;
  final bool allowMarkdownToolCalls;
  final Function(bool) setAllowMarkdownToolCalls;

  const AppShellConfig({
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
    required this.toolCallingEnabled,
    required this.setToolCallingEnabled,
    required this.toolDiscoveryMode,
    required this.setToolDiscoveryMode,
    required this.showToolCalls,
    required this.setShowToolCalls,
    required this.allowMarkdownToolCalls,
    required this.setAllowMarkdownToolCalls,
  });
}
