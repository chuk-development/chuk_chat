// lib/services/map_feature_resolver.dart
//
// Turns named geometry in a features <map> block into lines and polygons:
//
// - `ref: "sh:8:113,117"` → the official roadworks feed, by object id
//   (instant when the road_closures tool fetched it in this session).
// - `ref: "ab:A7:1a2b3c4d"` → an Autobahn GmbH item's road geometry
//   (instant from the same session, else one fetch of that motorway).
// - `road` + `town` (+ cross streets `from`/`to`) → every OSM segment of
//   that street from Nominatim (`polygon_geojson`, `dedupe=0`), clipped to
//   the stretch between the two crossings.
// - `area: "Marktplatz, Preetz"` → the place's outline from Nominatim.
//
// Nominatim allows one request per second, so all lookups go through one
// queue. Results are cached for the session; a failed lookup returns empty
// geometry and is not cached, so the next open tries again.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:chuk_chat/services/autobahn_traffic_service.dart';
import 'package:chuk_chat/services/road_closures_service.dart';
import 'package:chuk_chat/utils/map_features.dart';

const String _nominatimBase = 'https://nominatim.openstreetmap.org';
const Map<String, String> _headers = {
  'Accept': 'application/json',
  'User-Agent': 'chuk-chat/1.0',
};
const Duration _timeout = Duration(seconds: 15);
const Duration _nominatimSpacing = Duration(milliseconds: 1100);
const int _maxCacheEntries = 200;

class MapFeatureResolver {
  MapFeatureResolver._();

  static final MapFeatureResolver instance = MapFeatureResolver._();

  final LinkedHashMap<String, Future<ResolvedGeometry>> _cache =
      LinkedHashMap<String, Future<ResolvedGeometry>>();
  final Map<String, ResolvedGeometry> _primedRefs = {};
  final Map<String, Future<ResolvedGeometry>> _streetCache = {};

  Future<void> _nominatimQueue = Future<void>.value();
  DateTime _lastNominatim = DateTime.fromMillisecondsSinceEpoch(0);

  /// Stores geometry the road_closures tool already has, so the map draws
  /// it without a second request.
  void primeRef(String ref, ResolvedGeometry geometry) {
    if (geometry.isEmpty) return;
    _primedRefs[ref.trim()] = geometry;
    if (_primedRefs.length > _maxCacheEntries) {
      _primedRefs.remove(_primedRefs.keys.first);
    }
  }

  /// The looked-up geometry of [spec] (without its inline geometry).
  Future<ResolvedGeometry> resolve(MapFeatureSpec spec) {
    if (!spec.needsResolve) return Future.value(ResolvedGeometry.empty);
    final key = spec.resolveKey;
    final cached = _cache[key];
    if (cached != null) return cached;
    final future = _resolveUncached(spec).catchError((Object e) {
      if (kDebugMode) {
        debugPrint('map feature resolve failed: ${e.runtimeType}');
      }
      return ResolvedGeometry.empty;
    });
    _cache[key] = future;
    if (_cache.length > _maxCacheEntries) _cache.remove(_cache.keys.first);
    future.then((g) {
      if (g.isEmpty) _cache.remove(key);
    });
    return future;
  }

  Future<ResolvedGeometry> _resolveUncached(MapFeatureSpec spec) async {
    var out = ResolvedGeometry.empty;
    final ref = spec.ref?.trim();
    if (ref != null && ref.isNotEmpty) {
      out = out.merge(await _resolveRef(ref));
    }
    final road = spec.road;
    if (road != null && road.isNotEmpty) {
      out = out.merge(await _resolveRoad(spec));
    }
    final area = spec.areaName;
    if (area != null && area.isNotEmpty) {
      out = out.merge(await _resolveArea(area, spec.town));
    }
    return out;
  }

  Future<ResolvedGeometry> _resolveRef(String ref) async {
    final primed = _primedRefs[ref];
    if (primed != null) return primed;
    if (ref.startsWith(kRoadworksRefPrefix)) {
      return fetchRoadworksRefGeometry(ref);
    }
    if (ref.startsWith(kAutobahnRefPrefix)) {
      return AutobahnTrafficService.instance.refGeometry(ref);
    }
    return ResolvedGeometry.empty;
  }

