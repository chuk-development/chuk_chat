// lib/utils/map_features.dart
//
// Pure logic behind the `features` form of a <map> block: road closures,
// roadworks, detours and areas drawn as lines and polygons.
//
// The model writes a compact, forgiving description. A feature can carry its
// geometry directly (`line`, `area` as coordinates, `lat`/`lon`) or name it
// (`road` + `town` + optional cross streets `from`/`to`, `area` as a place
// name, `ref` from the road_closures tool). Named geometry is resolved later
// by `MapFeatureResolver`; everything in this file is synchronous and
// network-free so it can be unit tested.

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// What a feature means. Decides the colour, the line style and the icon.
enum MapFeatureKind { closure, roadworks, detour, info }

/// One end of a road stretch: a cross street by name or a coordinate.
class FeatureEndpoint {
  const FeatureEndpoint({this.street, this.point});

  final String? street;
  final LatLng? point;

  bool get isEmpty => (street == null || street!.isEmpty) && point == null;
}

/// One parsed feature, before any network lookup.
class MapFeatureSpec {
  const MapFeatureSpec({
    required this.kind,
    required this.label,
    this.info,
    this.dates,
    this.detour,
    this.url,
    this.point,
    this.lines = const [],
    this.polygons = const [],
    this.ref,
    this.road,
    this.town,
    this.from,
    this.to,
    this.areaName,
  });

  final MapFeatureKind kind;
  final String label;
  final String? info;
  final String? dates;
  final String? detour;
  final String? url;

  /// Geometry the model gave directly.
  final LatLng? point;
  final List<List<LatLng>> lines;
  final List<List<LatLng>> polygons;

  /// Geometry the client has to look up.
  final String? ref;
  final String? road;
  final String? town;
  final FeatureEndpoint? from;
  final FeatureEndpoint? to;
  final String? areaName;

  /// True when part of the geometry still has to be fetched.
  bool get needsResolve =>
      (ref != null && ref!.isNotEmpty) ||
      (road != null && road!.isNotEmpty) ||
      (areaName != null && areaName!.isNotEmpty);

  /// The geometry known without any lookup.
  ResolvedGeometry get inlineGeometry =>
      ResolvedGeometry(lines: lines, polygons: polygons, point: point);

  /// Stable key for caching a lookup of this feature's geometry.
  String get resolveKey => [
    ref ?? '',
    road ?? '',
    town ?? '',
    from?.street ?? _pointKey(from?.point),
    to?.street ?? _pointKey(to?.point),
    areaName ?? '',
  ].join('|').toLowerCase();
}

String _pointKey(LatLng? p) => p == null
    ? ''
    : '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';

/// Geometry ready to draw.
class ResolvedGeometry {
  const ResolvedGeometry({
    this.lines = const [],
    this.polygons = const [],
    this.point,
  });

  static const ResolvedGeometry empty = ResolvedGeometry();

  final List<List<LatLng>> lines;
  final List<List<LatLng>> polygons;
  final LatLng? point;

  bool get isEmpty =>
      point == null &&
      lines.every((l) => l.length < 2) &&
      polygons.every((p) => p.length < 3);

  /// Every coordinate, for fitting the camera.
  List<LatLng> get allPoints => [
    ...lines.expand((l) => l),
    ...polygons.expand((p) => p),
    ?point,
  ];

  /// Where the feature's icon sits: the middle of the longest line, the
  /// centre of the largest area, or the point.
  LatLng? get labelPoint {
    final drawnLines = lines.where((l) => l.length >= 2).toList();
    if (drawnLines.isNotEmpty) {
      drawnLines.sort((a, b) => pathLength(b).compareTo(pathLength(a)));
      return pointAlongPath(drawnLines.first, 0.5);
    }
    final drawnPolys = polygons.where((p) => p.length >= 3).toList();
    if (drawnPolys.isNotEmpty) {
      drawnPolys.sort((a, b) => b.length.compareTo(a.length));
      return centroid(drawnPolys.first);
    }
    return point;
  }

