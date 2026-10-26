// lib/services/autobahn_traffic_service.dart
//
// Closures and roadworks on every German motorway, keyless.
//
// Source: the open traffic API of Die Autobahn GmbH des Bundes
// (verkehr.autobahn.de/o/autobahn). It has no area query: the API lists
// the roads, and each road lists its closures and roadworks with the real
// road geometry (GeoJSON LineString). So a lookup asks per road and keeps
// what lies within the radius.
//
// Cost control:
// - Per-road results are cached for [kAutobahnRoadTtl] (5 min).
// - A road index (the bounding box of each road's current items) is built
//   from the first full scan and kept for [kAutobahnIndexTtl]. While it is
//   fresh, a lookup asks only roads whose box touches the search circle,
//   plus roads whose last fetch failed. A road with no items at all is
//   skipped until the index expires.
// - At most [kAutobahnConcurrency] requests run at once, each with a short
//   timeout, and the whole lookup has a deadline. A failed road is skipped
//   and not cached.
//
// Warnings (traffic jams, accidents) are not asked: that would be a third
// request per road.
//
// Parsing is pure and unit tested.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:chuk_chat/services/road_closures_service.dart';
import 'package:chuk_chat/utils/map_features.dart';

const String kAutobahnApiBase = 'https://verkehr.autobahn.de/o/autobahn';

/// Prefix of a feature `ref` that points at Autobahn GmbH items:
/// `ab:<road>:<id>[,<id>…]`, where an id is the short hash of the item's
/// identifier (see [autobahnShortId]) or the full identifier.
const String kAutobahnRefPrefix = 'ab:';

/// Neutral agent string: the app name only, no user or device data.
const Map<String, String> kAutobahnHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'chuk-chat/1.0',
};

/// The services asked per road.
const List<String> kAutobahnServices = ['closure', 'roadworks'];

const Duration kAutobahnRoadTtl = Duration(minutes: 5);
const Duration kAutobahnIndexTtl = Duration(hours: 1);
const Duration kAutobahnRoadListTtl = Duration(hours: 24);
const int kAutobahnConcurrency = 8;
const Duration _requestTimeout = Duration(seconds: 8);
const Duration _lookupDeadline = Duration(seconds: 25);

/// Pseudo layer id for Autobahn entries in a [RoadClosure].
const int kAutobahnLayer = -1;

/// Rough box around Germany. The API only knows German motorways.
bool autobahnFeedCovers(double lat, double lon) =>
    lat >= 47.2 && lat <= 55.1 && lon >= 5.8 && lon <= 15.1;

// ──────────────────────────────────────────────────────────
// Ids and refs
// ──────────────────────────────────────────────────────────

/// 8 hex chars (FNV-1a, 32 bit) of an item identifier. The identifiers are
/// about 90 chars long; the short form keeps the tool result small and is
/// stable across fetches.
String autobahnShortId(String identifier) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(identifier)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// Parses "ab:A7:1a2b3c4d,5e6f7a8b" into ("A7", ["1a2b3c4d", "5e6f7a8b"]).
/// Null when malformed.
(String, List<String>)? parseAutobahnRef(String ref) {
  final m = RegExp(r'^ab:([A-Za-z]\d{1,4}):(.+)$').firstMatch(ref.trim());
  if (m == null) return null;
  final ids = m[2]!
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (ids.isEmpty) return null;
  return (m[1]!.toUpperCase(), ids);
}

// ──────────────────────────────────────────────────────────
// Parsing
// ──────────────────────────────────────────────────────────

/// One item as the API returns it, parsed.
class AutobahnItem {
  AutobahnItem({
    required this.identifier,
    required this.road,
    required this.closure,
  });

  final String identifier;
  final String road;
  final RoadClosure closure;

  String get shortId => autobahnShortId(identifier);
}

final RegExp _abDate = RegExp(r'\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})\b');
final RegExp _abTime = RegExp(r'\b(\d{1,2}):(\d{2})\b');

