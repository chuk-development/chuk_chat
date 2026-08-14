// lib/services/user_status_service.dart
//
// One cached view of `/v1/user/status` for the whole app.
//
// Before this, the settings page and the subscription page each fetched the
// plan on every open, so a user who has paid still watched a spinner decide
// whether they are a subscriber. The plan changes a few times a year at
// most; it belongs in a cache that is shown instantly and refreshed behind
// the UI.
//
// The cache is keyed by user id and dropped when the signed-in user
// changes, so a sign-out never leaks one account's plan into the next.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class UserStatusService {
  UserStatusService._();

  static const String _keyPrefix = 'user_status_cache_';

  /// A background refresh is skipped if the last one landed this recently.
  static const Duration _minRefreshInterval = Duration(seconds: 30);

  /// Latest known status. Widgets can listen to repaint when a refresh
  /// lands without holding their own copy.
  static final ValueNotifier<Map<String, dynamic>?> status =
      ValueNotifier<Map<String, dynamic>?>(null);

  static String? _loadedForUserId;
  static DateTime? _lastFetchAt;
  static Future<Map<String, dynamic>?>? _inFlight;

  static String? get _userId => SupabaseService.auth.currentUser?.id;

  /// Cache-first read.
  ///
  /// Returns the stored status right away and refreshes in the background.
  /// Only a cold cache (first run, or a different user) waits on the
  /// network.
  static Future<Map<String, dynamic>?> load({bool forceRefresh = false}) async {
    final String? uid = _userId;
    if (uid == null) {
      _reset();
      return null;
    }

    if (_loadedForUserId != uid) {
      _reset();
      _loadedForUserId = uid;
      status.value = await _readCache(uid);
    }

    if (status.value == null || forceRefresh) {
      return refresh();
    }

    final DateTime? last = _lastFetchAt;
    if (last == null ||
        DateTime.now().difference(last) > _minRefreshInterval) {
      unawaited(refresh());
    }
    return status.value;
  }

  /// Force a network read. Concurrent callers share one request.
  static Future<Map<String, dynamic>?> refresh() {
    final Future<Map<String, dynamic>?>? existing = _inFlight;
    if (existing != null) return existing;

    final Future<Map<String, dynamic>?> pending = _fetch();
    _inFlight = pending;
    return pending.whenComplete(() {
      _inFlight = null;
    });
  }

  /// Drop everything held for the signed-out user.
  static void clear() => _reset();

  static void _reset() {
    _loadedForUserId = null;
    _lastFetchAt = null;
    status.value = null;
  }

  static Future<Map<String, dynamic>?> _fetch() async {
    final String? uid = _userId;
    if (uid == null) return null;

    try {
      String? token;
      try {
        final session = await SupabaseService.refreshSession() ??
            SupabaseService.auth.currentSession;
        token = session?.accessToken;
      } catch (_) {
        token = null;
      }
      if (token == null || token.isEmpty) return status.value;

      // A hung request must not pin the in-flight future forever — every
      // later refresh would join it and the plan would stop updating for
      // the rest of the session.
      final response = await http
          .get(
            Uri.parse('${ApiConfigService.apiBaseUrl}/v1/user/status'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw StateError('user_status returned ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('user_status body was not a JSON object');
      }

      // The user may have signed out while the request was in flight.
      if (_userId != uid) return null;

      _lastFetchAt = DateTime.now();
      _loadedForUserId = uid;
      status.value = decoded;
      unawaited(_writeCache(uid, decoded));
      return decoded;
    } catch (error) {
      unawaited(
        DiagnosticsLogService.warning(
          'user_status',
          'Failed to fetch user status',
          data: {'error': error.toString()},
        ),
      );
      if (kDebugMode) {
        debugPrint('Failed to fetch user status: $error');
      }
      // Keep showing the cached plan rather than demoting a paying user to
      // "Free" because one request failed.
      return status.value;
    }
  }

  static Future<Map<String, dynamic>?> _readCache(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_keyPrefix$uid');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCache(
    String uid,
    Map<String, dynamic> value,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_keyPrefix$uid', jsonEncode(value));
    } catch (_) {
      // A cache write failure is not worth surfacing.
    }
  }
}
