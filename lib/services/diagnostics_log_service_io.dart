// lib/services/diagnostics_log_service_io.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opt-in diagnostics logger that also works in release builds.
///
/// Privacy: this logger is intended for app/runtime metadata only.
/// Do not log chat content, credentials, tokens, passwords, or emails.
class DiagnosticsLogService {
  const DiagnosticsLogService._();

  static const String _enabledKey = 'diagnostics_logging_enabled';
  static const String _fileName = 'chuk_diagnostics.log';
  static const int _maxFileBytes = 2 * 1024 * 1024; // 2 MB

  static bool _isInitialized = false;
  static bool _enabled = false;
  static File? _logFile;
  static Future<void>? _initInFlight;
  static Future<void> _writeLock = Future<void>.value();

  // Frame timing monitor for lag diagnosis.
  static bool _frameMonitorAttached = false;
  static bool _isAppInForeground = true;
  static int _frameCount = 0;
  static int _jankCount = 0;
  static DateTime _lastFrameSummaryAt = DateTime.now();

  /// Hint from lifecycle service to suppress false jank while backgrounded.
  static void setAppInForeground(bool isForeground) {
    _isAppInForeground = isForeground;
    if (!isForeground) {
      _frameCount = 0;
      _jankCount = 0;
      _lastFrameSummaryAt = DateTime.now();
    }
  }

  static Future<void> initialize() {
    if (_isInitialized) return Future<void>.value();
    if (_initInFlight != null) return _initInFlight!;

    Future<void> run() async {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledKey) ?? false;
      if (_enabled) {
        await _ensureLogFile();
        _setFrameMonitoring(true);
        await _appendRaw(
          _encodeLine(
            level: 'INFO',
            area: 'diagnostics',
            message: 'Diagnostics logger initialized',
            data: {
              'release_mode': kReleaseMode,
              'platform': Platform.operatingSystem,
            },
          ),
        );
      }
      _isInitialized = true;
    }

