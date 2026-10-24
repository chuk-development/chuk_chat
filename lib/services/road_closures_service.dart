// lib/services/road_closures_service.dart
//
// Official roadworks and closures for northern Germany, keyless.
//
// Source: the ArcGIS MapServer behind the LBV.SH "Baustelleninformationen"
// map (strasseninfo-sh.de → Digitaler Atlas Nord). It carries roadworks on
// federal, state and some county roads plus motorways in Schleswig-Holstein,
// TIC traffic events (LMS SH), detour routes, and the feeds of Hamburg,
// Lower Saxony, Mecklenburg-Western Pomerania and Norderstedt. Lines come
// with their real geometry, so the map can draw the closed stretch.
//
// Municipal streets are mostly missing: a town's own closures live on the
// town's website, which the model finds with web_search.
//
// Parsing is pure and unit tested; the fetch helpers are thin wrappers.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/utils/map_features.dart';

const String kRoadworksMapServer =
    'https://service.gdi-sh.de/REST_AGS_SH_Baustelleninformationen_DANord/'
    'arcgis/rest/services/FACHDATEN/Baustelleninformationen_DANord/MapServer';

/// Neutral agent string: the app name only, no user or device data.
const Map<String, String> kRoadworksHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'chuk-chat/1.0',
};

const Duration _timeout = Duration(seconds: 20);

/// Prefix of a feature `ref` that points into [kRoadworksMapServer].
const String kRoadworksRefPrefix = 'sh:';

/// Rough box the feed covers (SH, HH, NI, MV).
bool roadworksFeedCovers(double lat, double lon) =>
    lat >= 51.25 && lat <= 55.1 && lon >= 6.6 && lon <= 14.5;

/// One layer of the map service.
class RoadworksLayer {
  const RoadworksLayer(
    this.id,
    this.source, {
    this.isLine = false,
    this.isoIsUtc = false,
    this.isDetour = false,
  });

  final int id;
  final String source;
  final bool isLine;

  /// The SH layers write ISO timestamps in UTC ("2026-02-02 23:00:00" is
  /// midnight in Germany).
  final bool isoIsUtc;
  final bool isDetour;
}

/// The layers worth asking. Layer 11 (Verkehrslagen) is traffic flow, not
/// closures, and is left out.
const List<RoadworksLayer> kRoadworksLayers = [
  RoadworksLayer(8, 'LBV.SH', isLine: true, isoIsUtc: true),
  RoadworksLayer(10, 'Autobahn GmbH', isLine: true, isoIsUtc: true),
  RoadworksLayer(9, 'Niedersachsen', isLine: true),
  RoadworksLayer(7, 'Verkehrsmeldung (LMS SH)', isLine: true),
  RoadworksLayer(6, 'Umleitung', isLine: true, isDetour: true),
  RoadworksLayer(0, 'LBV.SH', isoIsUtc: true),
  RoadworksLayer(5, 'Autobahn GmbH', isoIsUtc: true),
  RoadworksLayer(2, 'Niedersachsen'),
  RoadworksLayer(1, 'Hamburg'),
  RoadworksLayer(3, 'Mecklenburg-Vorpommern'),
  RoadworksLayer(4, 'Norderstedt'),
];

RoadworksLayer? _layerById(int id) {
  for (final l in kRoadworksLayers) {
    if (l.id == id) return l;
  }
  return null;
}

/// A start/end pair read from one of the feed's many date formats.
class DateRange {
  const DateRange(this.start, this.end);
  final DateTime? start;
  final DateTime? end;
}

final RegExp _isoDate = RegExp(
  r'(\d{4})-(\d{2})-(\d{2})(?:[ T,]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
);
final RegExp _deDate = RegExp(
  r'(\d{1,2})\.(\d{1,2})\.(\d{4})(?:,?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
);

