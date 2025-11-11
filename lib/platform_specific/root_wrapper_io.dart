// lib/platform_specific/root_wrapper_io.dart
// Platform detection for dart:io platforms (mobile and desktop)
//
// This file uses compile-time constants (--dart-define) to enable aggressive tree-shaking:
//
// BUILD COMMANDS FOR OPTIMAL TREE-SHAKING:
// =========================================
// Desktop (excludes mobile code):
//   flutter build linux --dart-define=PLATFORM_DESKTOP=true --tree-shake-icons
//
// Mobile (excludes desktop code):
//   flutter build apk --dart-define=PLATFORM_MOBILE=true --tree-shake-icons
//
// Auto-detect (includes both, larger binary):
//   flutter build linux --tree-shake-icons
//   flutter build apk --tree-shake-icons
//
// When PLATFORM_DESKTOP=true or PLATFORM_MOBILE=true is set, the Dart compiler
// can completely remove the unused branch at compile time, resulting in smaller binaries.

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_config.dart';
import 'root_wrapper_desktop.dart';
import 'root_wrapper_mobile.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    // Compile-time platform detection for aggressive tree-shaking
    if (kPlatformMobile) {
      // When PLATFORM_MOBILE=true is set at build time,
      // desktop code is completely removed by tree-shaker
      return RootWrapperMobile(
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
      );
    } else if (kPlatformDesktop) {
      // When PLATFORM_DESKTOP=true is set at build time,
      // mobile code is completely removed by tree-shaker
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
      );
    }

    // Auto-detect mode (both branches included - larger binary)
    final bool isMobilePhone = _isMobilePhone(context);
    if (isMobilePhone) {
      return RootWrapperMobile(
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
      );
    }

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
    );
  }

  bool _isMobilePhone(BuildContext context) {
    // Web always uses desktop UI
    if (kIsWeb) return false;

    // Check platform type - these constants allow tree-shaking
    final TargetPlatform platform = defaultTargetPlatform;
    final bool isMobilePlatform =
        (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

    if (!isMobilePlatform) return false;

    // For mobile platforms, check screen size
    final double screenWidth = MediaQuery.of(context).size.width;
    return screenWidth < kTabletBreakpoint;
  }
}
