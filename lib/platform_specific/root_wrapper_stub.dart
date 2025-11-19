// lib/platform_specific/root_wrapper_stub.dart
// Stub implementation - should never be used in practice
// This exists only to satisfy the conditional import system

import 'package:flutter/material.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Platform not supported'),
      ),
    );
  }
}