  /// This geometry with [other]'s parts added.
  ResolvedGeometry merge(ResolvedGeometry other) => ResolvedGeometry(
    lines: [...lines, ...other.lines],
    polygons: [...polygons, ...other.polygons],
    point: point ?? other.point,
  );
}

/// A parsed `features` map block.
class MapFeaturesBlockData {
  const MapFeaturesBlockData({required this.features, this.title});

  final String? title;
  final List<MapFeatureSpec> features;
}

/// True when a parsed <map> object uses the features form.
bool isFeaturesMap(Map<String, dynamic> data) {
  final type = data['type']?.toString().toLowerCase().trim();
  return data['features'] is List ||
      type == 'features' ||
      type == 'closures' ||
      type == 'roadworks';
}

// ──────────────────────────────────────────────────────────
// Parsing
// ──────────────────────────────────────────────────────────

/// Parses a features map. Never throws: an item that cannot be understood is
/// skipped, and a block with nothing usable comes back with no features.
MapFeaturesBlockData parseMapFeatures(Map<String, dynamic> data) {
  final title = _str(data['title']);
  final defaultTown = _str(data['town'] ?? data['city'] ?? data['place']);
  final features = <MapFeatureSpec>[];

  final rawFeatures = data['features'];
  if (rawFeatures is List) {
    for (final item in rawFeatures) {
      if (item is! Map) continue;
      final spec = parseMapFeature(
        Map<String, dynamic>.from(item),
        defaultTown: defaultTown,
      );
      if (spec != null) features.add(spec);
    }
  }

  // Plain markers in the same block become info points.
  final rawMarkers = data['markers'];
  if (rawMarkers is List) {
    for (final item in rawMarkers) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      m.putIfAbsent('kind', () => 'info');
      final spec = parseMapFeature(m, defaultTown: defaultTown);
      if (spec != null) features.add(spec);
    }
  }

  return MapFeaturesBlockData(title: title, features: features);
}

/// Parses one feature object. Returns null when it has no geometry at all,
/// neither given nor nameable.
MapFeatureSpec? parseMapFeature(
  Map<String, dynamic> m, {
  String? defaultTown,
}) {
  final point = parseLatLng(m) ?? parseLatLng(m['point'] ?? m['at']);

  final lines = <List<LatLng>>[];
  for (final key in const ['line', 'lines', 'path', 'coords', 'coordinates']) {
    lines.addAll(parseLatLngLines(m[key]));
  }
  final polygons = <List<LatLng>>[];
  String? areaName;
  for (final key in const ['area', 'polygon']) {
    final raw = m[key];
    if (raw is String && parseLatLngList(raw).length < 3) {
      areaName ??= _str(raw);
    } else {
      polygons.addAll(
        parseLatLngLines(raw).where((ring) => ring.length >= 3),
      );
    }
  }

  final ref = _str(m['ref'] ?? m['id_ref']);
  final road = _str(m['road'] ?? m['street'] ?? m['strasse'] ?? m['straße']);
  final town = _str(m['town'] ?? m['city'] ?? m['ort']) ?? defaultTown;

  FeatureEndpoint? from = _parseEndpoint(m['from'] ?? m['von']);
  FeatureEndpoint? to = _parseEndpoint(m['to'] ?? m['bis']);
  final between = m['between'];
  if (between is List && between.length >= 2) {
    from ??= _parseEndpoint(between[0]);
    to ??= _parseEndpoint(between[1]);
  } else if (between is String) {
    final parts = between.split(RegExp(r'\s+(?:and|und|bis|to|-|–)\s+|[;&]'));
    if (parts.length >= 2) {
      from ??= _parseEndpoint(parts[0]);
      to ??= _parseEndpoint(parts[1]);
    }
  }

  final hasGeometry =
      point != null ||
      lines.any((l) => l.length >= 2) ||
      polygons.isNotEmpty ||
      ref != null ||
      road != null ||
      areaName != null;
  if (!hasGeometry) return null;

  final isPointOnly =
      point != null &&
      lines.isEmpty &&
      polygons.isEmpty &&
      ref == null &&
      road == null &&
      areaName == null;
  final kind = parseFeatureKind(
    m['kind'] ?? m['type'] ?? m['category'] ?? m['style'],
    fallback: isPointOnly ? MapFeatureKind.info : MapFeatureKind.closure,
  );

  final label =
      _str(m['label'] ?? m['name'] ?? m['title']) ??
      road ??
      areaName ??
      _kindLabel(kind);

  var dates = _str(m['dates'] ?? m['when'] ?? m['period'] ?? m['zeitraum']);
  if (dates == null) {
    final start = _str(m['start'] ?? m['from_date'] ?? m['since']);
    final end = _str(m['end'] ?? m['until'] ?? m['to_date']);
    if (start != null && end != null) {
      dates = '$start – $end';
    } else if (start != null) {
      dates = 'ab $start';
    } else if (end != null) {
      dates = 'bis $end';
    }
  }

  return MapFeatureSpec(
    kind: kind,
    label: label,
    info: _str(
      m['info'] ??
          m['text'] ??
          m['description'] ??
          m['details'] ??
          m['what'] ??
          m['popup'],
    ),
    dates: dates,
    detour: _str(m['detour'] ?? m['umleitung'] ?? m['diversion']),
    url: _str(m['url'] ?? m['source'] ?? m['link']),
    point: point,
    lines: lines.where((l) => l.length >= 2).toList(),
    polygons: polygons,
    ref: ref,
    road: road,
    town: town,
    from: (from == null || from.isEmpty) ? null : from,
    to: (to == null || to.isEmpty) ? null : to,
    areaName: areaName,
  );
}