/// Start and end of an item from its validity lines:
/// "Beginn: 05.10.26 um 00:00 Uhr" + "Ende: 01.12.26 um 00:00 Uhr",
/// "27.10.26 von 17:00 bis 22:00 Uhr",
/// "29.10.26 20:00 bis zum 30.10.26 05:00 Uhr.",
/// "Jeden Montag … zwischen dem 03.11.26 und dem 07.11.26 von 20:00 bis 05:00".
/// Takes the earliest and latest moment named. Two-digit years are 20xx.
DateRange parseAutobahnValidity(List<String> lines) {
  final points = <DateTime>[];
  for (final line in lines) {
    final dates = _abDate.allMatches(line).toList();
    for (var i = 0; i < dates.length; i++) {
      final m = dates[i];
      var y = int.parse(m[3]!);
      if (y < 100) y += 2000;
      final mo = int.parse(m[2]!), d = int.parse(m[1]!);
      if (mo < 1 || mo > 12 || d < 1 || d > 31) continue;
      final tail = line.substring(
        m.end,
        i + 1 < dates.length ? dates[i + 1].start : line.length,
      );
      final times = _abTime.allMatches(tail).take(2).toList();
      if (times.isEmpty) {
        points.add(DateTime(y, mo, d));
      }
      for (final t in times) {
        points.add(DateTime(y, mo, d, int.parse(t[1]!), int.parse(t[2]!)));
      }
    }
  }
  if (points.isEmpty) return const DateRange(null, null);
  points.sort();
  return DateRange(points.first, points.length > 1 ? points.last : null);
}

/// "A7: Füssen -> Ulm, zwischen …", "Von A96: …", "Abfahrt von der A9: …"
/// repeat the title; they are not notes.
bool _isLocationLine(String line, String road) {
  final i = line.indexOf('$road:');
  return i >= 0 && i <= 30;
}

String _clip(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1)}…';

/// Parses one service response (`{"closure":[…]}`, `{"roadworks":[…]}`)
/// of [road]. Malformed items are skipped; never throws.
List<AutobahnItem> parseAutobahnItems(String road, dynamic json) {
  if (json is! Map) return const [];
  final out = <AutobahnItem>[];
  for (final list in json.values) {
    if (list is! List) continue;
    for (final raw in list) {
      final item = _parseItem(road, raw);
      if (item != null) out.add(item);
    }
  }
  return out;
}

AutobahnItem? _parseItem(String road, dynamic raw) {
  if (raw is! Map) return null;
  final id = raw['identifier']?.toString().trim() ?? '';
  final title = raw['title']?.toString().trim() ?? '';
  if (id.isEmpty || title.isEmpty) return null;

  final displayType = raw['display_type']?.toString() ?? '';
  final blocked = raw['isBlocked']?.toString().toLowerCase() == 'true';

  // Description: blocks split by empty lines. The first block is the
  // validity, a "Länge: …" line carries length and limits, the location
  // line repeats the title, the last block says what is done.
  final desc = raw['description'] is List
      ? (raw['description'] as List).map((e) => e.toString().trim()).toList()
      : const <String>[];
  final blocks = <List<String>>[];
  var current = <String>[];
  for (final l in desc) {
    if (l.isEmpty) {
      if (current.isNotEmpty) blocks.add(current);
      current = <String>[];
    } else {
      current.add(l);
    }
  }
  if (current.isNotEmpty) blocks.add(current);

  final validity = <String>[];
  String? limits;
  final notes = <String>[];
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (i == 0 && b.any((l) => _abDate.hasMatch(l))) {
      validity.addAll(b.where((l) => !l.endsWith(':')));
      continue;
    }
    for (final l in b) {
      if (l.startsWith('Länge:')) {
        final parts = l
            .split('|')
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty && !p.contains('nicht ermittelt'))
            .toList();
        if (parts.isNotEmpty) limits = parts.join(', ');
      } else if (l != title && !_isLocationLine(l, road)) {
        notes.add(l);
      }
    }
  }

  // The overall end only counts when no phase dates are given.
  final phase = validity.where((l) => !l.contains('Gesamtmaßnahme')).toList();
  final range = parseAutobahnValidity(phase.isNotEmpty ? phase : validity);
  // "Beginn: … / Ende: …" says no more than the date label; keep the
  // source wording only for hours and weekly patterns.
  final plainRange =
      phase.isNotEmpty &&
      phase.every((l) => l.startsWith('Beginn:') || l.startsWith('Ende:'));
  final when = plainRange
      ? ''
      : phase.map((l) => l.replaceAll(RegExp(r'\.$'), '')).join('; ');

  final kind = (blocked || displayType.startsWith('CLOSURE'))
      ? MapFeatureKind.closure
      : MapFeatureKind.roadworks;
  final restriction = switch (displayType) {
    'CLOSURE_ENTRY_EXIT' => 'Anschlussstelle gesperrt',
    'CLOSURE' => 'Sperrung',
    'SHORT_TERM_ROADWORKS' => 'Tagesbaustelle',
    _ => blocked ? 'gesperrt' : null,
  };

  var geometry = geometryFromGeoJson(raw['geometry']);
  if (geometry.isEmpty) {
    final c = raw['coordinate'];
    if (c is Map) {
      final p = parseLatLng({'lat': c['lat'], 'lon': c['long']});
      if (p != null) geometry = ResolvedGeometry(point: p);
    }
  }

  final direction = raw['subtitle']?.toString().trim();
  final shortId = autobahnShortId(id);
  return AutobahnItem(
    identifier: id,
    road: road,
    closure: RoadClosure(
      layer: kAutobahnLayer,
      ids: const [],
      kind: kind,
      title: title,
      road: road,
      restriction: restriction,
      start: range.start,
      end: range.end,
      limits: limits,
      notes: notes.isEmpty ? null : _clip(notes.join(' · '), 120),
      geometry: geometry,
      ref: '$kAutobahnRefPrefix$road:$shortId',
      source: 'Autobahn GmbH',
      direction: (direction == null || direction.isEmpty) ? null : direction,
      whenText: when.isEmpty ? null : _clip(when, 120),
      blocked: blocked,
    ),
  );
}