/// Reads the first two dates from [text]: "2026-02-02 23:00:00 bis …",
/// "20.03.2023 00:00:00 bis …", "von 01.07.2026 00:00 Uhr bis …",
/// "2026-09-07 - 2026-10-31". ISO timestamps are taken as UTC when
/// [isoIsUtc] is set and returned in local time.
DateRange parseDateRange(String? text, {bool isoIsUtc = false}) {
  if (text == null || text.trim().isEmpty) return const DateRange(null, null);
  final found = <(int, DateTime)>[];
  for (final m in _isoDate.allMatches(text)) {
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    final h = int.tryParse(m[4] ?? '') ?? 0;
    final mi = int.tryParse(m[5] ?? '') ?? 0;
    final dt = (isoIsUtc && m[4] != null)
        ? DateTime.utc(y, mo, d, h, mi).toLocal()
        : DateTime(y, mo, d, h, mi);
    found.add((m.start, dt));
  }
  for (final m in _deDate.allMatches(text)) {
    final d = int.parse(m[1]!), mo = int.parse(m[2]!), y = int.parse(m[3]!);
    final h = int.tryParse(m[4] ?? '') ?? 0;
    final mi = int.tryParse(m[5] ?? '') ?? 0;
    found.add((m.start, DateTime(y, mo, d, h, mi)));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return DateRange(
    found.isNotEmpty ? found[0].$2 : null,
    found.length > 1 ? found[1].$2 : null,
  );
}

String _two(int v) => v.toString().padLeft(2, '0');

/// "03.02.2026"
String formatGermanDate(DateTime d) =>
    '${_two(d.day)}.${_two(d.month)}.${d.year}';

/// One closure or roadworks measure, possibly made of several segments.
class RoadClosure {
  RoadClosure({
    required this.layer,
    required this.ids,
    required this.kind,
    required this.title,
    this.road,
    this.restriction,
    this.start,
    this.end,
    this.detour,
    this.notes,
    this.limits,
    this.geometry = ResolvedGeometry.empty,
  });

  final int layer;
  final List<int> ids;
  final MapFeatureKind kind;
  final String title;
  final String? road;
  final String? restriction;
  final DateTime? start;
  final DateTime? end;
  final String? detour;
  final String? notes;
  final String? limits;
  ResolvedGeometry geometry;

  String get source => _layerById(layer)?.source ?? 'DANord';

  /// What a map feature writes to point back at this measure.
  String get ref => '$kRoadworksRefPrefix$layer:${ids.join(',')}';

  String get datesLabel {
    final s = start, e = end;
    if (s != null && e != null) {
      return '${formatGermanDate(s)} – ${formatGermanDate(e)}';
    }
    if (s != null) return 'ab ${formatGermanDate(s)}';
    if (e != null) return 'bis ${formatGermanDate(e)}';
    return '';
  }

  String get _dedupeKey =>
      '${title.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}|$datesLabel';
}

String? _attr(Map<String, dynamic> a, List<String> keys) {
  for (final k in keys) {
    final v = a[k];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isNotEmpty && s != '-' && s.toLowerCase() != 'null') return s;
  }
  return null;
}

