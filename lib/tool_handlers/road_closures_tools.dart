// lib/tool_handlers/road_closures_tools.dart
//
// `road_closures` tool: current and upcoming roadworks / closures around a
// place from the official feeds: the northern-German DANord feed (see
// services/road_closures_service.dart) and, for all of Germany, the
// Autobahn GmbH motorway feed (services/autobahn_traffic_service.dart).
// The result lists ready-made map features, so the model can draw the
// closed stretches without writing coordinates.

import 'package:chuk_chat/services/autobahn_traffic_service.dart';
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

  final north = roadworksFeedCovers(lat, lon);
  final autobahn = autobahnFeedCovers(lat, lon);
  if (!north && !autobahn) {
    return 'No official roadworks feed for $label in this tool (it covers '
        'German motorways, and in Schleswig-Holstein, Hamburg, Lower Saxony '
        'and Mecklenburg-Vorpommern also federal, state and county roads). '
        'Use web_search for "<town> Sperrung" / "<road> closure" instead and '
        'draw the result as a features <map> (skill map-features) with '
        '"road" + "town" + "from"/"to".';
  }

  final warnings = <String>[];
  final northFuture = north
      ? fetchRoadClosuresAround(
          lat: lat,
          lon: lon,
          radiusKm: radiusKm,
        ).then<List<RoadClosure>?>((r) => r).catchError((Object _) => null)
      : Future<List<RoadClosure>?>.value(const []);
  final autobahnFuture = autobahn
      ? AutobahnTrafficService.instance
            .closuresAround(lat: lat, lon: lon, radiusKm: radiusKm)
            .then<AutobahnLookup?>((r) => r)
            .catchError((Object _) => null)
      : Future<AutobahnLookup?>.value(null);

  final northResult = await northFuture;
  final autobahnResult = await autobahnFuture;

  // Only the feeds that were asked count: an unasked one is not a success.
  final northFailed = !north || northResult == null;
  final autobahnFailed = !autobahn || autobahnResult == null;
  if (northFailed && autobahnFailed) {
    return 'Error: roadworks feeds unavailable. Fall back to web_search.';
  }
  if (north && northResult == null) {
    warnings.add('the northern feed (LBV.SH / DANord) did not answer.');
  }
  if (autobahn && autobahnResult == null) {
    warnings.add('the Autobahn GmbH feed did not answer; motorways missing.');
  } else if (autobahnResult != null && autobahnResult.roadsFailed > 0) {
    warnings.add(
      'Autobahn GmbH: ${autobahnResult.roadsFailed} of '
      '${autobahnResult.roadsAsked} motorways did not answer.',
    );
  }

  final ab = autobahnResult?.closures ?? const <RoadClosure>[];
  final all = [...dropDanordAutobahnCopies(northResult ?? const [], ab), ...ab];
  final now = DateTime.now();
  final current = filterCurrentClosures(
    all,
    now: now,
    daysAhead: daysAhead,
    nearLat: lat,
    nearLon: lon,
  );
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
    northFeed: north && northResult != null,
    autobahn: autobahn && autobahnResult != null,
    warnings: warnings,
  );
}