FeatureEndpoint? _parseEndpoint(dynamic raw) {
  if (raw == null) return null;
  final p = parseLatLng(raw);
  if (p != null) return FeatureEndpoint(point: p);
  final s = _str(raw);
  return s == null ? null : FeatureEndpoint(street: s);
}

/// Maps the many words a model uses for a kind onto [MapFeatureKind].
MapFeatureKind parseFeatureKind(
  dynamic raw, {
  MapFeatureKind fallback = MapFeatureKind.closure,
}) {
  final s = raw?.toString().toLowerCase().trim() ?? '';
  if (s.isEmpty) return fallback;
  if (s.contains('detour') ||
      s.contains('umleit') ||
      s.contains('diversion') ||
      s.contains('bypass') ||
      s.contains('alternative')) {
    return MapFeatureKind.detour;
  }
  if (s.contains('work') ||
      s.contains('baustelle') ||
      s.contains('bau') ||
      s.contains('construction') ||
      s.contains('arbeit') ||
      s.contains('lane') ||
      s.contains('halbseitig') ||
      s.contains('restrict') ||
      s.contains('einschränk')) {
    return MapFeatureKind.roadworks;
  }
  if (s.contains('clos') ||
      s.contains('sperr') ||
      s.contains('block') ||
      s.contains('gesperrt')) {
    return MapFeatureKind.closure;
  }
  if (s.contains('info') ||
      s.contains('marker') ||
      s.contains('point') ||
      s.contains('poi') ||
      s.contains('hinweis') ||
      s.contains('note')) {
    return MapFeatureKind.info;
  }
  return fallback;
}

String _kindLabel(MapFeatureKind kind) => switch (kind) {
  MapFeatureKind.closure => 'Sperrung',
  MapFeatureKind.roadworks => 'Baustelle',
  MapFeatureKind.detour => 'Umleitung',
  MapFeatureKind.info => 'Hinweis',
};

String? _str(dynamic v) {
  if (v == null) return null;
  if (v is Map || v is List) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

double? _num(dynamic v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final d = double.tryParse(v.trim());
    return (d != null && d.isFinite) ? d : null;
  }
  return null;
}

