// lib/services/device_services.dart
//
// Native device features service.
// Provides GPS, calendar, alarms, notifications, SMS drafts, and email drafts.
// Uses singleton pattern. Wraps all debugPrint in kDebugMode checks.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:add_2_calendar/add_2_calendar.dart' as cal;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;

/// Singleton service providing access to native device features.
///
/// Capabilities vary by platform — use [getPlatformCapabilities] to check
/// what is supported at runtime.
class DeviceServices {
  static final DeviceServices _instance = DeviceServices._internal();
  factory DeviceServices() => _instance;
  DeviceServices._internal();

  /// Whether timezone data has been initialized.
  bool _tzInitialized = false;

  /// In-memory alarm registry: id → {title, dateTime, timer}.
  final Map<int, Map<String, dynamic>> _alarms = {};

  /// Auto-incrementing alarm ID counter.
  int _nextAlarmId = 1;

  /// Notification plugin (shared with NotificationService but independent init
  /// for alarm/timer use).
  FlutterLocalNotificationsPlugin? _notificationsPlugin;

  /// Ensure timezone data is loaded once.
  void _ensureTimezones() {
    if (!_tzInitialized) {
      tz.initializeTimeZones();
      _tzInitialized = true;
    }
  }

  /// Lazy-initialize the notifications plugin for alarms.
  Future<FlutterLocalNotificationsPlugin> _getNotificationsPlugin() async {
    if (_notificationsPlugin != null) return _notificationsPlugin!;

    _notificationsPlugin = FlutterLocalNotificationsPlugin();

    const androidSettings = AndroidInitializationSettings('ic_notification');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );

    await _notificationsPlugin!.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
        linux: linuxSettings,
      ),
    );

    return _notificationsPlugin!;
  }

  // ---------------------------------------------------------------------------
  // GPS / Location
  // ---------------------------------------------------------------------------

  /// Get the device's current GPS position.
  ///
  /// Returns structured error on platforms without GPS hardware
  /// (Linux, Windows).
  Future<Map<String, dynamic>> getCurrentLocation() async {
    if (Platform.isLinux || Platform.isWindows) {
      return {
        'success': false,
        'error': 'GPS is not available on ${Platform.operatingSystem}',
        'platform': Platform.operatingSystem,
      };
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return {
          'success': false,
          'error': 'Location services are disabled on this device',
        };
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return {
            'success': false,
            'error': 'Location permission denied by user',
          };
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return {
          'success': false,
          'error':
              'Location permission permanently denied. '
              'Enable in device settings.',
        };
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      return {
        'success': true,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'altitude': position.altitude,
        'accuracy': position.accuracy,
        'speed': position.speed,
        'heading': position.heading,
        'timestamp': position.timestamp.toIso8601String(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Get the last known device position (cached, may be stale).
  Future<Map<String, dynamic>> getLastKnownLocation() async {
    if (Platform.isLinux || Platform.isWindows) {
      return {
        'success': false,
        'error': 'GPS is not available on ${Platform.operatingSystem}',
        'platform': Platform.operatingSystem,
      };
    }

    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position == null) {
        return {'success': false, 'error': 'No cached location available'};
      }
      return {
        'success': true,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'altitude': position.altitude,
        'accuracy': position.accuracy,
        'timestamp': position.timestamp.toIso8601String(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Calculate distance in meters between two lat/lng points.
  double calculateDistance(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {
    return Geolocator.distanceBetween(startLat, startLng, endLat, endLng);
  }

  // ---------------------------------------------------------------------------
  // Calendar
  // ---------------------------------------------------------------------------

  /// Create a calendar event.
  ///
  /// Uses native calendar via add_2_calendar on mobile/macOS.
  /// Falls back to .ics file via xdg-open on Linux, and Google Calendar URL
  /// as final fallback on other platforms.
  Future<Map<String, dynamic>> createCalendarEvent({
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    String? description,
    String? location,
    bool allDay = false,
  }) async {
    try {
      // Mobile + macOS: native calendar
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        final event = cal.Event(
          title: title,
          description: description ?? '',
          location: location ?? '',
          startDate: startDate,
          endDate: endDate,
          allDay: allDay,
        );
        cal.Add2Calendar.addEvent2Cal(event);
        return {
          'success': true,
          'method': 'native',
          'message': 'Calendar event dialog opened',
        };
      }

      // Linux/Windows: generate .ics file and open
      if (Platform.isLinux || Platform.isWindows) {
        return await _createIcsEvent(
          title: title,
          startDate: startDate,
          endDate: endDate,
          description: description,
          location: location,
          allDay: allDay,
        );
      }

      // Fallback: Google Calendar URL
      return _createCalendarUrl(
        title: title,
        startDate: startDate,
        endDate: endDate,
        description: description,
        location: location,
      );
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Generate an .ics file and open it with the default application.
  Future<Map<String, dynamic>> _createIcsEvent({
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    String? description,
    String? location,
    bool allDay = false,
  }) async {
    final buffer = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//ChukChat//EN')
      ..writeln('BEGIN:VEVENT')
      ..writeln('DTSTART:${_icsDateTime(startDate, allDay)}')
      ..writeln('DTEND:${_icsDateTime(endDate, allDay)}')
      ..writeln('SUMMARY:${_icsEscape(title)}');

    if (description != null && description.isNotEmpty) {
      buffer.writeln('DESCRIPTION:${_icsEscape(description)}');
    }
    if (location != null && location.isNotEmpty) {
      buffer.writeln('LOCATION:${_icsEscape(location)}');
    }

    buffer
      ..writeln('END:VEVENT')
      ..writeln('END:VCALENDAR');

    final tempDir = Directory.systemTemp;
    final sanitized = title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    final fileName = sanitized.isEmpty
        ? 'event.ics'
        : '${sanitized.substring(0, sanitized.length.clamp(0, 40))}.ics';
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsString(buffer.toString());

    if (Platform.isLinux) {
      await Process.run('xdg-open', [file.path]);
    } else if (Platform.isWindows) {
      await Process.run('start', ['', file.path], runInShell: true);
    }

    return {
      'success': true,
      'method': 'ics_file',
      'filePath': file.path,
      'message': 'Calendar event file opened with default application',
    };
  }

  /// Build a Google Calendar URL as last-resort fallback.
  Map<String, dynamic> _createCalendarUrl({
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    String? description,
    String? location,
  }) {
    final params = <String, String>{
      'action': 'TEMPLATE',
      'text': title,
      'dates': '${_googleDateTime(startDate)}/${_googleDateTime(endDate)}',
    };
    if (description != null) params['details'] = description;
    if (location != null) params['location'] = location;

    final uri = Uri.https('calendar.google.com', '/calendar/render', params);

    return {
      'success': true,
      'method': 'url',
      'url': uri.toString(),
      'message': 'Use this URL to create the calendar event',
    };
  }

  /// Format DateTime for ICS (UTC).
  String _icsDateTime(DateTime dt, bool allDay) {
    final utc = dt.toUtc();
    if (allDay) {
      return '${utc.year}${_pad(utc.month)}${_pad(utc.day)}';
    }
    return '${utc.year}${_pad(utc.month)}${_pad(utc.day)}'
        'T${_pad(utc.hour)}${_pad(utc.minute)}${_pad(utc.second)}Z';
  }

  /// Format DateTime for Google Calendar URL.
  String _googleDateTime(DateTime dt) {
    final utc = dt.toUtc();
    return '${utc.year}${_pad(utc.month)}${_pad(utc.day)}'
        'T${_pad(utc.hour)}${_pad(utc.minute)}${_pad(utc.second)}Z';
  }

  /// Escape special characters for ICS format.
  String _icsEscape(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll(';', '\\;')
        .replaceAll(',', '\\,')
        .replaceAll('\n', '\\n');
  }

  /// Zero-pad a number to two digits.
  String _pad(int n) => n.toString().padLeft(2, '0');

  // ---------------------------------------------------------------------------
  // Alarms & Timers
  // ---------------------------------------------------------------------------

  /// Set an alarm at a specific time.
  ///
  /// Returns the alarm ID so it can be cancelled later.
  Future<Map<String, dynamic>> setAlarm({
    required String title,
    required DateTime dateTime,
    String? description,
  }) async {
    _ensureTimezones();

    try {
      final now = DateTime.now();
      final delay = dateTime.difference(now);

      if (delay.isNegative) {
        return {'success': false, 'error': 'Cannot set alarm in the past'};
      }

      final id = _nextAlarmId++;

      // Schedule a notification when the alarm fires
      final timer = Timer(delay, () async {
        await _fireAlarmNotification(id, title, description);
        _alarms.remove(id);
        _persistAlarms();
      });

      _alarms[id] = {
        'title': title,
        'description': description,
        'dateTime': dateTime.toIso8601String(),
        'timer': timer,
      };

      await _persistAlarms();

      if (kDebugMode) {
        debugPrint('[DeviceServices] Alarm #$id set for $dateTime');
      }

      return {
        'success': true,
        'alarmId': id,
        'dateTime': dateTime.toIso8601String(),
        'message': 'Alarm "$title" set for ${dateTime.toLocal()}',
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Set a countdown timer for a duration from now.
  Future<Map<String, dynamic>> setTimer({
    required String title,
    required Duration duration,
    String? description,
  }) async {
    final fireAt = DateTime.now().add(duration);
    return setAlarm(
      title: title,
      dateTime: fireAt,
      description: description ?? 'Timer: ${_formatDuration(duration)}',
    );
  }

  /// Cancel an active alarm by its ID.
  Map<String, dynamic> cancelAlarm(int alarmId) {
    final alarm = _alarms.remove(alarmId);
    if (alarm == null) {
      return {'success': false, 'error': 'Alarm #$alarmId not found'};
    }

    final timer = alarm['timer'] as Timer?;
    timer?.cancel();
    _persistAlarms();

    if (kDebugMode) {
      debugPrint('[DeviceServices] Alarm #$alarmId cancelled');
    }

    return {'success': true, 'message': 'Alarm #$alarmId cancelled'};
  }

  /// List all active alarms.
  Map<String, dynamic> listAlarms() {
    final alarms = _alarms.entries.map((e) {
      return {
        'id': e.key,
        'title': e.value['title'],
        'description': e.value['description'],
        'dateTime': e.value['dateTime'],
        'isActive': (e.value['timer'] as Timer?)?.isActive ?? false,
      };
    }).toList();

    return {'success': true, 'alarms': alarms, 'count': alarms.length};
  }

  /// Fire a notification when an alarm triggers.
  Future<void> _fireAlarmNotification(
    int id,
    String title,
    String? description,
  ) async {
    try {
      final plugin = await _getNotificationsPlugin();
      await plugin.show(
        id + 100000, // Offset to avoid collision with other notifications
        'Alarm: $title',
        description ?? 'Your alarm "$title" is firing!',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'alarms',
            'Alarms & Timers',
            channelDescription: 'Alarm and timer notifications',
            importance: Importance.max,
            priority: Priority.max,
            enableVibration: true,
            playSound: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
          linux: LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DeviceServices] Failed to show alarm notification: $e');
      }
    }
  }

  /// Persist alarm metadata (not the Timer itself) to SharedPreferences.
  Future<void> _persistAlarms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serializable = <String, dynamic>{};
      for (final entry in _alarms.entries) {
        serializable[entry.key.toString()] = {
          'title': entry.value['title'],
          'description': entry.value['description'],
          'dateTime': entry.value['dateTime'],
        };
      }
      await prefs.setString('device_alarms', jsonEncode(serializable));
    } catch (_) {
      // Non-critical persistence failure
    }
  }

  /// Restore alarms from SharedPreferences on startup.
  ///
  /// Alarms whose fire time has passed are discarded.
  Future<void> restoreAlarms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('device_alarms');
      if (raw == null) return;

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();

      for (final entry in data.entries) {
        final id = int.tryParse(entry.key);
        if (id == null) continue;

        final info = entry.value as Map<String, dynamic>;
        final dateTime = DateTime.tryParse(info['dateTime'] as String? ?? '');
        if (dateTime == null || dateTime.isBefore(now)) continue;

        if (id >= _nextAlarmId) _nextAlarmId = id + 1;

        final delay = dateTime.difference(now);
        final timer = Timer(delay, () async {
          await _fireAlarmNotification(
            id,
            info['title'] as String? ?? 'Alarm',
            info['description'] as String?,
          );
          _alarms.remove(id);
          _persistAlarms();
        });

        _alarms[id] = {
          'title': info['title'],
          'description': info['description'],
          'dateTime': info['dateTime'],
          'timer': timer,
        };
      }

      if (kDebugMode) {
        debugPrint('[DeviceServices] Restored ${_alarms.length} alarms');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DeviceServices] Failed to restore alarms: $e');
      }
    }
  }

  /// Format a duration as human-readable text.
  String _formatDuration(Duration d) {
    final parts = <String>[];
    if (d.inHours > 0) parts.add('${d.inHours}h');
    final mins = d.inMinutes % 60;
    if (mins > 0) parts.add('${mins}m');
    final secs = d.inSeconds % 60;
    if (secs > 0 && d.inHours == 0) parts.add('${secs}s');
    return parts.isEmpty ? '0s' : parts.join(' ');
  }

  // ---------------------------------------------------------------------------
  // SMS
  // ---------------------------------------------------------------------------

  /// Open the default SMS app with a pre-filled draft.
  ///
  /// Only supported on mobile platforms (Android, iOS).
  Future<Map<String, dynamic>> createSmsDraft({
    required String phoneNumber,
    String? body,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return {
        'success': false,
        'error':
            'SMS is not available on ${Platform.operatingSystem}. '
            'SMS requires a mobile device.',
        'platform': Platform.operatingSystem,
      };
    }

    try {
      final encodedBody = body != null ? Uri.encodeComponent(body) : '';
      final uri = Uri.parse(
        'sms:$phoneNumber${body != null ? '?body=$encodedBody' : ''}',
      );

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        return {
          'success': true,
          'message': 'SMS draft opened for $phoneNumber',
        };
      }
      return {'success': false, 'error': 'Could not open SMS application'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ---------------------------------------------------------------------------
  // Email (mailto: URI)
  // ---------------------------------------------------------------------------

  /// Open the default email client with a pre-filled draft.
  ///
  /// Supported on all platforms.
  Future<Map<String, dynamic>> createEmailDraft({
    required String to,
    String? subject,
    String? body,
    List<String>? cc,
    List<String>? bcc,
  }) async {
    try {
      final params = <String, String>{};
      if (subject != null) params['subject'] = subject;
      if (body != null) params['body'] = body;
      if (cc != null && cc.isNotEmpty) params['cc'] = cc.join(',');
      if (bcc != null && bcc.isNotEmpty) params['bcc'] = bcc.join(',');

      final uri = Uri(
        scheme: 'mailto',
        path: to,
        queryParameters: params.isNotEmpty ? params : null,
      );

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        return {'success': true, 'message': 'Email draft opened for $to'};
      }
      return {'success': false, 'error': 'Could not open email application'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ---------------------------------------------------------------------------
  // Notifications
  // ---------------------------------------------------------------------------

  /// Show an immediate local notification.
  Future<Map<String, dynamic>> showNotification({
    required String title,
    required String body,
    int? id,
  }) async {
    try {
      final plugin = await _getNotificationsPlugin();
      final notifId = id ?? DateTime.now().millisecondsSinceEpoch % 100000;

      await plugin.show(
        notifId,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'device_services',
            'Device Services',
            channelDescription: 'Notifications from device services',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
          linux: LinuxNotificationDetails(),
        ),
      );

      return {
        'success': true,
        'notificationId': notifId,
        'message': 'Notification shown',
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ---------------------------------------------------------------------------
  // Platform capabilities
  // ---------------------------------------------------------------------------

  /// Returns a map describing which features are supported on the current
  /// platform.
  Map<String, dynamic> getPlatformCapabilities() {
    final platform = Platform.operatingSystem;
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final isDesktop =
        Platform.isLinux || Platform.isWindows || Platform.isMacOS;

    return {
      'platform': platform,
      'gps': {
        'supported': isMobile || Platform.isMacOS,
        'note': isMobile
            ? 'Full GPS support'
            : Platform.isMacOS
            ? 'Core Location (may need permission)'
            : 'No GPS hardware on desktop',
      },
      'calendar': {
        'supported': true,
        'method': (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)
            ? 'native'
            : 'ics_file',
        'note': (Platform.isLinux || Platform.isWindows)
            ? 'Creates .ics file opened with default calendar app'
            : 'Opens native calendar dialog',
      },
      'alarms': {
        'supported': true,
        'method': 'local_notification',
        'note': 'In-app timer with notification on fire',
      },
      'sms': {
        'supported': isMobile,
        'note': isMobile
            ? 'Opens default SMS app with draft'
            : 'SMS requires a mobile device',
      },
      'email': {
        'supported': true,
        'note': 'Opens default email client via mailto: URI',
      },
      'notifications': {
        'supported': true,
        'note': isDesktop
            ? 'Desktop notifications via system tray'
            : 'Mobile push-style notifications',
      },
    };
  }
}
