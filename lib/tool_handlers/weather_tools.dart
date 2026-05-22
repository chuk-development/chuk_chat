import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/multiplex_tool_proxy.dart';

/// Weather via server-side Brave Rich Callback proxy.
///
/// The server calls Brave `/web/search?enable_rich_callback=1` to get a
/// `callback_key`, then `/web/rich?callback_key=…` for the structured
/// weather payload. No Open-Meteo fallback.
Future<String> executeWeather({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
  http.Client? client,
}) async {
  final location = (args['location'] as String? ?? '').trim();
  final latRaw = args['latitude'];
  final lonRaw = args['longitude'];
  if (location.isEmpty && !(latRaw is num && lonRaw is num)) {
    return 'Error: Provide "location" (city name) or '
        '"latitude"/"longitude"';
  }

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  final action = (args['action'] as String? ?? 'current').toLowerCase().trim();
  final days = (args['days'] as num?)?.toInt();
  final hours = (args['hours'] as num?)?.toInt();

  final query = _buildQuery(
    location: location,
    latitude: latRaw is num ? latRaw.toDouble() : null,
    longitude: lonRaw is num ? lonRaw.toDouble() : null,
    action: action,
    days: days,
    hours: hours,
  );

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final body = {
      'query': query,
      'country': 'DE',
      'search_lang': 'de',
    };

    Map<String, dynamic>? data;
    final mux = await tryToolViaMultiplex(tool: 'brave_rich', payload: body);
    if (mux.isError) {
      return 'Weather error: ${mux.error}';
    }
    if (mux.isOk) {
      data = mux.body;
    } else {
      final response = await effectiveClient
          .post(
            Uri.parse('$baseUrl/v1/tools/brave/rich'),
            headers: {'Content-Type': 'application/json', ...serverHeaders},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 404) {
        return 'No weather data from Brave for "$query". Try rephrasing the '
            'location or a different action.';
      }
      if (response.statusCode != 200) {
        final errorData = _tryDecodeJsonObject(response.body);
        final error = errorData?['error']?.toString();
        return 'Weather error: ${error ?? 'HTTP ${response.statusCode}'}';
      }

      data = _tryDecodeJsonObject(response.body);
    }
    if (data == null) {
      return 'Weather error: Invalid server response';
    }

    final vertical = data['vertical']?.toString() ?? '';
    final payload = data['data'];
    if (payload is! Map) {
      return 'No weather data in response for "$query"';
    }

    return _formatWeather(
      locationLabel: location.isNotEmpty ? location : query,
      action: action,
      vertical: vertical,
      payload: Map<String, dynamic>.from(payload),
    );
  } on TimeoutException {
    return 'Weather request timed out. Please try again.';
  } catch (e) {
    return 'Weather error: $e';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

String _buildQuery({
  required String location,
  double? latitude,
  double? longitude,
  required String action,
  int? days,
  int? hours,
}) {
  final locationPart = location.isNotEmpty
      ? location
      : (latitude != null && longitude != null
            ? '$latitude,$longitude'
            : '');

  switch (action) {
    case 'forecast':
      final n = (days ?? 7).clamp(1, 16);
      return '$n day weather forecast $locationPart'.trim();
    case 'hourly':
      final n = (hours ?? 24).clamp(1, 48);
      return 'hourly weather next $n hours $locationPart'.trim();
    case 'current':
    default:
      return 'weather $locationPart'.trim();
  }
}

Map<String, dynamic>? _tryDecodeJsonObject(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // ignore
  }
  return null;
}

String _formatWeather({
  required String locationLabel,
  required String action,
  required String vertical,
  required Map<String, dynamic> payload,
}) {
  final buf = StringBuffer();
  final weather = _pickMap(payload, const [
    'weather',
    'data',
    'result',
    'results',
    'forecast',
  ]);
  final source = weather ?? payload;

  final place = _pickString(source, const [
    'location',
    'place',
    'title',
    'name',
    'query',
  ]) ?? locationLabel;

  buf.writeln('Weather — $place (source: Brave rich${vertical.isNotEmpty ? '/$vertical' : ''})');

  final current = _pickMap(source, const [
    'current',
    'now',
    'current_condition',
    'current_conditions',
  ]);
  if (current != null) {
    _writeCurrent(buf, current);
  } else {
    // Top-level condition fields
    _writeCurrent(buf, source);
  }

  if (action == 'forecast' || action == 'current') {
    final daily = _pickList(source, const [
      'forecast',
      'daily',
      'days',
      'forecast_days',
      'daily_forecast',
    ]);
    if (daily != null && daily.isNotEmpty) {
      buf.writeln();
      buf.writeln('Forecast:');
      for (final entry in daily) {
        if (entry is Map) {
          _writeDay(buf, Map<String, dynamic>.from(entry));
        }
      }
    }
  }

  if (action == 'hourly') {
    final hourly = _pickList(source, const [
      'hourly',
      'hours',
      'hour_forecast',
      'hourly_forecast',
    ]);
    if (hourly != null && hourly.isNotEmpty) {
      buf.writeln();
      buf.writeln('Hourly:');
      for (final entry in hourly) {
        if (entry is Map) {
          _writeHour(buf, Map<String, dynamic>.from(entry));
        }
      }
    }
  }

  final result = buf.toString().trimRight();
  if (result.split('\n').length <= 1) {
    // Fallback: dump raw JSON so the model still has something to work with.
    return '$result\nRaw payload:\n${jsonEncode(payload)}';
  }
  return result;
}

