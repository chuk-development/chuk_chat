// lib/platform_specific/root_wrapper_stub.dart
// Web implementation - uses desktop layout
import 'package:flutter/material.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';

/// Web wrapper - renders desktop UI since web is a desktop-like environment
class RootWrapper extends StatelessWidget {
  final AppShellConfig config;

  const RootWrapper({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    // Web uses desktop layout
    return RootWrapperDesktop(config: config);
  }
}
