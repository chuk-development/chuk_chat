// lib/tool_handlers/road_closures_tools.dart
//
// `road_closures` tool: current and upcoming roadworks / closures around a
// place from the official northern-German feed (see
// services/road_closures_service.dart). The result lists ready-made map
// features, so the model can draw the closed stretches without writing
// coordinates.

import 'package:chuk_chat/services/map_feature_resolver.dart';
import 'package:chuk_chat/services/road_closures_service.dart';

double? _coerce(dynamic v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) return double.tryParse(v.trim());
  return null;
}

Future<String> executeRoadClosures(Map<String, dynamic> args) async {
  final place = (args['place'] ?? args['city'] ?? args['query'] ?? '')
      .toString()
      .trim();
  var lat = _coerce(args['lat']);
  var lon = _coerce(args['lon']);
  final radiusKm = (_coerce(args['radius_km']) ?? 5).clamp(1, 25).toDouble();
  final daysAhead = (_coerce(args['days_ahead']) ?? 30).clamp(0, 365).toInt();

  if (lat == null || lon == null) {
    if (place.isEmpty) {
      return 'Error: give "place" (town or address) or "lat" and "lon".';
    }
    final p = await MapFeatureResolver.instance.geocode(place);
    if (p == null) return 'Could not find "$place".';
    lat = p.latitude;
    lon = p.longitude;
  }

  final label = place.isEmpty
      ? '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}'
      : place;

  if (!roadworksFeedCovers(lat, lon)) {
    return 'No official roadworks feed for $label in this tool (it covers '
        'Schleswig-Holstein, Hamburg, Lower Saxony and Mecklenburg-'
        'Vorpommern). Use web_search for "<town> Sperrung" / "<road> '
        'closure" instead and draw the result as a features <map> '
        '(skill map-features) with "road" + "town" + "from"/"to".';
  }

  try {
    final all = await fetchRoadClosuresAround(
      lat: lat,
      lon: lon,
      radiusKm: radiusKm,
    );
    final now = DateTime.now();
    final current = filterCurrentClosures(all, now: now, daysAhead: daysAhead);
    for (final c in current) {
      MapFeatureResolver.instance.primeRef(c.ref, c.geometry);
    }
    return formatClosuresForModel(
      closures: current,
      placeLabel: label,
      lat: lat,
      lon: lon,
      radiusKm: radiusKm,
      now: now,
    );
  } catch (e) {
    return 'Error: roadworks feed unavailable (${e.runtimeType}). Fall back '
        'to web_search.';
  }
}
