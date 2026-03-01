import 'dart:convert';

import 'package:http/http.dart' as http;

const String _nominatimBaseUrl = 'https://nominatim.openstreetmap.org';
const String _osrmBaseUrl = 'https://router.project-osrm.org';
const Map<String, String> _defaultHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'chuk-chat/1.0',
};

Future<String> executeSearchPlaces(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final query = (args['query'] as String? ?? '').trim();
  if (query.isEmpty) {
    return 'Error: "query" parameter required';
  }

  final city = (args['city'] as String? ?? '').trim();
  final limit = _coerceInt(args['limit'], fallback: 10).clamp(1, 25);

  final lat = _coerceDouble(args['lat']);
  final lon = _coerceDouble(args['lon']);
  final radius = _coerceInt(args['radius'], fallback: 5000).clamp(500, 50000);

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final where = _buildWhereClause(
      city: city,
      latitude: lat,
      longitude: lon,
      radiusMeters: radius,
    );
    final searchQuery = where == null ? query : '$query $where';

    final results = await _searchNominatim(
      client: effectiveClient,
      query: searchQuery,
      limit: limit,
    );

    if (results.isEmpty) {
      return 'No places found for "$query"';
    }

    return _formatPlaceResults(
      heading: 'Found ${results.length} places for "$query":',
      results: results,
    );
  } catch (error) {
    return 'Error searching places: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<String> executeSearchRestaurants(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final query = (args['query'] as String? ?? '').trim();
  final cuisine = (args['cuisine'] as String? ?? '').trim();
  final city = (args['city'] as String? ?? '').trim();
  final limit = _coerceInt(args['limit'], fallback: 10).clamp(1, 25);

  final lat = _coerceDouble(args['lat']);
  final lon = _coerceDouble(args['lon']);
  final radius = _coerceInt(args['radius'], fallback: 5000).clamp(500, 50000);

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final where = _buildWhereClause(
      city: city,
      latitude: lat,
      longitude: lon,
      radiusMeters: radius,
    );

    final parts = <String>['restaurant'];
    if (query.isNotEmpty) {
      parts.add(query);
    }
    if (cuisine.isNotEmpty) {
      parts.add(cuisine);
    }
    if (where != null) {
      parts.add(where);
    }

    final results = await _searchNominatim(
      client: effectiveClient,
      query: parts.join(' '),
      limit: limit,
    );

    if (results.isEmpty) {
      final searchLabel = query.isNotEmpty
          ? query
          : (cuisine.isNotEmpty ? cuisine : 'restaurants');
      return 'No restaurants found for "$searchLabel"';
    }

    final headingLabel = query.isNotEmpty
        ? query
        : (cuisine.isNotEmpty ? cuisine : 'restaurants');
    return _formatPlaceResults(
      heading: 'Found ${results.length} restaurants for "$headingLabel":',
      results: results,
    );
  } catch (error) {
    return 'Error searching restaurants: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<String> executeGeocode(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final address = (args['address'] as String? ?? args['query'] as String? ?? '')
      .trim();
  final lat = _coerceDouble(args['lat']);
  final lon = _coerceDouble(args['lon']);

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    if (lat != null && lon != null) {
      final reverseUri = Uri.parse(
        '$_nominatimBaseUrl/reverse'
        '?format=jsonv2&lat=$lat&lon=$lon',
      );
      final response = await effectiveClient.get(
        reverseUri,
        headers: _defaultHeaders,
      );
      if (response.statusCode != 200) {
        return 'Error: reverse geocoding failed (${response.statusCode})';
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final name = (data['display_name'] as String? ?? '').trim();
      if (name.isEmpty) {
        return 'Could not find address for ($lat, $lon)';
      }
      return 'Address: $name\nCoordinates: $lat, $lon';
    }

    if (address.isEmpty) {
      return 'Error: "address" (or "query") parameter required';
    }

    final results = await _searchNominatim(
      client: effectiveClient,
      query: address,
      limit: 1,
    );
    if (results.isEmpty) {
      return 'Could not find coordinates for "$address"';
    }

    final first = results.first;
    final name = (first['display_name'] as String? ?? address).trim();
    final resolvedLat = first['lat'];
    final resolvedLon = first['lon'];
    return '$name\nCoordinates: $resolvedLat, $resolvedLon';
  } catch (error) {
    return 'Error geocoding: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<String> executeGetRoute(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final fromLat = _coerceDouble(args['from_lat']);
  final fromLon = _coerceDouble(args['from_lon']);
  final toLat = _coerceDouble(args['to_lat']);
  final toLon = _coerceDouble(args['to_lon']);

  if (fromLat == null || fromLon == null || toLat == null || toLon == null) {
    return 'Error: from_lat, from_lon, to_lat and to_lon are required';
  }

  final profileInput = (args['profile'] as String? ?? 'driving')
      .trim()
      .toLowerCase();
  final profile = switch (profileInput) {
    'walking' => 'foot',
    'foot' => 'foot',
    'cycling' => 'bike',
    'bike' => 'bike',
    _ => 'driving',
  };

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final uri = Uri.parse(
      '$_osrmBaseUrl/route/v1/$profile/$fromLon,$fromLat;$toLon,$toLat'
      '?overview=false&steps=true&alternatives=false',
    );

    final response = await effectiveClient.get(uri, headers: _defaultHeaders);
    if (response.statusCode != 200) {
      return 'Error: route lookup failed (${response.statusCode})';
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      return 'Could not find a route';
    }

    final route = routes.first as Map<String, dynamic>;
    final distanceMeters = (route['distance'] as num?)?.toDouble() ?? 0.0;
    final durationSeconds = (route['duration'] as num?)?.toDouble() ?? 0.0;

    final distanceKm = (distanceMeters / 1000).toStringAsFixed(1);
    final durationMin = (durationSeconds / 60).toStringAsFixed(0);

    final buf = StringBuffer();
    buf.writeln('Route ($profileInput): $distanceKm km, ~$durationMin min');

    final legs = route['legs'] as List<dynamic>? ?? const [];
    if (legs.isNotEmpty) {
      final firstLeg = legs.first as Map<String, dynamic>;
      final steps = firstLeg['steps'] as List<dynamic>? ?? const [];

      for (var i = 0; i < steps.length && i < 10; i++) {
        final step = steps[i] as Map<String, dynamic>;
        final stepDistance = (step['distance'] as num?)?.toDouble() ?? 0.0;
        final maneuver = step['maneuver'] as Map<String, dynamic>? ?? const {};
        final instruction = _buildInstruction(
          maneuver: maneuver,
          roadName: (step['name'] as String? ?? '').trim(),
        );
        buf.writeln('  - $instruction (${_formatDistance(stepDistance)})');
      }

      if (steps.length > 10) {
        buf.writeln('  ... and ${steps.length - 10} more steps');
      }
    }

    buf.writeln('Start: $fromLat, $fromLon');
    buf.writeln('End: $toLat, $toLon');
    return buf.toString().trimRight();
  } catch (error) {
    return 'Error getting route: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<List<Map<String, dynamic>>> _searchNominatim({
  required http.Client client,
  required String query,
  required int limit,
}) async {
  final uri = Uri.parse(
    '$_nominatimBaseUrl/search'
    '?format=jsonv2&q=${Uri.encodeComponent(query)}&limit=$limit',
  );

  final response = await client.get(uri, headers: _defaultHeaders);
  if (response.statusCode != 200) {
    throw StateError('Nominatim returned ${response.statusCode}');
  }

  final decoded = jsonDecode(response.body);
  if (decoded is! List) {
    return const <Map<String, dynamic>>[];
  }

  final parsed = <Map<String, dynamic>>[];
  for (final item in decoded) {
    if (item is! Map<String, dynamic>) {
      continue;
    }
    final lat = _coerceDouble(item['lat']);
    final lon = _coerceDouble(item['lon']);
    if (lat == null || lon == null) {
      continue;
    }

    parsed.add({
      'display_name': item['display_name']?.toString() ?? '',
      'lat': lat,
      'lon': lon,
      'type': item['type']?.toString() ?? '',
      'category': item['category']?.toString() ?? '',
    });
  }

  return parsed;
}