LatLng? _validLatLng(double? a, double? b) {
  if (a == null || b == null) return null;
  var lat = a;
  var lon = b;
  // [lon, lat] written by mistake: only fixable when it is unambiguous.
  if (lat.abs() > 90 && lon.abs() <= 90) {
    final t = lat;
    lat = lon;
    lon = t;
  }
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  if (lat == 0 && lon == 0) return null;
  return LatLng(lat, lon);
}

/// Reads one coordinate from `{lat, lon}`, `[lat, lon]` or `"lat,lon"`.
LatLng? parseLatLng(dynamic raw) {
  if (raw is Map) {
    final lat = _num(raw['lat'] ?? raw['latitude']);
    final lon = _num(raw['lon'] ?? raw['lng'] ?? raw['longitude']);
    return _validLatLng(lat, lon);
  }
  if (raw is List && raw.length == 2 && raw.every((e) => e is num)) {
    return _validLatLng(_num(raw[0]), _num(raw[1]));
  }
  if (raw is String) {
    final m = RegExp(
      r'^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$',
    ).firstMatch(raw);
    if (m != null) {
      return _validLatLng(double.parse(m[1]!), double.parse(m[2]!));
    }
  }
  return null;
}

/// Reads a coordinate list: `[[lat,lon],...]`, `[{lat,lon},...]`,
/// `"lat,lon; lat,lon"` or a flat `[lat,lon,lat,lon,...]`.
List<LatLng> parseLatLngList(dynamic raw) {
  if (raw is String) {
    return raw
        .split(RegExp(r'[;|]'))
        .map(parseLatLng)
        .whereType<LatLng>()
        .toList();
  }
  if (raw is! List || raw.isEmpty) return const [];
  if (raw.length > 2 && raw.length.isEven && raw.every((e) => e is num)) {
    final out = <LatLng>[];
    for (var i = 0; i + 1 < raw.length; i += 2) {
      final p = _validLatLng(_num(raw[i]), _num(raw[i + 1]));
      if (p != null) out.add(p);
    }
    return out;
  }
  return raw.map(parseLatLng).whereType<LatLng>().toList();
}

/// Reads one or several coordinate lists (a line or a multi-line).
List<List<LatLng>> parseLatLngLines(dynamic raw) {
  if (raw is List && raw.isNotEmpty) {
    final first = raw.first;
    final isMulti =
        first is List && first.isNotEmpty && (first.first is List || first.first is Map);
    if (isMulti) {
      return raw
          .map(parseLatLngList)
          .where((l) => l.isNotEmpty)
          .toList();
    }
  }
  final single = parseLatLngList(raw);
  return single.isEmpty ? const [] : [single];
}

// ──────────────────────────────────────────────────────────
// Foreign geometry formats
// ──────────────────────────────────────────────────────────

List<LatLng> _lonLatList(dynamic raw) {
  if (raw is! List) return const [];
  final out = <LatLng>[];
  for (final c in raw) {
    if (c is List && c.length >= 2) {
      final p = _validLatLng(_num(c[1]), _num(c[0]));
      if (p != null) out.add(p);
    }
  }
  return out;
}

/// Converts a GeoJSON geometry (as Nominatim's `polygon_geojson` returns
/// it, `[lon, lat]` order) into drawable geometry.
ResolvedGeometry geometryFromGeoJson(dynamic geojson) {
  if (geojson is! Map) return ResolvedGeometry.empty;
  final type = geojson['type']?.toString();
  final coords = geojson['coordinates'];
  switch (type) {
    case 'Point':
      final p = coords is List && coords.length >= 2
          ? _validLatLng(_num(coords[1]), _num(coords[0]))
          : null;
      return ResolvedGeometry(point: p);
    case 'LineString':
      return ResolvedGeometry(lines: [_lonLatList(coords)]);
    case 'MultiLineString':
      return ResolvedGeometry(
        lines: coords is List ? coords.map(_lonLatList).toList() : const [],
      );
    case 'Polygon':
      return ResolvedGeometry(
        polygons: coords is List && coords.isNotEmpty
            ? [_lonLatList(coords.first)]
            : const [],
      );
    case 'MultiPolygon':
      return ResolvedGeometry(
        polygons: coords is List
            ? coords
                  .whereType<List>()
                  .where((poly) => poly.isNotEmpty)
                  .map((poly) => _lonLatList(poly.first))
                  .toList()
            : const [],
      );
    case 'GeometryCollection':
      var out = ResolvedGeometry.empty;
      final parts = geojson['geometries'];
      if (parts is List) {
        for (final g in parts) {
          out = out.merge(geometryFromGeoJson(g));
        }
      }
      return out;
  }
  return ResolvedGeometry.empty;
}

