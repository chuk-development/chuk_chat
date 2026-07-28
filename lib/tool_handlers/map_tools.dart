import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/multiplex_tool_proxy.dart';

/// These endpoints are called straight from the device, so a stalled
/// request would otherwise wedge the whole tool loop — which is exactly
/// what happens when the phone loses its network mid-turn.
const Duration _networkTimeout = Duration(seconds: 20);

const String _nominatimBaseUrl = 'https://nominatim.openstreetmap.org';
const String _osrmBaseUrl = 'https://router.workspace-osrm.org';
const Map<String, String> _defaultHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'chuk-chat/1.0',
};

/// Search places via server-side Brave Local proxy.
Future<String> executeSearchPlaces({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
  http.Client? client,
}) async {
  final query = (args['query'] as String? ?? '').trim();
  if (query.isEmpty) {
    return 'Error: "query" parameter required';
  }

  final city = (args['city'] as String? ?? '').trim();
  final limit = _coerceInt(args['limit'], fallback: 10).clamp(1, 20);
  final country = _extractCountry(args);
  final lang = _extractLang(args);

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final searchQuery = city.isNotEmpty ? '$query $city' : query;
    final places = await _fetchBravePlaces(
      baseUrl: baseUrl,
      serverHeaders: serverHeaders,
      client: effectiveClient,
      query: searchQuery,
      count: limit,
      country: country,
      searchLang: lang,
    );

    if (places.isEmpty) {
      return 'No places found for "$query"';
    }

    return _formatBravePlaces(
      heading: 'Found ${places.length} places for "$query":',
      places: places,
    );
  } catch (error) {
    return 'Error searching places: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

/// Search restaurants via server-side Brave Local proxy.
Future<String> executeSearchRestaurants({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
  http.Client? client,
}) async {
  final query = (args['query'] as String? ?? '').trim();
  final cuisine = (args['cuisine'] as String? ?? '').trim();
  final city = (args['city'] as String? ?? '').trim();
  final limit = _coerceInt(args['limit'], fallback: 10).clamp(1, 20);
  final country = _extractCountry(args);
  final lang = _extractLang(args);

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final parts = <String>[];
    if (cuisine.isNotEmpty) parts.add(cuisine);
    parts.add('restaurants');
    if (query.isNotEmpty) parts.add(query);
    if (city.isNotEmpty) parts.add('in $city');
    final searchQuery = parts.join(' ');

    final places = await _fetchBravePlaces(
      baseUrl: baseUrl,
      serverHeaders: serverHeaders,
      client: effectiveClient,
      query: searchQuery,
      count: limit,
      country: country,
      searchLang: lang,
    );

    final label = query.isNotEmpty
        ? query
        : (cuisine.isNotEmpty ? cuisine : 'restaurants');

    if (places.isEmpty) {
      return 'No restaurants found for "$label"';
    }

    return _formatBravePlaces(
      heading: 'Found ${places.length} restaurants for "$label":',
      places: places,
    );
  } catch (error) {
    return 'Error searching restaurants: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

/// Forward / reverse geocoding via Nominatim (kept; no server proxy).
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
      final response = await effectiveClient
          .get(reverseUri, headers: _defaultHeaders)
          .timeout(_networkTimeout);
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
    'driving' => 'car',
    'car' => 'car',
    _ => 'car',
  };

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final uri = Uri.parse(
      '$_osrmBaseUrl/route/v1/$profile/$fromLon,$fromLat;$toLon,$toLat'
      '?overview=false&steps=true&alternatives=false',
    );

    final response = await effectiveClient
        .get(uri, headers: _defaultHeaders)
        .timeout(_networkTimeout);
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

Future<List<Map<String, dynamic>>> _fetchBravePlaces({
  required String baseUrl,
  required Map<String, String> serverHeaders,
  required http.Client client,
  required String query,
  required int count,
  String country = 'DE',
  String searchLang = 'de',
}) async {
  final body = {
    'query': query,
    'count': count,
    'country': country,
    'search_lang': searchLang,
  };

  Map<String, dynamic>? data;
  final mux = await tryToolViaMultiplex(tool: 'brave_places', payload: body);
  if (mux.isError) {
    throw StateError(mux.error.toString());
  }
  if (mux.isOk) {
    data = mux.body;
  } else {
    final response = await client
        .post(
          Uri.parse('$baseUrl/v1/tools/brave/places'),
          headers: {'Content-Type': 'application/json', ...serverHeaders},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      final err = _tryDecodeJsonObject(response.body)?['error']?.toString();
      throw StateError(err ?? 'HTTP ${response.statusCode}');
    }

    data = _tryDecodeJsonObject(response.body);
  }
  if (data == null) {
    throw StateError('Invalid server response');
  }

  final raw = data['places'];
  if (raw is! List) return const <Map<String, dynamic>>[];
  return raw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
}

String _formatBravePlaces({
  required String heading,
  required List<Map<String, dynamic>> places,
}) {
  final buf = StringBuffer();
  buf.writeln(heading);
  buf.writeln();

  for (final place in places) {
    // Brave Places occasionally returns string fields as lists (e.g.
    // multiple phone numbers, multiple price-range labels). Coerce
    // defensively so one weird POI doesn't blow up the whole batch.
    final name = _asString(place['name']).trim();
    final lat = place['lat'];
    final lon = place['lon'];
    final address = _asString(place['address']).trim();
    final phone = _asString(place['phone']).trim();
    final website = _asString(place['website']).trim();
    final hours = _asString(place['opening_hours']).trim();
    final cuisine = _asString(place['cuisine']).trim();
    final rating = place['rating'];
    final reviews = place['review_count'];
    final price = _asString(place['price_range']).trim();
    final description = _asString(place['description']).trim();

    final latLonLabel = (lat != null && lon != null) ? ' [$lat, $lon]' : '';
    buf.writeln('- ${name.isEmpty ? '(unnamed)' : name}$latLonLabel');
    if (cuisine.isNotEmpty) buf.writeln('  Category: $cuisine');
    if (address.isNotEmpty) buf.writeln('  Address: $address');
    if (phone.isNotEmpty) buf.writeln('  Phone: $phone');
    if (website.isNotEmpty) buf.writeln('  Website: $website');
    if (hours.isNotEmpty) buf.writeln('  Hours: $hours');
    final ratingBits = <String>[];
    if (rating != null) ratingBits.add('rating $rating');
    if (reviews != null) ratingBits.add('$reviews reviews');
    if (price.isNotEmpty) ratingBits.add('price $price');
    if (ratingBits.isNotEmpty) {
      buf.writeln('  ${ratingBits.join(' · ')}');
    }
    if (description.isNotEmpty) buf.writeln('  About: $description');
  }

  return buf.toString().trimRight();
}

Future<List<Map<String, dynamic>>> _searchNominatim({
  required http.Client client,
  required String query,
  required int limit,
  double? latitude,
  double? longitude,
  int? radiusMeters,
}) async {
  var url =
      '$_nominatimBaseUrl/search'
      '?format=jsonv2&q=${Uri.encodeComponent(query)}&limit=$limit';

  // Use Nominatim viewbox for spatial filtering when coordinates are provided
  if (latitude != null && longitude != null && radiusMeters != null) {
    // Convert radius to approximate degree offset (~111km per degree)
    final delta = radiusMeters / 111000.0;
    final viewbox =
        '${longitude - delta},${latitude + delta},'
        '${longitude + delta},${latitude - delta}';
    url += '&viewbox=$viewbox&bounded=1';
  }

  final uri = Uri.parse(url);

  final response = await client
      .get(uri, headers: _defaultHeaders)
      .timeout(_networkTimeout);
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

String _extractCountry(Map<String, dynamic> args) {
  final v = (args['country'] as String? ?? '').trim();
  if (v.length == 2) return v.toUpperCase();
  return 'DE';
}

String _extractLang(Map<String, dynamic> args) {
  final v = (args['search_lang'] as String? ?? args['lang'] as String? ?? '')
      .trim();
  if (v.isNotEmpty) return v.toLowerCase();
  return 'de';
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

/// Coerce a JSON-decoded value to a String. Server tools normally hand back
/// strings for these fields but Brave Places occasionally surfaces a list
/// (e.g. multi-value price_range) and a null is always possible.
String _asString(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is List) {
    return value
        .where((e) => e != null)
        .map((e) => e.toString())
        .join(', ');
  }
  return value.toString();
}
