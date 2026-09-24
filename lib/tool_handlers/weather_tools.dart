import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/multiplex_tool_proxy.dart';
import 'package:chuk_chat/utils/json_helpers.dart';

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
    final body = {'query': query, 'country': 'DE', 'search_lang': 'de'};

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
        final errorData = tryDecodeJsonObject(response.body);
        final error = errorData?['error']?.toString();
        return 'Weather error: ${error ?? 'HTTP ${response.statusCode}'}';
      }

      data = tryDecodeJsonObject(response.body);
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
      days: days,
      hours: hours,
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
      : (latitude != null && longitude != null ? '$latitude,$longitude' : '');

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

String _formatWeather({
  required String locationLabel,
  required String action,
  int? days,
  int? hours,
  required String vertical,
  required Map<String, dynamic> payload,
}) {
  // The payload Brave really sends: `{type: rich, results: [{subtype:
  // weather, weather: {location, current_weather, daily, hours3, alerts}}]}`.
  // The generic reader below never matched it, so every call returned the
  // same 16 kB raw JSON dump, whatever the action. The model then could not
  // find the fields the weather card asks for and called the tool again.
  final brave = _braveWeather(payload);
  if (brave != null) {
    return _formatBraveWeather(
      brave,
      locationLabel: locationLabel,
      action: action,
      days: days,
      hours: hours,
      vertical: vertical,
    );
  }

  final buf = StringBuffer();
  final weather = _pickMap(payload, const [
    'weather',
    'data',
    'result',
    'results',
    'forecast',
  ]);
  final source = weather ?? payload;

  final place =
      _pickString(source, const [
        'location',
        'place',
        'title',
        'name',
        'query',
      ]) ??
      locationLabel;

  buf.writeln(
    'Weather — $place (source: Brave rich${vertical.isNotEmpty ? '/$vertical' : ''})',
  );

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

/// Line that tells the model this one result is complete for the place.
const String kWeatherCompleteNote =
    'This one result holds the current conditions, the daily forecast and '
    'the hourly outlook for this place. Another weather call for the same '
    'place returns the same data.';

/// The `weather` map of a Brave rich weather payload, or null when the
/// payload has another shape.
Map<String, dynamic>? _braveWeather(Map<String, dynamic> payload) {
  final results = payload['results'];
  if (results is! List) return null;
  for (final item in results) {
    if (item is! Map) continue;
    final weather = item['weather'];
    if (weather is Map &&
        (weather['current_weather'] is Map ||
            weather['daily'] is List ||
            weather['hours3'] is List)) {
      return Map<String, dynamic>.from(weather);
    }
  }
  return null;
}

String _formatBraveWeather(
  Map<String, dynamic> weather, {
  required String locationLabel,
  required String action,
  int? days,
  int? hours,
  required String vertical,
}) {
  final location = weather['location'] is Map
      ? Map<String, dynamic>.from(weather['location'] as Map)
      : const <String, dynamic>{};
  final tzOffset = _asNum(location['tzoffset'])?.toInt() ?? 0;
  final name = (location['name'] as String?)?.trim();
  final country = (location['country'] as String?)?.trim();
  final place = (name == null || name.isEmpty)
      ? locationLabel
      : (country == null || country.isEmpty ? name : '$name, $country');

  final buf = StringBuffer()
    ..writeln(
      'Weather — $place (source: Brave rich'
      '${vertical.isNotEmpty ? '/$vertical' : ''})',
    )
    ..writeln(kWeatherCompleteNote)
    ..writeln('Units: °C, km/h, mm. Codes are WMO weather codes.');

  final localTime = weather['current_time_iso'];
  if (localTime is String && localTime.length >= 16) {
    buf.writeln(
      'Local time: ${localTime.substring(0, 16).replaceAll('T', ' ')}',
    );
  }

  final current = weather['current_weather'];
  if (current is Map) {
    final c = Map<String, dynamic>.from(current);
    final parts = <String>[
      ?_conditionPart(c['weather']),
      if (_asNum(c['temp']) != null)
        '${_fmt(_asNum(c['temp']))} °C'
            '${_asNum(c['feels_like']) != null ? ' (feels ${_fmt(_asNum(c['feels_like']))} °C)' : ''}',
      if (_asNum(c['humidity']) != null)
        'humidity ${_fmt(_asNum(c['humidity']))}%',
      ?_windPart(c['wind']),
      if (_precipAmount(c['rain']) != null)
        'rain ${_fmt(_precipAmount(c['rain']))} mm',
      if (_precipAmount(c['snow']) != null)
        'snow ${_fmt(_precipAmount(c['snow']))} mm',
      if (_asNum(c['clouds']) != null) 'clouds ${_fmt(_asNum(c['clouds']))}%',
      if (_asNum(c['uvi']) != null) 'UV ${_fmt(_asNum(c['uvi']))}',
    ];
    buf.writeln('Current: ${parts.join(' · ')}');
  }

  final alerts = weather['alerts'];
  if (alerts is List && alerts.isNotEmpty) {
    buf.writeln('Alerts:');
    for (final alert in alerts.whereType<Map>()) {
      final event = alert['event']?.toString() ?? 'Alert';
      final sender = alert['sender']?.toString();
      final when = alert['start_relative_i18n']?.toString();
      buf.writeln(
        '- $event'
        '${sender != null && sender.isNotEmpty ? ' ($sender)' : ''}'
        '${when != null && when.isNotEmpty ? ', $when' : ''}',
      );
    }
  }

  final daily = weather['daily'];
  if (daily is List && daily.isNotEmpty) {
    final count = (action == 'forecast' ? (days ?? 7) : 3).clamp(
      1,
      daily.length,
    );
    buf.writeln('Daily:');
    for (final entry in daily.take(count).whereType<Map>()) {
      final d = Map<String, dynamic>.from(entry);
      final temp = d['temperature'] is Map
          ? Map<String, dynamic>.from(d['temperature'] as Map)
          : const <String, dynamic>{};
      final parts = <String>[
        ?_conditionPart(d['weather']),
        if (_asNum(temp['max']) != null || _asNum(temp['min']) != null)
          'max ${_fmt(_asNum(temp['max']))} / min ${_fmt(_asNum(temp['min']))} °C',
        if (_asNum(d['pop']) != null)
          'precip prob ${(_asNum(d['pop'])! * 100).round()}%',
        if (_precipAmount(d['rain']) != null)
          'rain ${_fmt(_precipAmount(d['rain']))} mm',
        if (_precipAmount(d['snow']) != null)
          'snow ${_fmt(_precipAmount(d['snow']))} mm',
        ?_windPart(d['wind']),
      ];
      final date = _localDateTime(d['ts'], tzOffset);
      buf.writeln(
        '- ${date == null ? '' : '${_isoDate(date)}: '}${parts.join(' · ')}',
      );
    }
  }

  final hourly = weather['hours3'];
  if (hourly is List && hourly.isNotEmpty) {
    final wantHours = action == 'hourly' ? (hours ?? 24) : 24;
    final count = ((wantHours.clamp(1, 48) + 2) ~/ 3).clamp(1, hourly.length);
    buf.writeln('Hourly (3-hour steps):');
    for (final entry in hourly.take(count).whereType<Map>()) {
      final h = Map<String, dynamic>.from(entry);
      final temp = h['temperature'] is Map
          ? Map<String, dynamic>.from(h['temperature'] as Map)
          : const <String, dynamic>{};
      final t = _asNum(temp['temp']) ?? _asNum(h['temp']);
      final parts = <String>[
        if (t != null) '${_fmt(t)} °C',
        ?_conditionPart(h['weather']),
        if (_asNum(h['pop']) != null)
          'precip prob ${(_asNum(h['pop'])! * 100).round()}%',
        if (_precipAmount(h['rain']) != null)
          'rain ${_fmt(_precipAmount(h['rain']))} mm',
        ?_windPart(h['wind']),
      ];
      final time = _localDateTime(h['ts'], tzOffset);
      buf.writeln(
        '- ${time == null ? '' : '${_isoDate(time)} ${_hhmm(time)}: '}'
        '${parts.join(' · ')}',
      );
    }
  }

  return buf.toString().trimRight();
}

num? _asNum(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim());
  return null;
}

