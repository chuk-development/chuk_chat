import 'dart:convert';
import 'package:chuk_chat/utils/io_helper.dart';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// A tracked session record from the user_sessions table.
class SessionRecord {
  final String id;
  final String deviceName;
  final String platform;
  final String? appVersion;
  final DateTime lastSeenAt;
  final DateTime createdAt;
  final bool isActive;

  const SessionRecord({
    required this.id,
    required this.deviceName,
    required this.platform,
    this.appVersion,
    required this.lastSeenAt,
    required this.createdAt,
    required this.isActive,
  });

  factory SessionRecord.fromJson(Map<String, dynamic> json) {
    return SessionRecord(
      id: json['id'] as String,
      deviceName: json['device_name'] as String? ?? 'Unknown device',
      platform: json['platform'] as String? ?? 'unknown',
      appVersion: json['app_version'] as String?,
      lastSeenAt: DateTime.parse(json['last_seen_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      isActive: json['is_active'] as bool? ?? false,
    );
  }
}

/// Manages session tracking across devices.
///
/// Registers sessions on login, updates last-seen timestamps,
/// and allows users to list and revoke sessions.
class SessionTrackingService {
  const SessionTrackingService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _currentSessionIdKey = 'current_session_id';
  static const String _currentTokenHashKey = 'current_token_hash';
  static const String _remoteSignOutKey = 'was_remotely_signed_out';

  static String? _cachedSessionId;
  static String? _cachedTokenHash;

  /// Register the current device as an active session.
  /// Call after successful login.
  static Future<void> registerSession() async {
    try {
      final session = SupabaseService.auth.currentSession;
      final user = SupabaseService.auth.currentUser;
      if (session == null || user == null) return;

      final tokenHash = _hashToken(session.refreshToken ?? '');
      final deviceName = _getDeviceName();
      final platform = _getPlatformName();
      final appVersion = await _getAppVersion();

      // Upsert: if a session with this token hash exists, update it
      final response = await SupabaseService.client
          .from('user_sessions')
          .upsert(
            {
              'user_id': user.id,
              'device_name': deviceName,
              'platform': platform,
              'app_version': appVersion,
              'last_seen_at': DateTime.now().toUtc().toIso8601String(),
              'is_active': true,
              'refresh_token_hash': tokenHash,
            },
            onConflict: 'user_id,refresh_token_hash',
          )
          .select('id')
          .single();

      final sessionId = response['id'] as String;
      _cachedSessionId = sessionId;
      _cachedTokenHash = tokenHash;

      await _storage.write(key: _currentSessionIdKey, value: sessionId);
      await _storage.write(key: _currentTokenHashKey, value: tokenHash);

      // Clear any remote sign-out flag on fresh login
      await _storage.delete(key: _remoteSignOutKey);

      if (kDebugMode) {
        debugPrint('[SessionTracking] Registered session: $sessionId');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SessionTracking] Failed to register session: $e');
      }
    }
  }

  /// Update last_seen_at for the current session. Call on app resume.
  static Future<void> updateLastSeen() async {
    try {
      final sessionId = await getCurrentSessionId();
      if (sessionId == null) return;

      await SupabaseService.client
          .from('user_sessions')
          .update({'last_seen_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', sessionId);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SessionTracking] Failed to update last_seen: $e');
      }
    }
  }

  /// Load all active sessions for the current user.
  static Future<List<SessionRecord>> listActiveSessions() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return [];

    final data = await SupabaseService.client
        .from('user_sessions')
        .select()
        .eq('user_id', user.id)
        .eq('is_active', true)
        .order('last_seen_at', ascending: false);

    return (data as List).map((row) {
      return SessionRecord.fromJson(row as Map<String, dynamic>);
    }).toList();
  }

  /// Revoke a single session by calling the edge function.
  static Future<bool> revokeSession(String sessionId) async {
    try {
      final response = await SupabaseService.client.functions.invoke(
        'revoke-session',
        body: {'session_id': sessionId},
      );
      return response.status == 200;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SessionTracking] Failed to revoke session: $e');
      }
      return false;
    }
  }

  /// Revoke all sessions except the current one.
  static Future<bool> revokeAllOtherSessions() async {
    try {
      final tokenHash = await _getCurrentTokenHash();
      final response = await SupabaseService.client.functions.invoke(
        'revoke-session',
        body: {
          'revoke_all_others': true,
          'current_token_hash': tokenHash,
        },
      );
      return response.status == 200;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SessionTracking] Failed to revoke all others: $e');
      }
      return false;
    }
  }

  /// Get the current session's ID (locally stored).
  static Future<String?> getCurrentSessionId() async {
    if (_cachedSessionId != null) return _cachedSessionId;
    try {
      _cachedSessionId = await _storage.read(key: _currentSessionIdKey);
      return _cachedSessionId;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _getCurrentTokenHash() async {
    if (_cachedTokenHash != null) return _cachedTokenHash;
    try {
      _cachedTokenHash = await _storage.read(key: _currentTokenHashKey);
      return _cachedTokenHash;
    } catch (_) {
      return null;
    }
  }

  /// Mark that this device was remotely signed out.
  static Future<void> setRemotelySignedOut() async {
    try {
      await _storage.write(key: _remoteSignOutKey, value: 'true');
    } catch (_) {}
  }

  /// Check and consume the remote sign-out flag.
  /// Returns true once, then clears the flag.
  static Future<bool> wasRemotelySignedOut() async {
    try {
      final value = await _storage.read(key: _remoteSignOutKey);
      if (value == 'true') {
        await _storage.delete(key: _remoteSignOutKey);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Deactivate the current session in the DB (on explicit logout).
  static Future<void> deactivateCurrentSession() async {
    try {
      final sessionId = await getCurrentSessionId();
      if (sessionId == null) return;

      await SupabaseService.client
          .from('user_sessions')
          .update({'is_active': false})
          .eq('id', sessionId);

      _cachedSessionId = null;
      _cachedTokenHash = null;
      await _storage.delete(key: _currentSessionIdKey);
      await _storage.delete(key: _currentTokenHashKey);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SessionTracking] Failed to deactivate session: $e');
      }
    }
  }

  // --- Helpers ---

  static String _hashToken(String token) {
    final bytes = utf8.encode(token);
    return sha256.convert(bytes).toString();
  }

  static String _getDeviceName() {
    if (kIsWeb) return 'Web Browser';
    try {
      if (Platform.isAndroid) return 'Android Device';
      if (Platform.isIOS) return 'iPhone / iPad';
      if (Platform.isLinux) return 'Linux Desktop';
      if (Platform.isMacOS) return 'macOS Desktop';
      if (Platform.isWindows) return 'Windows Desktop';
    } catch (_) {}
    return 'Unknown Device';
  }

  static String _getPlatformName() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isLinux) return 'linux';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
    } catch (_) {}
    return 'unknown';
  }

  static Future<String> _getAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return 'unknown';
    }
  }
}