String _fmtNum(dynamic v) {
  final d = v is num ? v.toDouble() : double.tryParse(v.toString());
  if (d == null) return v.toString();
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

/// Decides closure vs roadworks from the German wording.
MapFeatureKind classifyRestriction(String text) {
  final t = text.toLowerCase();
  if (t.contains('vollsperrung') || t.contains('voll gesperrt')) {
    return MapFeatureKind.closure;
  }
  if (t.contains('halbseitig') ||
      t.contains('fahrstreifen gesperrt') ||
      t.contains('verengt') ||
      t.contains('einengung') ||
      t.contains('lichtsignal') ||
      t.contains('lichtzeichen') ||
      t.contains('ampel')) {
    return MapFeatureKind.roadworks;
  }
  if (t.contains('gesperrt') || t.contains('sperrung')) {
    return MapFeatureKind.closure;
  }
  return MapFeatureKind.roadworks;
}

/// Parses one layer's ArcGIS query response into closures (one per
/// feature, not yet grouped). Malformed features are skipped.
List<RoadClosure> parseRoadworksLayer(int layerId, dynamic json) {
  final layer = _layerById(layerId) ?? RoadworksLayer(layerId, 'DANord');
  if (json is! Map) return const [];
  final features = json['features'];
  if (features is! List) return const [];
  final out = <RoadClosure>[];
  for (final f in features) {
    if (f is! Map) continue;
    final raw = f['attributes'];
    if (raw is! Map) continue;
    final a = Map<String, dynamic>.from(raw);
    final id = a['objectid'] ?? a['OBJECTID'];
    final idNum = id is num ? id.toInt() : int.tryParse('$id');
    if (idNum == null) continue;

    final infos = _attr(a, ['infos', 'verkehrs__und_reiseereignis']);
    var title = _attr(a, ['header']) ?? '';
    String? infoRest;
    if (infos != null) {
      final lines = infos.split('\n').map((l) => l.trim()).toList();
      if (title.length <= 12 || title.isEmpty) {
        title = [if (title.isNotEmpty) title, lines.first].join(': ');
        infoRest = lines.skip(1).where((l) => l.isNotEmpty).join(', ');
      } else {
        infoRest = lines.where((l) => l.isNotEmpty).join(', ');
      }
    }
    if (title.isEmpty) continue;

    final restriction = _attr(a, [
      'verkehrseinschränkung',
      'ereignis',
      'erlaeuterung',
      'sperrart',
    ]);

    String? datesText = _attr(a, ['dauer_der_bauphase', 'dauer', 'gültigkeit']);
    final begin = _attr(a, ['baubeginn']);
    final finish = _attr(a, ['bauende']);
    if (datesText == null && (begin != null || finish != null)) {
      datesText = '${begin ?? ''} bis ${finish ?? ''}';
    }
    var range = parseDateRange(datesText, isoIsUtc: layer.isoIsUtc);
    if (begin == null && finish != null && range.start != null) {
      range = DateRange(null, range.start);
    }

    final limits = <String>[
      if (a['höchstgeschwindigkeit_in_km_h'] != null)
        'max ${_fmtNum(a['höchstgeschwindigkeit_in_km_h'])} km/h',
      if (a['verbleibende_restbreite_in_m'] is num &&
          (a['verbleibende_restbreite_in_m'] as num) > 0)
        'Restbreite ${_fmtNum(a['verbleibende_restbreite_in_m'])} m',
      if (a['gewichtsbeschränkung_in_t'] != null)
        'max ${_fmtNum(a['gewichtsbeschränkung_in_t'])} t',
      if (a['höhenbeschränkung_in_m'] != null)
        'max Höhe ${_fmtNum(a['höhenbeschränkung_in_m'])} m',
    ];

    final vonNach = (a['von'] != null && a['nach'] != null)
        ? '${a['von']} → ${a['nach']}'
        : null;
    final notes = [
      _attr(a, ['hinweise_zur_verkehrsführung']),
      vonNach,
      infoRest,
      _attr(a, ['zusätzliche_information', 'anderemassnahmen']),
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

    final kind = layer.isDetour
        ? MapFeatureKind.detour
        : classifyRestriction('${restriction ?? ''} $title ${infos ?? ''}');

    out.add(
      RoadClosure(
        layer: layerId,
        ids: [idNum],
        kind: kind,
        title: title,
        road: _attr(a, ['straßenname', 'strasse']),
        restriction: restriction,
        start: range.start,
        end: range.end,
        detour: layer.isDetour
            ? _attr(a, ['streckenführung'])
            : _attr(a, ['umleitungsempfehlung', 'verkehrslenkung']),
        notes: notes.isEmpty ? null : notes,
        limits: limits.isEmpty ? null : limits.join(', '),
        geometry: geometryFromArcgis(f['geometry']),
      ),
    );
  }
  return out;
}

/// Folds segments of one measure into one entry and drops point copies of
/// measures that already came as lines. [closures] should list line layers
/// first (as [kRoadworksLayers] does).
List<RoadClosure> groupRoadClosures(List<RoadClosure> closures) {
  final byKey = <String, RoadClosure>{};
  final ordered = <RoadClosure>[];
  for (final c in closures) {
    final key = c._dedupeKey;
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = c;
      ordered.add(c);
      continue;
    }
    if (existing.layer == c.layer) {
      existing.ids.addAll(c.ids);
      existing.geometry = existing.geometry.merge(c.geometry);
    }
    // Same measure from another layer (the point copy of a line): skip.
  }
  return ordered;
}

/// Drops finished measures and those starting later than [daysAhead];
/// active ones first, then by start date.
List<RoadClosure> filterCurrentClosures(
  List<RoadClosure> closures, {
  required DateTime now,
  int daysAhead = 30,
}) {
  final horizon = now.add(Duration(days: daysAhead));
  final kept = closures.where((c) {
    if (c.end != null && c.end!.isBefore(now)) return false;
    if (c.start != null && c.start!.isAfter(horizon)) return false;
    return true;
  }).toList();
  bool active(RoadClosure c) => c.start == null || !c.start!.isAfter(now);
  kept.sort((a, b) {
    final aa = active(a), ba = active(b);
    if (aa != ba) return aa ? -1 : 1;
    final kindOrder = a.kind.index.compareTo(b.kind.index);
    if (kindOrder != 0) return kindOrder;
    return (a.start ?? now).compareTo(b.start ?? now);
  });
  return kept;
}

String _kindWord(MapFeatureKind k) => switch (k) {
  MapFeatureKind.closure => 'CLOSURE',
  MapFeatureKind.roadworks => 'ROADWORKS',
  MapFeatureKind.detour => 'DETOUR',
  MapFeatureKind.info => 'INFO',
};

String _short(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1)}…';