String _fmt(num? value) {
  if (value == null) return '?';
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(1);
}

/// Rain or snow amount: OpenWeatherMap sends a number or `{"1h": n}`.
num? _precipAmount(Object? value) {
  if (value is Map) return _asNum(value['1h'] ?? value['3h']);
  return _asNum(value);
}

String? _conditionPart(Object? weather) {
  if (weather is! Map) return null;
  final description = weather['description']?.toString().trim();
  final id = _asNum(weather['id'])?.toInt();
  final code = id == null ? null : owmToWmoCode(id);
  if ((description == null || description.isEmpty) && code == null) {
    return null;
  }
  return '${description ?? ''}${code != null ? ' (WMO $code)' : ''}'.trim();
}

String? _windPart(Object? wind) {
  if (wind is! Map) return null;
  final speed = _asNum(wind['speed']);
  if (speed == null) return null;
  final deg = _asNum(wind['deg']);
  final gust = _asNum(wind['gust']);
  return 'wind ${(speed * 3.6).round()} km/h'
      '${deg != null ? ' ${compassPoint(deg)}' : ''}'
      '${gust != null ? ', gusts ${(gust * 3.6).round()} km/h' : ''}';
}

DateTime? _localDateTime(Object? ts, int tzOffsetSeconds) {
  final seconds = _asNum(ts)?.toInt();
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (seconds + tzOffsetSeconds) * 1000,
    isUtc: true,
  );
}

