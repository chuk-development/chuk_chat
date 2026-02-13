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

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_config.dart';
import 'root_wrapper_desktop.dart';
import 'root_wrapper_mobile.dart';

class RootWrapper extends StatelessWidget {
  final AppShellConfig config;

  const RootWrapper({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    // Compile-time platform detection for aggressive tree-shaking
    if (kPlatformMobile) {
      // When PLATFORM_MOBILE=true is set at build time,
      // desktop code is completely removed by tree-shaker
      return RootWrapperMobile(config: config);
    } else if (kPlatformDesktop) {
      // When PLATFORM_DESKTOP=true is set at build time,
      // mobile code is completely removed by tree-shaker
      return RootWrapperDesktop(config: config);
    }

    // Auto-detect mode (both branches included - larger binary)
    final bool isMobilePhone = _isMobilePhone(context);
    if (isMobilePhone) {
      return RootWrapperMobile(config: config);
    }

    return RootWrapperDesktop(config: config);
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