    _initInFlight = run();
    return _initInFlight!.whenComplete(() {
      _initInFlight = null;
    });
  }

  static Future<bool> isEnabled() async {
    await initialize();
    return _enabled;
  }

  static Future<void> setEnabled(bool enabled) async {
    await initialize();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    _enabled = enabled;

    _setFrameMonitoring(enabled);

    if (enabled) {
      await _ensureLogFile();
      await info('diagnostics', 'Diagnostics logging enabled');
    } else {
      await _appendRaw(
        _encodeLine(
          level: 'INFO',
          area: 'diagnostics',
          message: 'Diagnostics logging disabled',
        ),
      );
    }
  }

  static Future<void> info(
    String area,
    String message, {
    Map<String, Object?>? data,
  }) => _write('INFO', area, message, data: data);

  static Future<void> warning(
    String area,
    String message, {
    Map<String, Object?>? data,
  }) => _write('WARN', area, message, data: data);

  static Future<void> error(
    String area,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    final merged = <String, Object?>{...?data};
    if (error != null) {
      merged['error'] = error.toString();
    }
    if (stackTrace != null) {
      merged['stack'] = stackTrace.toString().split('\n').take(3).join(' | ');
    }
    return _write('ERROR', area, message, data: merged);
  }

  static Future<void> timing(
    String area,
    String operation,
    int elapsedMs, {
    Map<String, Object?>? data,
  }) {
    final payload = <String, Object?>{
      'operation': operation,
      'elapsed_ms': elapsedMs,
      ...?data,
    };
    final level = elapsedMs >= 1500 ? 'WARN' : 'INFO';
    return _write(level, area, 'Timing', data: payload);
  }

  static Future<String?> getLogFilePath() async {
    await initialize();
    await _ensureLogFile();
    return _logFile?.path;
  }

  static Future<String> readRecentLogs({int maxLines = 250}) async {
    await initialize();
    await _ensureLogFile();
    final file = _logFile;
    if (file == null || !await file.exists()) {
      return '';
    }
    try {
      final contents = await file.readAsString();
      final lines = contents.split('\n').where((line) => line.isNotEmpty);
      final list = lines.toList(growable: false);
      if (list.length <= maxLines) {
        return list.join('\n');
      }
      return list.sublist(list.length - maxLines).join('\n');
    } catch (_) {
      return '';
    }
  }

  /// Returns a compact, focused report for the Linux model-menu flicker/jank
  /// issue, so users can share useful diagnostics without huge log dumps.
  static Future<String> readModelMenuDebugReport({
    int lookbackMinutes = 25,
    int maxEventsPerSection = 45,
  }) async {
    await initialize();
    await _ensureLogFile();
    final file = _logFile;
    if (file == null || !await file.exists()) {
      return '';
    }

    try {
      final cutoff = DateTime.now().toUtc().subtract(
        Duration(minutes: lookbackMinutes),
      );
      final lines = (await file.readAsLines()).where((line) => line.isNotEmpty);

      final List<Map<String, Object?>> parsed = <Map<String, Object?>>[];
      for (final line in lines) {
        final item = _parseLogLine(line);
        if (item == null) continue;
        final ts = _parseTimestamp(item['ts']);
        if (ts == null || ts.isBefore(cutoff)) continue;
        parsed.add(item);
      }

      if (parsed.isEmpty) {
        return 'No diagnostics entries in the last $lookbackMinutes minutes.';
      }

      const trackedAreas = <String>{
        'model_menu',
        'chat_ui',
        'performance',
        'startup',
        'tray',
      };

      final countsByArea = <String, int>{};
      int warnOrErrorCount = 0;
      final List<Map<String, Object?>> warnOrError = <Map<String, Object?>>[];
      final List<Map<String, Object?>> modelMenuEvents =
          <Map<String, Object?>>[];
      final List<Map<String, Object?>> uiEvents = <Map<String, Object?>>[];
      final List<Map<String, Object?>> perfEvents = <Map<String, Object?>>[];

      for (final entry in parsed) {
        final area = (entry['area'] ?? '').toString();
        if (!trackedAreas.contains(area)) continue;

        countsByArea[area] = (countsByArea[area] ?? 0) + 1;

        final level = (entry['level'] ?? '').toString();
        if (level == 'WARN' || level == 'ERROR') {
          warnOrErrorCount++;
          warnOrError.add(entry);
        }

        if (area == 'model_menu') {
          modelMenuEvents.add(entry);
        } else if (area == 'chat_ui' || area == 'tray' || area == 'startup') {
          uiEvents.add(entry);
        } else if (area == 'performance') {
          perfEvents.add(entry);
        }
      }

      List<Map<String, Object?>> tail(
        List<Map<String, Object?>> list,
        int maxEntries,
      ) {
        if (list.length <= maxEntries) return list;
        return list.sublist(list.length - maxEntries);
      }

      final sb = StringBuffer();
      sb.writeln('=== Chuk Chat Focused Debug Report (Model Menu) ===');
      sb.writeln(
        'generated_utc=${DateTime.now().toUtc().toIso8601String()} lookback_minutes=$lookbackMinutes',
      );
      sb.writeln(
        'entries_total=${parsed.length} warn_or_error=$warnOrErrorCount',
      );

      if (countsByArea.isNotEmpty) {
        final areaSummary = countsByArea.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        sb.writeln(
          'areas=${areaSummary.map((e) => '${e.key}:${e.value}').join(', ')}',
        );
      }

      void writeSection(String title, List<Map<String, Object?>> entries) {
        sb.writeln();
        sb.writeln('[$title]');
        if (entries.isEmpty) {
          sb.writeln('(none)');
          return;
        }
        for (final item in entries) {
          sb.writeln(_formatCompactEntry(item));
        }
      }

      writeSection('WARN/ERROR (recent)', tail(warnOrError, 25));
      writeSection(
        'Model Menu Events (recent)',
        tail(modelMenuEvents, maxEventsPerSection),
      );
      writeSection(
        'Chat/Startup/Tray Events (recent)',
        tail(uiEvents, maxEventsPerSection),
      );
      writeSection(
        'Performance Events (recent)',
        tail(perfEvents, maxEventsPerSection),
      );

      return sb.toString().trimRight();
    } catch (_) {
      return '';
    }
  }

  static Future<void> clearLogs() async {
    await initialize();
    await _ensureLogFile();
    final file = _logFile;
    if (file == null) return;
    try {
      await file.writeAsString('', flush: true);
    } catch (_) {
      // Ignore clear failures.
    }
  }

  static Map<String, Object?>? _parseLogLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        return Map<String, Object?>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  static DateTime? _parseTimestamp(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static String _formatCompactEntry(Map<String, Object?> entry) {
    final ts = _parseTimestamp(entry['ts']);
    final tsText = ts == null
        ? '--:--:--'
        : '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}:${ts.second.toString().padLeft(2, '0')}';
    final level = (entry['level'] ?? '').toString();
    final area = (entry['area'] ?? '').toString();
    final msg = (entry['msg'] ?? '').toString();
    final data = entry['data'];

    if (data is Map) {
      final compact = <String>[];
      const preferredKeys = <String>[
        'operation',
        'elapsed_ms',
        'show_scroll_button',
        'max_width',
        'last_stable_width',
        'total_ms',
        'build_ms',
        'raster_ms',
        'status_code',
        'models',
        'icon_path',
        'error',
      ];
      for (final key in preferredKeys) {
        if (!data.containsKey(key)) continue;
        compact.add('$key=${data[key]}');
        if (compact.length >= 5) break;
      }
      final suffix = compact.isEmpty ? '' : ' ${compact.join(' ')}';
      return '$tsText $level $area $msg$suffix';
    }

    return '$tsText $level $area $msg';
  }

  static Future<void> _write(
    String level,
    String area,
    String message, {
    Map<String, Object?>? data,
  }) async {
    await initialize();
    if (!_enabled) return;

    await _ensureLogFile();
    final line = _encodeLine(
      level: level,
      area: area,
      message: message,
      data: data,
    );
    await _appendRaw(line);
  }

  static Future<void> _ensureLogFile() async {
    if (_logFile != null) return;

    try {
      final baseDir = await getApplicationSupportDirectory();
      final logDir = Directory('${baseDir.path}${Platform.pathSeparator}logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      _logFile = File('${logDir.path}${Platform.pathSeparator}$_fileName');
      if (!await _logFile!.exists()) {
        await _logFile!.create(recursive: true);
      }
    } catch (error) {
      _logFile = null;
      if (kDebugMode) {
        debugPrint('Diagnostics log file init failed: $error');
      }
    }
  }

  static Future<void> _appendRaw(String line) async {
    _writeLock = _writeLock.catchError((_) {}).then((_) async {
      final file = _logFile;
      if (file == null) return;

      await _rotateIfNeeded();

      final currentFile = _logFile;
      if (currentFile == null) return;
      await currentFile.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    });

    try {
      await _writeLock;
    } catch (_) {
      // Ignore logging failures.
    }
  }

  static Future<void> _rotateIfNeeded() async {
    final file = _logFile;
    if (file == null || !await file.exists()) return;

    try {
      final len = await file.length();
      if (len < _maxFileBytes) return;

      final backup = File('${file.path}.1');
      if (await backup.exists()) {
        await backup.delete();
      }
      await file.rename(backup.path);
      final newFile = File(file.path);
      await newFile.create(recursive: true);
      _logFile = newFile;
    } catch (_) {
      _logFile = null;
      // Ignore rotate failures.
    }
  }

  static String _encodeLine({
    required String level,
    required String area,
    required String message,
    Map<String, Object?>? data,
  }) {
    final payload = <String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'area': area,
      'msg': message,
      if (data != null && data.isNotEmpty) 'data': _sanitizeData(data),
    };
    return jsonEncode(payload);
  }

  static Map<String, Object?> _sanitizeData(Map<String, Object?> data) {
    final sanitized = <String, Object?>{};
    data.forEach((key, value) {
      if (value == null || value is num || value is bool || value is String) {
        sanitized[key] = value;
      } else if (value is DateTime) {
        sanitized[key] = value.toUtc().toIso8601String();
      } else {
        sanitized[key] = value.toString();
      }
    });
    return sanitized;
  }

  static void _setFrameMonitoring(bool enabled) {
    if (enabled) {
      if (_frameMonitorAttached) return;
      SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
      _frameMonitorAttached = true;
      return;
    }

    if (!_frameMonitorAttached) return;
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _frameMonitorAttached = false;
    _frameCount = 0;
    _jankCount = 0;
  }

  static void _onFrameTimings(List<FrameTiming> timings) {
    if (!_enabled || !_isAppInForeground) return;

    for (final timing in timings) {
      _frameCount++;
      final totalMs = timing.totalSpan.inMicroseconds / 1000.0;
      final buildMs = timing.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000.0;
      final renderMs = buildMs + rasterMs;

      if (totalMs > 33.0 && renderMs > 8.0) {
        _jankCount++;
      }
      if (totalMs > 120.0 && (buildMs > 16.0 || rasterMs > 16.0)) {
        unawaited(
          warning(
            'performance',
            'Severe frame jank detected',
            data: {
              'total_ms': totalMs.toStringAsFixed(1),
              'build_ms': buildMs.toStringAsFixed(1),
              'raster_ms': rasterMs.toStringAsFixed(1),
            },
          ),
        );
      }
    }

    final now = DateTime.now();
    if (now.difference(_lastFrameSummaryAt) >= const Duration(seconds: 15) &&
        _frameCount > 0) {
      final jankPct = (_jankCount / _frameCount) * 100.0;
      unawaited(
        info(
          'performance',
          'Frame timing summary',
          data: {
            'frames': _frameCount,
            'jank_frames': _jankCount,
            'jank_percent': jankPct.toStringAsFixed(1),
          },
        ),
      );
      _frameCount = 0;
      _jankCount = 0;
      _lastFrameSummaryAt = now;
    }
  }
}