String _two(int n) => n.toString().padLeft(2, '0');

String _isoDate(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

String _hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// Eight-point compass direction for a wind bearing in degrees.
@visibleForTesting
String compassPoint(num degrees) {
  const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final index = (((degrees % 360) + 22.5) ~/ 45) % 8;
  return points[index];
}

/// Maps an OpenWeatherMap condition id to the WMO weather code the
/// `<weather>` card uses.
@visibleForTesting
int owmToWmoCode(int id) {
  if (id >= 200 && id < 300) return 95;
  if (id >= 300 && id < 400) {
    if (id == 300 || id == 301) return 51;
    if (id == 302) return 55;
    return 53;
  }
  if (id >= 500 && id < 600) {
    if (id == 500) return 61;
    if (id == 501) return 63;
    if (id >= 502 && id <= 504) return 65;
    if (id == 511) return 66;
    if (id == 520) return 80;
    if (id == 521) return 81;
    return 82;
  }
  if (id >= 600 && id < 700) {
    if (id == 600) return 71;
    if (id == 601) return 73;
    if (id == 602) return 75;
    if (id == 620) return 85;
    if (id == 621 || id == 622) return 86;
    return 77;
  }
  if (id >= 700 && id < 800) return 45;
  if (id == 800) return 0;
  if (id == 801) return 1;
  if (id == 802) return 2;
  return 3;
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
  final high = _pickString(src, const [
    'high',
    'max_temp',
    'temp_max',
    'high_temp',
  ]);
  final low = _pickString(src, const [
    'low',
    'min_temp',
    'temp_min',
    'low_temp',
  ]);

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
  final high = _pickString(day, const [
    'high',
    'max_temp',
    'temp_max',
    'high_temp',
  ]);
  final low = _pickString(day, const [
    'low',
    'min_temp',
    'temp_min',
    'low_temp',
  ]);
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