  Future<ResolvedGeometry> _resolveRoad(MapFeatureSpec spec) async {
    final road = await _streetLines(spec.road!, spec.town);
    if (road.isEmpty) return ResolvedGeometry.empty;

    final from = spec.from;
    final to = spec.to;
    if (from != null && to != null) {
      final a = await _endpointCandidates(road, from, spec.town);
      final b = await _endpointCandidates(road, to, spec.town);
      if (a.isNotEmpty && b.isNotEmpty) {
        final clipped = clipRoadBetween(road, a, b);
        if (clipped != null && clipped.length >= 2) {
          return ResolvedGeometry(lines: [clipped]);
        }
      }
    }
    // No usable crossings: show the whole street rather than nothing.
    return ResolvedGeometry(lines: road);
  }

  Future<List<LatLng>> _endpointCandidates(
    List<List<LatLng>> road,
    FeatureEndpoint end,
    String? town,
  ) async {
    if (end.point != null) return [end.point!];
    final street = end.street;
    if (street == null || street.isEmpty) return const [];
    final cross = await _streetLines(street, town);
    if (cross.isEmpty) return const [];
    return intersectionCandidates(road, cross);
  }

  /// Every line segment of a street. Structured search first (it returns
  /// all segments with `dedupe=0`), free text as the fallback.
  Future<List<List<LatLng>>> _streetLines(String street, String? town) async {
    final key = '${street.toLowerCase()}|${(town ?? '').toLowerCase()}';
    final cached = _streetCache[key];
    final future =
        cached ??
        () async {
          var lines = <List<LatLng>>[];
          if (town != null && town.isNotEmpty) {
            lines = _linesOf(
              await _nominatim({
                'street': street,
                'city': town,
                'dedupe': '0',
                'limit': '40',
              }),
            );
          }
          if (lines.isEmpty) {
            final q = (town == null || street.contains(town))
                ? street
                : '$street, $town';
            lines = _linesOf(
              await _nominatim({'q': q, 'dedupe': '0', 'limit': '40'}),
            );
          }
          return ResolvedGeometry(lines: lines);
        }();
    _streetCache[key] = future;
    final g = await future;
    if (g.lines.isEmpty) _streetCache.remove(key);
    return g.lines;
  }

  List<List<LatLng>> _linesOf(List<dynamic> results) {
    final lines = <List<LatLng>>[];
    for (final r in results) {
      if (r is! Map) continue;
      final g = geometryFromGeoJson(r['geojson']);
      lines.addAll(g.lines.where((l) => l.length >= 2));
    }
    return lines;
  }

  Future<ResolvedGeometry> _resolveArea(String area, String? town) async {
    final q = (town == null ||
            town.isEmpty ||
            area.toLowerCase().contains(town.toLowerCase()))
        ? area
        : '$area, $town';
    final results = (await _nominatim({
      'q': q,
      'limit': '3',
    })).whereType<Map>().toList();
    if (results.isEmpty) return ResolvedGeometry.empty;
    // An area wants an outline: prefer the first hit that has one.
    for (final r in results) {
      final g = geometryFromGeoJson(r['geojson']);
      if (g.polygons.any((p) => p.length >= 3)) return g;
    }
    final first = results.first;
    final g = geometryFromGeoJson(first['geojson']);
    if (!g.isEmpty) return g;
    return ResolvedGeometry(
      point: parseLatLng({'lat': first['lat'], 'lon': first['lon']}),
    );
  }

  /// Coordinates of a place name, through the same rate-limited queue.
  Future<LatLng?> geocode(String query) async {
    final results = await _nominatim({'q': query, 'limit': '1'}, geo: false);
    if (results.isEmpty || results.first is! Map) return null;
    final first = results.first as Map;
    return parseLatLng({'lat': first['lat'], 'lon': first['lon']});
  }

  /// One Nominatim search, spaced at least [_nominatimSpacing] from the
  /// previous one. Returns an empty list on any failure.
  Future<List<dynamic>> _nominatim(
    Map<String, String> params, {
    bool geo = true,
  }) {
    final completer = Completer<List<dynamic>>();
    _nominatimQueue = _nominatimQueue.then((_) async {
      final wait = _nominatimSpacing - DateTime.now().difference(_lastNominatim);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _lastNominatim = DateTime.now();
      final uri = Uri.parse('$_nominatimBase/search').replace(
        queryParameters: {
          'format': 'jsonv2',
          if (geo) 'polygon_geojson': '1',
          ...params,
        },
      );
      try {
        final res = await http.get(uri, headers: _headers).timeout(_timeout);
        if (res.statusCode != 200) {
          completer.complete(const []);
          return;
        }
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        completer.complete(decoded is List ? decoded : const []);
      } catch (e) {
        if (kDebugMode) debugPrint('nominatim failed: ${e.runtimeType}');
        completer.complete(const []);
      }
    });
    return completer.future;
  }
}