String _formatPlaceResults({
  required String heading,
  required List<Map<String, dynamic>> results,
}) {
  final buf = StringBuffer();
  buf.writeln(heading);
  buf.writeln();

  for (final result in results) {
    final fullName = (result['display_name'] as String? ?? '').trim();
    final shortName = fullName.split(',').first.trim();
    final lat = result['lat'];
    final lon = result['lon'];
    final type = (result['type'] as String? ?? '').trim();
    final category = (result['category'] as String? ?? '').trim();

    buf.write('- ${shortName.isEmpty ? fullName : shortName}');
    if (type.isNotEmpty || category.isNotEmpty) {
      final tag = [
        if (category.isNotEmpty) category,
        if (type.isNotEmpty) type,
      ].join('/');
      buf.write(' ($tag)');
    }
    buf.writeln(' [$lat, $lon]');
    if (fullName.isNotEmpty) {
      buf.writeln('  Address: $fullName');
    }
  }

  return buf.toString().trimRight();
}

String? _buildWhereClause({
  required String city,
  required double? latitude,
  required double? longitude,
  required int radiusMeters,
}) {
  if (city.isNotEmpty) {
    return city;
  }

  if (latitude != null && longitude != null) {
    return 'near $latitude,$longitude within ${radiusMeters}m';
  }

  return null;
}

String _buildInstruction({
  required Map<String, dynamic> maneuver,
  required String roadName,
}) {
  final type = (maneuver['type'] as String? ?? 'continue').trim();
  final modifier = (maneuver['modifier'] as String? ?? '').trim();

  final phrase = switch (type) {
    'depart' => 'Depart',
    'arrive' => 'Arrive',
    'turn' => modifier.isEmpty ? 'Turn' : 'Turn $modifier',
    'new name' => 'Continue',
    'merge' => modifier.isEmpty ? 'Merge' : 'Merge $modifier',
    'on ramp' => modifier.isEmpty ? 'Take on-ramp' : 'Take on-ramp $modifier',
    'off ramp' =>
      modifier.isEmpty ? 'Take off-ramp' : 'Take off-ramp $modifier',
    'fork' => modifier.isEmpty ? 'Keep' : 'Keep $modifier',
    'roundabout' => 'Enter roundabout',
    'rotary' => 'Enter rotary',
    'roundabout turn' => 'At roundabout, turn',
    'notification' => 'Continue',
    _ => 'Continue',
  };

  if (roadName.isEmpty) {
    return phrase;
  }
  return '$phrase on $roadName';
}

String _formatDistance(double meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
  return '${meters.round()} m';
}

double? _coerceDouble(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString().trim());
}

int _coerceInt(dynamic value, {required int fallback}) {
  if (value == null) {
    return fallback;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  final parsed = int.tryParse(value.toString().trim());
  return parsed ?? fallback;
}