/// The map feature JSON the model can copy into a <map> block.
Map<String, dynamic> closureMapFeature(RoadClosure c) => {
  'kind': c.kind.name,
  'ref': c.ref,
  'label': _short(c.title, 60),
  if (c.datesLabel.isNotEmpty) 'dates': c.datesLabel,
  if (c.restriction != null || c.limits != null)
    'info': [c.restriction, c.limits].whereType<String>().join(', '),
  if (c.detour != null) 'detour': _short(c.detour!, 160),
};

/// The text the model reads.
String formatClosuresForModel({
  required List<RoadClosure> closures,
  required String placeLabel,
  required double lat,
  required double lon,
  required double radiusKm,
  required DateTime now,
  int maxItems = 15,
}) {
  final buf = StringBuffer();
  buf.writeln(
    'Official roadworks feed (LBV.SH / Digitaler Atlas Nord: federal, state '
    'and some county roads and motorways in Schleswig-Holstein, TIC traffic '
    'events, plus the Hamburg, Lower Saxony, Mecklenburg-Vorpommern and '
    'Norderstedt feeds). Area: ${radiusKm.toStringAsFixed(0)} km around '
    '$placeLabel (${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}). '
    'Today: ${formatGermanDate(now)}.',
  );
  if (closures.isEmpty) {
    buf.writeln('No current or upcoming entries in this area.');
  } else {
    buf.writeln('${closures.length} entries:');
  }
  var i = 0;
  for (final c in closures.take(maxItems)) {
    i++;
    final active = c.start == null || !c.start!.isAfter(now);
    final status = active
        ? 'active'
        : 'starts ${formatGermanDate(c.start!)}';
    buf.writeln();
    buf.writeln('$i. ${_kindWord(c.kind)} · $status · ${c.title}');
    final details = [
      if (c.road != null) 'Road: ${c.road}',
      if (c.restriction != null) 'Restriction: ${c.restriction}',
      if (c.limits != null) c.limits!,
    ];
    if (details.isNotEmpty) buf.writeln('   ${details.join(' · ')}');
    if (c.datesLabel.isNotEmpty) buf.writeln('   When: ${c.datesLabel}');
    if (c.detour != null) buf.writeln('   Detour: ${c.detour}');
    if (c.notes != null) buf.writeln('   Notes: ${_short(c.notes!, 300)}');
    buf.writeln('   Source: ${c.source}');
    buf.writeln('   Map feature: ${jsonEncode(closureMapFeature(c))}');
  }
  if (closures.length > maxItems) {
    buf.writeln();
    buf.writeln('… ${closures.length - maxItems} more not shown.');
  }
  buf.writeln();
  buf.writeln(
    'Municipal streets (Gemeindestraßen) are mostly NOT in this feed. For a '
    'town, also web_search "<town> Sperrung" / "<town> Vollsperrung" (the '
    'town website and local news) and draw what you find as '
    '{"kind":"closure","road":"<street>","town":"<town>","from":"<cross '
    'street>","to":"<cross street>","dates":"…","detour":"…"}. Copy the '
    '"Map feature" objects above unchanged into the "features" list of one '
    '<map> block (format: skill map-features).',
  );
  return buf.toString().trimRight();
}