// ──────────────────────────────────────────────────────────
// Distance
// ──────────────────────────────────────────────────────────

/// Distance in km from ([lat], [lon]) to the nearest part of [g] (lines as
/// segments, not only their vertices). Infinity for empty geometry.
double distanceToGeometryKm(ResolvedGeometry g, double lat, double lon) {
  final kx = 111.32 * math.cos(lat * math.pi / 180);
  const ky = 110.574;
  (double, double) xy(LatLng p) =>
      ((p.longitude - lon) * kx, (p.latitude - lat) * ky);
  var best = double.infinity;
  void seg(LatLng a, LatLng b) {
    final (ax, ay) = xy(a);
    final (bx, by) = xy(b);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final px = ax + dx * t, py = ay + dy * t;
    best = math.min(best, math.sqrt(px * px + py * py));
  }

  for (final line in [...g.lines, ...g.polygons]) {
    if (line.length == 1) seg(line.first, line.first);
    for (var i = 1; i < line.length; i++) {
      seg(line[i - 1], line[i]);
    }
  }
  final p = g.point;
  if (p != null) seg(p, p);
  return best;
}

/// Bounding box of a road's current items.
@immutable
class _Bounds {
  const _Bounds(this.minLat, this.minLon, this.maxLat, this.maxLon);

  final double minLat, minLon, maxLat, maxLon;

  static _Bounds? of(Iterable<LatLng> points) {
    double? a, b, c, d;
    for (final p in points) {
      a = a == null ? p.latitude : math.min(a, p.latitude);
      b = b == null ? p.longitude : math.min(b, p.longitude);
      c = c == null ? p.latitude : math.max(c, p.latitude);
      d = d == null ? p.longitude : math.max(d, p.longitude);
    }
    if (a == null) return null;
    return _Bounds(a, b!, c!, d!);
  }

  /// True when the circle's box (plus a 2 km margin) touches this box.
  bool touchesCircle(double lat, double lon, double radiusKm) {
    final r = radiusKm + 2;
    final dLat = r / 110.574;
    final dLon = r / (111.32 * math.max(0.01, math.cos(lat * math.pi / 180)));
    return lat + dLat >= minLat &&
        lat - dLat <= maxLat &&
        lon + dLon >= minLon &&
        lon - dLon <= maxLon;
  }
}

/// Folds the two directions of one measure (same title, same dates, same
/// kind) into one entry with a combined ref.
List<RoadClosure> groupAutobahnItems(List<AutobahnItem> items) {
  final byKey = <String, (RoadClosure, List<String>, Set<String>)>{};
  final order = <String>[];
  for (final it in items) {
    final c = it.closure;
    final key =
        '${c.title.toLowerCase()}|${c.whenText ?? c.datesLabel}|${c.kind.name}';
    final e = byKey[key];
    if (e == null) {
      // A copy: the cached item must not collect merged geometry.
      byKey[key] = (c.copyWithRef(), [it.shortId], {?c.direction});
      order.add(key);
      continue;
    }
    if (e.$2.contains(it.shortId)) continue;
    e.$2.add(it.shortId);
    if (c.direction != null) e.$3.add(c.direction!);
    e.$1.geometry = e.$1.geometry.merge(c.geometry);
  }
  return [
    for (final k in order)
      () {
        final (c, ids, dirs) = byKey[k]!;
        if (ids.length == 1) return c;
        return c.copyWithRef(
          ref: '$kAutobahnRefPrefix${c.road}:${ids.join(',')}',
          direction: dirs.length > 1 ? 'beide Richtungen' : c.direction,
        );
      }(),
  ];
}