/// Converts an ArcGIS REST geometry (`paths`, `rings` or `x`/`y`, queried
/// with `outSR=4326`) into drawable geometry.
ResolvedGeometry geometryFromArcgis(dynamic geometry) {
  if (geometry is! Map) return ResolvedGeometry.empty;
  final paths = geometry['paths'];
  final rings = geometry['rings'];
  return ResolvedGeometry(
    lines: paths is List ? paths.map(_lonLatList).toList() : const [],
    polygons: rings is List ? rings.map(_lonLatList).toList() : const [],
    point: _validLatLng(_num(geometry['y']), _num(geometry['x'])),
  );
}

// ──────────────────────────────────────────────────────────
// Road stretch between two cross streets
// ──────────────────────────────────────────────────────────

const Distance _distance = Distance();

double _meters(LatLng a, LatLng b) => _distance.as(LengthUnit.Meter, a, b);

/// Length of a polyline in metres.
double pathLength(List<LatLng> path) {
  var total = 0.0;
  for (var i = 1; i < path.length; i++) {
    total += _meters(path[i - 1], path[i]);
  }
  return total;
}

/// The point [fraction] (0..1) of the way along [path].
LatLng pointAlongPath(List<LatLng> path, double fraction) {
  if (path.length == 1) return path.first;
  final target = pathLength(path) * fraction.clamp(0.0, 1.0);
  var walked = 0.0;
  for (var i = 1; i < path.length; i++) {
    final seg = _meters(path[i - 1], path[i]);
    if (walked + seg >= target && seg > 0) {
      final t = (target - walked) / seg;
      return LatLng(
        path[i - 1].latitude + (path[i].latitude - path[i - 1].latitude) * t,
        path[i - 1].longitude +
            (path[i].longitude - path[i - 1].longitude) * t,
      );
    }
    walked += seg;
  }
  return path.last;
}

/// Plain vertex average; good enough to place an icon inside a small area.
LatLng centroid(List<LatLng> ring) {
  var lat = 0.0;
  var lon = 0.0;
  for (final p in ring) {
    lat += p.latitude;
    lon += p.longitude;
  }
  return LatLng(lat / ring.length, lon / ring.length);
}

String _vertexKey(LatLng p) =>
    '${p.latitude.toStringAsFixed(7)},${p.longitude.toStringAsFixed(7)}';

/// Points where [cross] meets [road]: shared vertices first (OSM ways that
/// meet share a node, so the coordinates are identical); when there are
/// none, the closest pair of vertices within [maxMeters].
List<LatLng> intersectionCandidates(
  List<List<LatLng>> road,
  List<List<LatLng>> cross, {
  double maxMeters = 40,
}) {
  final roadKeys = <String, LatLng>{};
  for (final line in road) {
    for (final p in line) {
      roadKeys[_vertexKey(p)] = p;
    }
  }
  final shared = <String, LatLng>{};
  for (final line in cross) {
    for (final p in line) {
      final hit = roadKeys[_vertexKey(p)];
      if (hit != null) shared[_vertexKey(hit)] = hit;
    }
  }
  if (shared.isNotEmpty) return shared.values.toList();

  LatLng? best;
  var bestD = double.infinity;
  for (final line in cross) {
    for (final p in line) {
      for (final q in roadKeys.values) {
        final d = _meters(p, q);
        if (d < bestD) {
          bestD = d;
          best = q;
        }
      }
    }
  }
  return (best != null && bestD <= maxMeters) ? [best] : const [];
}