void _writeCurrent(StringBuffer buf, Map<String, dynamic> src) {
  final temp = _pickString(src, const [
    'temperature',
    'temp',
    'temp_c',
    'temperature_c',
    'current_temp',
  ]);
  final feels = _pickString(src, const [
    'feels_like',
    'feelslike',
    'apparent_temperature',
    'feels_like_c',
  ]);
  final condition = _pickString(src, const [
    'condition',
    'description',
    'summary',
    'weather',
    'conditions',
    'text',
  ]);
  final humidity = _pickString(src, const ['humidity', 'humidity_pct']);
  final wind = _pickString(src, const ['wind', 'wind_speed', 'windspeed']);
  final windDir = _pickString(src, const [
    'wind_direction',
    'wind_dir',
    'winddir',
  ]);
  final precip = _pickString(src, const ['precipitation', 'precip', 'rain']);
  final pressure = _pickString(src, const ['pressure', 'surface_pressure']);
  final uv = _pickString(src, const ['uv', 'uv_index']);
  final high = _pickString(src, const ['high', 'max_temp', 'temp_max', 'high_temp']);
  final low = _pickString(src, const ['low', 'min_temp', 'temp_min', 'low_temp']);

  if (condition != null) buf.writeln('Condition: $condition');
  if (temp != null) {
    final pieces = <String>[temp];
    if (feels != null && feels != temp) pieces.add('(feels $feels)');
    buf.writeln('Temperature: ${pieces.join(' ')}');
  }
  if (high != null || low != null) {
    buf.writeln('High/Low: ${high ?? '?'} / ${low ?? '?'}');
  }
  if (humidity != null) buf.writeln('Humidity: $humidity');
  if (wind != null) {
    buf.writeln('Wind: $wind${windDir != null ? ' $windDir' : ''}');
  }
  if (precip != null) buf.writeln('Precipitation: $precip');
  if (pressure != null) buf.writeln('Pressure: $pressure');
  if (uv != null) buf.writeln('UV: $uv');
}

void _writeDay(StringBuffer buf, Map<String, dynamic> day) {
  final date = _pickString(day, const ['date', 'day', 'time', 'label']);
  final cond = _pickString(day, const [
    'condition',
    'description',
    'summary',
    'weather',
  ]);
  final high = _pickString(day, const ['high', 'max_temp', 'temp_max', 'high_temp']);
  final low = _pickString(day, const ['low', 'min_temp', 'temp_min', 'low_temp']);
  final precip = _pickString(day, const ['precipitation', 'precip', 'rain']);
  final wind = _pickString(day, const ['wind', 'wind_speed']);
  buf.write('- ');
  if (date != null) buf.write('$date: ');
  final parts = <String>[];
  if (cond != null) parts.add(cond);
  if (high != null || low != null) parts.add('${high ?? '?'}/${low ?? '?'}');
  if (precip != null) parts.add('precip $precip');
  if (wind != null) parts.add('wind $wind');
  buf.writeln(parts.isEmpty ? '(no data)' : parts.join(' · '));
}

void _writeHour(StringBuffer buf, Map<String, dynamic> hour) {
  final time = _pickString(hour, const ['time', 'hour', 'label', 'timestamp']);
  final cond = _pickString(hour, const [
    'condition',
    'description',
    'summary',
    'weather',
  ]);
  final temp = _pickString(hour, const ['temperature', 'temp', 'temp_c']);
  final precip = _pickString(hour, const ['precipitation', 'precip', 'rain']);
  final wind = _pickString(hour, const ['wind', 'wind_speed']);
  final parts = <String>[];
  if (temp != null) parts.add(temp);
  if (cond != null) parts.add(cond);
  if (precip != null) parts.add('precip $precip');
  if (wind != null) parts.add('wind $wind');
  buf.write('- ');
  if (time != null) buf.write('$time: ');
  buf.writeln(parts.isEmpty ? '(no data)' : parts.join(' · '));
}

Map<String, dynamic>? _pickMap(Map<String, dynamic> src, List<String> keys) {
  for (final k in keys) {
    final v = src[k];
    if (v is Map) {
      return Map<String, dynamic>.from(v);
    }
  }
  return null;
}

List? _pickList(Map<String, dynamic> src, List<String> keys) {
  for (final k in keys) {
    final v = src[k];
    if (v is List) return v;
    if (v is Map) {
      // Nested list candidates, e.g. {"forecast": {"days": [...]}}.
      final nested = _pickList(Map<String, dynamic>.from(v), keys);
      if (nested != null) return nested;
    }
  }
  return null;
}

String? _pickString(Map<String, dynamic> src, List<String> keys) {
  for (final k in keys) {
    final v = src[k];
    if (v == null) continue;
    if (v is String) {
      final s = v.trim();
      if (s.isNotEmpty) return s;
    } else if (v is num) {
      return v.toString();
    } else if (v is Map) {
      final inner =
          v['value'] ?? v['text'] ?? v['display'] ?? v['display_value'];
      if (inner is String && inner.trim().isNotEmpty) return inner.trim();
      if (inner is num) return inner.toString();
    }
  }
  return null;
}
