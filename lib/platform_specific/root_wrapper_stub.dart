// lib/platform_specific/root_wrapper_stub.dart
// Web implementation - uses desktop layout
import 'package:flutter/material.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';

/// Web wrapper - renders desktop UI since web is a desktop-like environment
class RootWrapper extends StatelessWidget {
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;
  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor;
  final bool grainEnabled;
  final Function(bool) setGrainEnabled;
  final bool showReasoningTokens;
  final Function(bool) setShowReasoningTokens;
  final bool showModelInfo;
  final Function(bool) setShowModelInfo;
  final bool showTps;
  final Function(bool) setShowTps;
  final bool autoSendVoiceTranscription;
  final Function(bool) setAutoSendVoiceTranscription;
  // Image generation settings
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

  const RootWrapper({
    super.key,
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
  });

  @override
  Widget build(BuildContext context) {
    // Web uses desktop layout
    return RootWrapperDesktop(
      currentThemeMode: currentThemeMode,
      currentAccentColor: currentAccentColor,
      currentIconFgColor: currentIconFgColor,
      currentBgColor: currentBgColor,
      setThemeMode: setThemeMode,
      setAccentColor: setAccentColor,
      setIconFgColor: setIconFgColor,
      setBgColor: setBgColor,
      grainEnabled: grainEnabled,
      setGrainEnabled: setGrainEnabled,
      showReasoningTokens: showReasoningTokens,
      setShowReasoningTokens: setShowReasoningTokens,
      showModelInfo: showModelInfo,
      setShowModelInfo: setShowModelInfo,
      showTps: showTps,
      setShowTps: setShowTps,
      autoSendVoiceTranscription: autoSendVoiceTranscription,
      setAutoSendVoiceTranscription: setAutoSendVoiceTranscription,
      imageGenEnabled: imageGenEnabled,
      setImageGenEnabled: setImageGenEnabled,
      imageGenDefaultSize: imageGenDefaultSize,
      setImageGenDefaultSize: setImageGenDefaultSize,
      imageGenCustomWidth: imageGenCustomWidth,
      setImageGenCustomWidth: setImageGenCustomWidth,
      imageGenCustomHeight: imageGenCustomHeight,
      setImageGenCustomHeight: setImageGenCustomHeight,
      imageGenUseCustomSize: imageGenUseCustomSize,
      setImageGenUseCustomSize: setImageGenUseCustomSize,
    );
  }
}