String _envelope(double lat, double lon, double radiusKm) {
  final dLat = radiusKm / 111.0;
  final dLon = radiusKm / (111.0 * math.max(0.01, math.cos(lat * math.pi / 180)));
  return '${lon - dLon},${lat - dLat},${lon + dLon},${lat + dLat}';
}

Future<List<RoadClosure>> _queryLayer(
  http.Client client,
  RoadworksLayer layer,
  Map<String, String> params,
) async {
  final uri = Uri.parse(
    '$kRoadworksMapServer/${layer.id}/query',
  ).replace(queryParameters: params);
  try {
    final res = await client
        .get(uri, headers: kRoadworksHeaders)
        .timeout(_timeout);
    if (res.statusCode != 200) return const [];
    return parseRoadworksLayer(layer.id, jsonDecode(utf8.decode(res.bodyBytes)));
  } catch (e) {
    if (kDebugMode) {
      debugPrint('roadworks layer ${layer.id} failed: ${e.runtimeType}');
    }
    return const [];
  }
}

/// Every layer's entries within [radiusKm] of the point, grouped.
Future<List<RoadClosure>> fetchRoadClosuresAround({
  required double lat,
  required double lon,
  double radiusKm = 5,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final params = {
      'where': '1=1',
      'geometry': _envelope(lat, lon, radiusKm),
      'geometryType': 'esriGeometryEnvelope',
      'inSR': '4326',
      'spatialRel': 'esriSpatialRelIntersects',
      'outFields': '*',
      'outSR': '4326',
      'returnGeometry': 'true',
      'f': 'json',
    };
    final results = await Future.wait(
      kRoadworksLayers.map((l) => _queryLayer(c, l, params)),
    );
    return groupRoadClosures(results.expand((r) => r).toList());
  } finally {
    if (client == null) c.close();
  }
}

/// Parses "sh:8:113,117" into (8, [113, 117]). Null when malformed.
(int, List<int>)? parseRoadworksRef(String ref) {
  final m = RegExp(r'^sh:(\d+):([\d,\s]+)$').firstMatch(ref.trim());
  if (m == null) return null;
  final ids = m[2]!
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .toList();
  if (ids.isEmpty) return null;
  return (int.parse(m[1]!), ids);
}

/// Geometry of a ref, fetched by object id.
Future<ResolvedGeometry> fetchRoadworksRefGeometry(
  String ref, {
  http.Client? client,
}) async {
  final parsed = parseRoadworksRef(ref);
  if (parsed == null) return ResolvedGeometry.empty;
  final layer = _layerById(parsed.$1);
  if (layer == null) return ResolvedGeometry.empty;
  final c = client ?? http.Client();
  try {
    final found = await _queryLayer(c, layer, {
      'objectIds': parsed.$2.take(200).join(','),
      'outFields': '*',
      'outSR': '4326',
      'returnGeometry': 'true',
      'f': 'json',
    });
    var g = ResolvedGeometry.empty;
    for (final f in found) {
      g = g.merge(f.geometry);
    }
    return g;
  } finally {
    if (client == null) c.close();
  }
}