/// Drops entries of the DANord feed's own Autobahn layers (5 and 10) that
/// are the same measure as an Autobahn GmbH entry: same road, same start
/// or end day, and within 3 km of each other.
List<RoadClosure> dropDanordAutobahnCopies(
  List<RoadClosure> danord,
  List<RoadClosure> autobahn,
) {
  if (autobahn.isEmpty) return danord;
  bool sameDay(DateTime? a, DateTime? b) =>
      a != null &&
      b != null &&
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day;
  bool isCopy(RoadClosure d) {
    if (d.layer != 5 && d.layer != 10) return false;
    // The point layer often has no road field; the title names it.
    final road = (d.road ?? RegExp(r'\bA ?\d{1,3}\b').firstMatch(d.title)?[0])
        ?.replaceAll(' ', '')
        .toUpperCase();
    if (road == null) return false;
    for (final a in autobahn) {
      if (a.road?.toUpperCase() != road) continue;
      if (!sameDay(d.start, a.start) && !sameDay(d.end, a.end)) continue;
      final p = d.geometry.labelPoint;
      if (p == null) continue;
      if (distanceToGeometryKm(a.geometry, p.latitude, p.longitude) <= 3) {
        return true;
      }
    }
    return false;
  }

  return danord.where((d) => !isCopy(d)).toList();
}

// ──────────────────────────────────────────────────────────
// Fetching
// ──────────────────────────────────────────────────────────

/// What one lookup found and how much of the network it reached.
class AutobahnLookup {
  const AutobahnLookup({
    required this.closures,
    required this.roadsAsked,
    required this.roadsFailed,
    required this.requests,
  });

  final List<RoadClosure> closures;
  final int roadsAsked;
  final int roadsFailed;

  /// HTTP requests this lookup sent (cache hits send none).
  final int requests;
}

class AutobahnUnavailable implements Exception {
  const AutobahnUnavailable();
}

class _RoadEntry {
  _RoadEntry(this.items, this.at);
  final List<AutobahnItem> items;
  final DateTime at;
}

