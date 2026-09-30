// lib/voice/incoming/voice_call_permissions.dart
//
// What a voice call needs from Android, and how to ask for it.
//
//  * Microphone — before the FIRST call. The callkit foreground service only
//    takes the microphone type when RECORD_AUDIO is already granted when it
//    starts; without it the microphone goes silent once the app is in the
//    background.
//  * Notifications — the ring and the ongoing-call notification.
//  * Full-screen intent (Android 14+) — the ring over the lock screen. Not a
//    dialog: a system settings page.
//  * Background (battery optimisation exemption) — the relay socket that
//    carries the ring stays up while the phone sleeps.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';

/// One thing a voice call needs, in the order the settings show them.
enum VoiceCallGrant { microphone, notifications, fullScreenIntent, background }

abstract final class VoiceCallPermissions {
  /// Remembers that the full-screen settings page was opened once on its
  /// own; after that only the settings row opens it.
  static const String _fullScreenAskedKey = 'voice_call_full_screen_asked';

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Whether each grant is in place. Everything reads false off Android.
  static Future<Map<VoiceCallGrant, bool>> statuses() async {
    final Map<VoiceCallGrant, bool> out = <VoiceCallGrant, bool>{
      for (final VoiceCallGrant g in VoiceCallGrant.values) g: false,
    };
    if (!_android) return out;
    out[VoiceCallGrant.microphone] = await _granted(Permission.microphone);
    out[VoiceCallGrant.notifications] = await _granted(Permission.notification);
    out[VoiceCallGrant.background] = await _granted(
      Permission.ignoreBatteryOptimizations,
    );
    try {
      out[VoiceCallGrant.fullScreenIntent] =
          await FlutterCallkitIncoming.canUseFullScreenIntent();
    } catch (_) {
      out[VoiceCallGrant.fullScreenIntent] = false;
    }
    return out;
  }

  static Future<bool> _granted(Permission permission) async {
    try {
      return (await permission.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Asks for [grant]: the system dialog where there is one, else the system
  /// settings page (full-screen intent, or a permission the user refused for
  /// good).
  static Future<void> request(VoiceCallGrant grant) async {
    if (!_android) return;
    try {
      switch (grant) {
        case VoiceCallGrant.microphone:
          await _ask(Permission.microphone);
        case VoiceCallGrant.notifications:
          await _ask(Permission.notification);
        case VoiceCallGrant.background:
          await _ask(Permission.ignoreBatteryOptimizations);
        case VoiceCallGrant.fullScreenIntent:
          await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[voice-permissions] ${grant.name}: ${e.runtimeType}');
      }
    }
  }

  static Future<void> _ask(Permission permission) async {
    final PermissionStatus status = await permission.status;
    if (status.isGranted) return;
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return;
    }
    await permission.request();
  }

  /// The questions a voice-call build asks once at start: the microphone and
  /// notification dialogs when they are still open, then the full-screen
  /// settings page the first time only. Dialogs one after the other: Android
  /// runs one permission request at a time.
  static Future<void> requestUpFront() async {
    if (!_android) return;
    try {
      final PermissionStatus mic = await Permission.microphone.status;
      if (!mic.isGranted && !mic.isPermanentlyDenied) {
        await Permission.microphone.request();
      }
      final PermissionStatus notes = await Permission.notification.status;
      if (!notes.isGranted && !notes.isPermanentlyDenied) {
        await Permission.notification.request();
      }
      if (await FlutterCallkitIncoming.canUseFullScreenIntent()) return;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_fullScreenAskedKey) ?? false) return;
      await prefs.setBool(_fullScreenAskedKey, true);
      await FlutterCallkitIncoming.requestFullIntentPermission();
    } catch (e) {
      // Another request running, no activity yet: the settings rows remain.
      if (kDebugMode) {
        debugPrint('[voice-permissions] up front: ${e.runtimeType}');
      }
    }
  }
}

/// [MicPermission] over permission_handler (the incoming-call service).
class PermissionHandlerMic implements MicPermission {
  const PermissionHandlerMic();

  @override
  Future<bool> isGranted() async =>
      (await Permission.microphone.status).isGranted;

  /// A permission refused for good cannot be asked again from here: that is
  /// a "no", and the notice points to the settings.
  @override
  Future<bool> request() async {
    final PermissionStatus status = await Permission.microphone.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) return false;
    return (await Permission.microphone.request()).isGranted;
  }
}