/// The road vertex closest to [p].
LatLng? nearestVertex(List<List<LatLng>> road, LatLng p) {
  LatLng? best;
  var bestD = double.infinity;
  for (final line in road) {
    for (final q in line) {
      final d = _meters(p, q);
      if (d < bestD) {
        bestD = d;
        best = q;
      }
    }
  }
  return best;
}

/// The shortest way along [road] from [a] to [b] (both snapped to the
/// nearest road vertex). Null when the two are not connected by the road's
/// own segments or snap to the same vertex.
List<LatLng>? shortestPathOnRoad(List<List<LatLng>> road, LatLng a, LatLng b) {
  final start = nearestVertex(road, a);
  final end = nearestVertex(road, b);
  if (start == null || end == null) return null;
  final startKey = _vertexKey(start);
  final endKey = _vertexKey(end);
  if (startKey == endKey) return null;

  final points = <String, LatLng>{};
  final edges = <String, Map<String, double>>{};
  for (final line in road) {
    for (var i = 0; i < line.length; i++) {
      final k = _vertexKey(line[i]);
      points[k] = line[i];
      edges.putIfAbsent(k, () => <String, double>{});
      if (i > 0) {
        final prev = _vertexKey(line[i - 1]);
        if (prev == k) continue;
        final w = _meters(line[i - 1], line[i]);
        edges[k]![prev] = w;
        edges[prev]![k] = w;
      }
    }
  }

  final dist = <String, double>{startKey: 0};
  final prev = <String, String>{};
  final open = <String>{startKey};
  final done = <String>{};
  while (open.isNotEmpty) {
    var current = open.first;
    for (final k in open) {
      if (dist[k]! < dist[current]!) current = k;
    }
    if (current == endKey) break;
    open.remove(current);
    done.add(current);
    for (final entry in edges[current]!.entries) {
      if (done.contains(entry.key)) continue;
      final nd = dist[current]! + entry.value;
      if (nd < (dist[entry.key] ?? double.infinity)) {
        dist[entry.key] = nd;
        prev[entry.key] = current;
        open.add(entry.key);
      }
    }
  }
  if (!dist.containsKey(endKey)) return null;

  final path = <LatLng>[];
  String? k = endKey;
  while (k != null) {
    path.add(points[k]!);
    k = prev[k];
  }
  return path.reversed.toList();
}

/// Cuts the stretch of [road] between the [fromCandidates] and
/// [toCandidates] crossings. Of all combinations it keeps the shortest
/// connected one; a cross street that meets the road twice then picks the
/// crossing that belongs to the stretch. Null when no pair connects.
List<LatLng>? clipRoadBetween(
  List<List<LatLng>> road,
  List<LatLng> fromCandidates,
  List<LatLng> toCandidates,
) {
  List<LatLng>? best;
  var bestLen = double.infinity;
  for (final a in fromCandidates) {
    for (final b in toCandidates) {
      final path = shortestPathOnRoad(road, a, b);
      if (path == null) continue;
      final len = pathLength(path);
      if (len < bestLen) {
        bestLen = len;
        best = path;
      }
    }
  }
  return best;
}

/// Camera zoom for a set of points when no bounds fit is possible.
double zoomForSpan(List<LatLng> points) {
  if (points.length < 2) return 15;
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (final p in points) {
    minLat = math.min(minLat, p.latitude);
    maxLat = math.max(maxLat, p.latitude);
    minLon = math.min(minLon, p.longitude);
    maxLon = math.max(maxLon, p.longitude);
  }
  final span = math.max(maxLat - minLat, maxLon - minLon);
  if (span < 0.005) return 16;
  if (span < 0.02) return 14;
  if (span < 0.1) return 12;
  if (span < 0.5) return 10;
  return 8;
}