/// Runs at most [max] tasks at once; tasks queued past [deadline] fail.
class _Limiter {
  _Limiter(this.max, this.clock);
  final int max;
  final DateTime Function() clock;
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<T> run<T>(Future<T> Function() task, DateTime deadline) async {
    if (_running >= max) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    } else {
      _running++;
    }
    try {
      if (clock().isAfter(deadline)) {
        throw TimeoutException('autobahn lookup deadline');
      }
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

class AutobahnTrafficService {
  AutobahnTrafficService({
    http.Client? client,
    DateTime Function()? clock,
    int concurrency = kAutobahnConcurrency,
  }) : _http = client ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _limiter = _Limiter(concurrency, clock ?? DateTime.now);

  static final AutobahnTrafficService instance = AutobahnTrafficService();

  final http.Client _http;
  final DateTime Function() _clock;
  final _Limiter _limiter;

  List<String>? _roads;
  DateTime? _roadsAt;
  final Map<String, _RoadEntry> _cache = {};
  final Map<String, Future<List<AutobahnItem>?>> _inFlight = {};

  /// Road → box of its items. Missing key = unknown (always asked);
  /// null value = the road had no items.
  final Map<String, _Bounds?> _index = {};
  DateTime? _indexAt;

  int _requests = 0;

  /// Clears every cache (tests, sign-out).
  void reset() {
    _roads = null;
    _roadsAt = null;
    _cache.clear();
    _index.clear();
    _indexAt = null;
  }

  Future<dynamic> _getJson(Uri uri, DateTime deadline) {
    return _limiter.run(() async {
      _requests++;
      final res = await _http
          .get(uri, headers: kAutobahnHeaders)
          .timeout(_requestTimeout);
      if (res.statusCode != 200) {
        throw http.ClientException('status ${res.statusCode}');
      }
      return jsonDecode(utf8.decode(res.bodyBytes));
    }, deadline);
  }

  Future<List<String>> _roadList(DateTime deadline) async {
    final now = _clock();
    final cached = _roads;
    if (cached != null &&
        _roadsAt != null &&
        now.difference(_roadsAt!) < kAutobahnRoadListTtl) {
      return cached;
    }
    try {
      final json = await _getJson(Uri.parse('$kAutobahnApiBase/'), deadline);
      final roads = json is Map && json['roads'] is List
          ? (json['roads'] as List)
                .map((r) => r.toString().trim())
                .where((r) => RegExp(r'^[A-Za-z]\d{1,4}$').hasMatch(r))
                .toList()
          : <String>[];
      if (roads.isEmpty) throw const AutobahnUnavailable();
      _roads = roads;
      _roadsAt = now;
      return roads;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('autobahn road list failed: ${e.runtimeType}');
      }
      if (cached != null) return cached;
      throw const AutobahnUnavailable();
    }
  }

  /// Items of one road, from cache when fresh. Null when a request failed.
  Future<List<AutobahnItem>?> _roadItems(String road, DateTime deadline) {
    final hit = _cache[road];
    if (hit != null && _clock().difference(hit.at) < kAutobahnRoadTtl) {
      return Future.value(hit.items);
    }
    return _inFlight[road] ??= () async {
      try {
        final parts = await Future.wait(
          kAutobahnServices.map(
            (s) => _getJson(
              Uri.parse(kAutobahnApiBase).replace(
                pathSegments: [
                  ...Uri.parse(kAutobahnApiBase).pathSegments,
                  road,
                  'services',
                  s,
                ],
              ),
              deadline,
            ),
          ),
        );
        final seen = <String>{};
        final items = [
          for (final p in parts)
            for (final it in parseAutobahnItems(road, p))
              if (seen.add(it.identifier)) it,
        ];
        _cache[road] = _RoadEntry(items, _clock());
        return items;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('autobahn road failed: ${e.runtimeType}');
        }
        return null;
      } finally {
        _inFlight.remove(road);
      }
    }();
  }

  bool get _indexFresh =>
      _indexAt != null && _clock().difference(_indexAt!) < kAutobahnIndexTtl;

  /// Closures and roadworks within [radiusKm] of the point, grouped.
  /// Throws [AutobahnUnavailable] when the road list cannot be loaded.
  Future<AutobahnLookup> closuresAround({
    required double lat,
    required double lon,
    double radiusKm = 5,
  }) async {
    final deadline = _clock().add(_lookupDeadline);
    final startRequests = _requests;
    final roads = await _roadList(deadline);
    final fullScan = !_indexFresh;
    final asked = fullScan
        ? roads
        : roads.where((r) {
            if (!_index.containsKey(r)) return true;
            final b = _index[r];
            return b != null && b.touchesCircle(lat, lon, radiusKm);
          }).toList();

    final results = await Future.wait(
      asked.map((r) => _roadItems(r, deadline)),
    );

    final near = <AutobahnItem>[];
    var failed = 0;
    for (var i = 0; i < asked.length; i++) {
      final items = results[i];
      if (items == null) {
        failed++;
        _index.remove(asked[i]);
        continue;
      }
      _index[asked[i]] = _Bounds.of(
        items.expand((it) => it.closure.geometry.allPoints),
      );
      for (final it in items) {
        if (distanceToGeometryKm(it.closure.geometry, lat, lon) <= radiusKm) {
          near.add(it);
        }
      }
    }
    if (fullScan) _indexAt = _clock();

    return AutobahnLookup(
      closures: groupAutobahnItems(near),
      roadsAsked: asked.length,
      roadsFailed: failed,
      requests: _requests - startRequests,
    );
  }

  /// Geometry of an `ab:` ref. Fetches the road (2 requests) unless it is
  /// cached.
  Future<ResolvedGeometry> refGeometry(String ref) async {
    final parsed = parseAutobahnRef(ref);
    if (parsed == null) return ResolvedGeometry.empty;
    final (road, ids) = parsed;
    final items = await _roadItems(road, _clock().add(_lookupDeadline));
    if (items == null) return ResolvedGeometry.empty;
    final wanted = ids.toSet();
    var g = ResolvedGeometry.empty;
    for (final it in items) {
      if (wanted.contains(it.shortId) || wanted.contains(it.identifier)) {
        g = g.merge(it.closure.geometry);
      }
    }
    return g;
  }
}
