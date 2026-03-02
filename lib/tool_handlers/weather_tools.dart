import 'dart:convert';

import 'package:http/http.dart' as http;

/// WMO Weather interpretation codes -> human-readable descriptions.
const _wmoCodes = <int, String>{
  0: 'Clear sky',
  1: 'Mainly clear',
  2: 'Partly cloudy',
  3: 'Overcast',
  45: 'Fog',
  48: 'Depositing rime fog',
  51: 'Light drizzle',
  53: 'Moderate drizzle',
  55: 'Dense drizzle',
  61: 'Slight rain',
  63: 'Moderate rain',
  65: 'Heavy rain',
  71: 'Slight snowfall',
  73: 'Moderate snowfall',
  75: 'Heavy snowfall',
  80: 'Slight rain showers',
  81: 'Moderate rain showers',
  82: 'Violent rain showers',
  95: 'Thunderstorm',
  96: 'Thunderstorm with slight hail',
  99: 'Thunderstorm with heavy hail',
};

String _wmoDescription(int code) => _wmoCodes[code] ?? 'Unknown ($code)';

/// Wind direction from degrees.
String _windDirection(num degrees) {
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return dirs[((degrees + 22.5) % 360 / 45).floor()];
}

/// Execute the weather tool. Calls Open-Meteo API directly (no key needed).
Future<String> executeWeather(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final action = (args['action'] as String? ?? 'current').toLowerCase();
  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final coords = await _resolveCoordinates(args, effectiveClient);
    if (coords == null) {
      return 'Error: Provide "location" (city name) or '
          '"latitude"/"longitude"';
    }

    final lat = coords['lat']!;
    final lon = coords['lon']!;
    final locationName = coords['name'] ?? '$lat, $lon';

    switch (action) {
      case 'current':
        return await _fetchCurrent(lat, lon, locationName, effectiveClient);
      case 'forecast':
        final days = (args['days'] as num?)?.toInt() ?? 7;
        return await _fetchForecast(
          lat,
          lon,
          locationName,
          days.clamp(1, 16),
          effectiveClient,
        );
      case 'hourly':
        final hours = (args['hours'] as num?)?.toInt() ?? 24;
        return await _fetchHourly(
          lat,
          lon,
          locationName,
          hours.clamp(1, 48),
          effectiveClient,
        );
      default:
        return 'Error: Unknown action "$action". Use: current, forecast, '
            'hourly';
    }
  } catch (e) {
    return 'Weather error: $e';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<Map<String, dynamic>?> _resolveCoordinates(
  Map<String, dynamic> args,
  http.Client client,
) async {
  final lat = args['latitude'];
  final lon = args['longitude'];
  if (lat is num && lon is num) {
    return {
      'lat': lat.toDouble(),
      'lon': lon.toDouble(),
      'name': args['location'] as String?,
    };
  }

  final location = args['location'] as String?;
  if (location == null || location.isEmpty) return null;

  final uri = Uri.parse(
    'https://geocoding-api.open-meteo.com/v1/search'
    '?name=${Uri.encodeComponent(location)}&count=1&language=en',
  );
  final resp = await client.get(uri);
  if (resp.statusCode != 200) return null;

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final results = data['results'] as List?;
  if (results == null || results.isEmpty) return null;

  final place = results[0] as Map<String, dynamic>;
  final country = place['country'] ?? '';
  final admin1 = place['admin1'] ?? '';
  final name = place['name'] ?? location;
  final displayName = [
    name,
    if ((admin1 as String).isNotEmpty) admin1,
    if ((country as String).isNotEmpty) country,
  ].join(', ');

  return {
    'lat': (place['latitude'] as num).toDouble(),
    'lon': (place['longitude'] as num).toDouble(),
    'name': displayName,
    'timezone': place['timezone'],
  };
}

Future<String> _fetchCurrent(
  double lat,
  double lon,
  String location,
  http.Client client,
) async {
  final uri = Uri.parse(
    'https://api.open-meteo.com/v1/forecast'
    '?latitude=$lat&longitude=$lon'
    '&current=temperature_2m,relative_humidity_2m,apparent_temperature,'
    'precipitation,weather_code,cloud_cover,wind_speed_10m,'
    'wind_direction_10m,wind_gusts_10m,surface_pressure'
    '&timezone=auto',
  );

  final resp = await client.get(uri);
  if (resp.statusCode != 200) {
    return 'Error: Open-Meteo returned ${resp.statusCode}';
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final current = data['current'] as Map<String, dynamic>;
  final units = data['current_units'] as Map<String, dynamic>;

  final wmo = (current['weather_code'] as num).toInt();
  final temp = current['temperature_2m'];
  final feelsLike = current['apparent_temperature'];
  final humidity = current['relative_humidity_2m'];
  final windSpeed = current['wind_speed_10m'];
  final windDir = current['wind_direction_10m'];
  final windGusts = current['wind_gusts_10m'];
  final precip = current['precipitation'];
  final clouds = current['cloud_cover'];
  final pressure = current['surface_pressure'];

  final buf = StringBuffer();
  buf.writeln('Current weather in $location:');
  buf.writeln(_wmoDescription(wmo));
  buf.writeln(
    'Temperature: $temp${units['temperature_2m']} '
    '(feels like $feelsLike${units['apparent_temperature']})',
  );
  buf.writeln('Humidity: $humidity${units['relative_humidity_2m']}');
  buf.writeln(
    'Wind: $windSpeed ${units['wind_speed_10m']} '
    '${_windDirection((windDir as num?)?.toDouble() ?? 0)} '
    '(gusts $windGusts ${units['wind_gusts_10m']})',
  );
  buf.writeln('Precipitation: $precip ${units['precipitation']}');
  buf.writeln('Cloud cover: $clouds${units['cloud_cover']}');
  buf.writeln('Pressure: $pressure ${units['surface_pressure']}');

  return buf.toString().trimRight();
}

Future<String> _fetchForecast(
  double lat,
  double lon,
  String location,
  int days,
  http.Client client,
) async {
  final uri = Uri.parse(
    'https://api.open-meteo.com/v1/forecast'
    '?latitude=$lat&longitude=$lon'
    '&daily=weather_code,temperature_2m_max,temperature_2m_min,'
    'apparent_temperature_max,apparent_temperature_min,'
    'precipitation_sum,precipitation_probability_max,'
    'wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,'
    'sunrise,sunset,uv_index_max'
    '&forecast_days=$days'
    '&timezone=auto',
  );

  final resp = await client.get(uri);
  if (resp.statusCode != 200) {
    return 'Error: Open-Meteo returned ${resp.statusCode}';
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final daily = data['daily'] as Map<String, dynamic>;
  final units = data['daily_units'] as Map<String, dynamic>;
  final times = (daily['time'] as List).cast<String>();

  final buf = StringBuffer();
  buf.writeln('$days-day forecast for $location:');
  buf.writeln();

  for (var i = 0; i < times.length; i++) {
    final date = times[i];
    final wmo = (daily['weather_code'][i] as num).toInt();
    final tMax = daily['temperature_2m_max'][i];
    final tMin = daily['temperature_2m_min'][i];
    final precip = daily['precipitation_sum'][i];
    final precipProb = daily['precipitation_probability_max'][i];
    final windMax = daily['wind_speed_10m_max'][i];
    final windDir = daily['wind_direction_10m_dominant'][i];
    final uvMax = daily['uv_index_max'][i];

    buf.writeln('$date -- ${_wmoDescription(wmo)}');
    buf.writeln('  Temp: $tMin-$tMax${units['temperature_2m_max']}');
    buf.writeln(
      '  Precip: $precip${units['precipitation_sum']} '
      '($precipProb% chance)',
    );
    buf.writeln(
      '  Wind: $windMax ${units['wind_speed_10m_max']} '
      '${_windDirection((windDir as num?)?.toDouble() ?? 0)}',
    );
    buf.writeln('  UV: $uvMax');
    buf.writeln();
  }

  return buf.toString().trimRight();
}

Future<String> _fetchHourly(
  double lat,
  double lon,
  String location,
  int hours,
  http.Client client,
) async {
  final uri = Uri.parse(
    'https://api.open-meteo.com/v1/forecast'
    '?latitude=$lat&longitude=$lon'
    '&hourly=temperature_2m,relative_humidity_2m,apparent_temperature,'
    'precipitation_probability,precipitation,weather_code,'
    'cloud_cover,wind_speed_10m,wind_direction_10m'
    '&forecast_hours=$hours'
    '&timezone=auto',
  );

  final resp = await client.get(uri);
  if (resp.statusCode != 200) {
    return 'Error: Open-Meteo returned ${resp.statusCode}';
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final hourly = data['hourly'] as Map<String, dynamic>;
  final units = data['hourly_units'] as Map<String, dynamic>;
  final times = (hourly['time'] as List).cast<String>();

  final buf = StringBuffer();
  buf.writeln('Hourly forecast for $location (next $hours hours):');
  buf.writeln();

  for (var i = 0; i < times.length; i++) {
    final time = times[i];
    final wmo = (hourly['weather_code'][i] as num).toInt();
    final temp = hourly['temperature_2m'][i];
    final feelsLike = hourly['apparent_temperature'][i];
    final precip = hourly['precipitation'][i];
    final precipProb = hourly['precipitation_probability'][i];
    final windSpeed = hourly['wind_speed_10m'][i];
    final windDir = hourly['wind_direction_10m'][i];

    buf.writeln(
      '${_timeOnly(time)} $temp${units['temperature_2m']} '
      '(feels $feelsLike${units['apparent_temperature']}) | '
      '${_wmoDescription(wmo)} | '
      'Wind $windSpeed ${units['wind_speed_10m']} '
      '${_windDirection((windDir as num?)?.toDouble() ?? 0)} | '
      'Precip $precip${units['precipitation']} ($precipProb%)',
    );
  }

  return buf.toString().trimRight();
}

String _timeOnly(dynamic isoString) {
  if (isoString == null) return '?';
  final s = isoString.toString();
  final tIdx = s.indexOf('T');
  return tIdx >= 0 ? s.substring(tIdx + 1) : s;
}
