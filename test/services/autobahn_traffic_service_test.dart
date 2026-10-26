import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'package:chuk_chat/services/autobahn_traffic_service.dart';
import 'package:chuk_chat/services/road_closures_service.dart';
import 'package:chuk_chat/utils/map_features.dart';

// Shapes copied from verkehr.autobahn.de (A7 closure/roadworks), trimmed.
Map<String, dynamic> _item({
  required String id,
  String title = 'A7 | Füssen - Nesselwang',
  String subtitle = ' Füssen/Reutte -> Ulm',
  String displayType = 'SHORT_TERM_ROADWORKS',
  String isBlocked = 'false',
  double lat = 47.599,
  double lon = 10.656,
  List<String>? description,
}) => {
  'identifier': id,
  'isBlocked': isBlocked,
  'future': true,
  'extent': '$lat,$lon,${lat + 0.007},$lon',
  'display_type': displayType,
  'subtitle': subtitle,
  'title': title,
  'coordinate': {'lat': '$lat', 'long': '$lon'},
  'description':
      description ??
      [
        'Die Baustelle ist zu folgenden Zeiträumen gültig:',
        '27.10.26 von 17:00 bis 22:00 Uhr',
        '',
        'A7: Füssen/Reutte -> Ulm, zwischen AS Füssen und AS Nesselwang',
        '',
        'Länge: 0.78 km | Max. 80 km/h | Maximale Durchfahrtsbreite: 3.5 m',
        '',
        'A7 Tunnel Reinertshof - Installation Notstromversorgung',
      ],
  'geometry': {
    'type': 'LineString',
    'coordinates': [
      [lon, lat],
      [lon + 0.001, lat + 0.007],
    ],
  },
};

/// Fake API: road list plus per-road closure/roadworks lists. Counts
/// requests per path.
class _FakeApi {
  _FakeApi(this.roads);

  final Map<String, Map<String, List<Map<String, dynamic>>>> roads;
  final Map<String, int> hits = {};
  final Set<String> failing = {};
  final List<Map<String, String>> headers = [];

  int get total => hits.values.fold(0, (a, b) => a + b);

  late final http.Client client = MockClient((req) async {
    headers.add(req.headers);
    final path = req.url.path;
    hits[path] = (hits[path] ?? 0) + 1;
    final seg = req.url.pathSegments.where((s) => s.isNotEmpty).toList();
    // /o/autobahn/  or  /o/autobahn/<road>/services/<service>
    if (seg.length == 2) {
      return http.Response(jsonEncode({'roads': roads.keys.toList()}), 200);
    }
    final road = seg[2];
    final service = seg[4];
    if (failing.contains(road)) return http.Response('busy', 503);
    final list = roads[road]?[service] ?? const [];
    return http.Response.bytes(
      utf8.encode(jsonEncode({service: list})),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  group('parseAutobahnValidity', () {
    test('Beginn/Ende lines', () {
      final r = parseAutobahnValidity([
        'Beginn: 05.10.26 um 00:00 Uhr',
        'Ende: 01.12.26 um 06:30 Uhr',
      ]);
      expect(r.start, DateTime(2026, 10, 5));
      expect(r.end, DateTime(2026, 12, 1, 6, 30));
    });

    test('one day with hours, and a range over midnight', () {
      final day = parseAutobahnValidity(['27.10.26 von 17:00 bis 22:00 Uhr']);
      expect(day.start, DateTime(2026, 10, 27, 17));
      expect(day.end, DateTime(2026, 10, 27, 22));
      final night = parseAutobahnValidity([
        '29.10.26 20:00 bis zum 30.10.26 05:00 Uhr.',
      ]);
      expect(night.start, DateTime(2026, 10, 29, 20));
      expect(night.end, DateTime(2026, 10, 30, 5));
    });

    test('no dates', () {
      expect(parseAutobahnValidity(['demnächst']).start, isNull);
      expect(parseAutobahnValidity(const []).end, isNull);
    });
  });

  group('parseAutobahnItems', () {
    test('roadworks item: dates, limits, direction, geometry, ref', () {
      final items = parseAutobahnItems('A7', {
        'roadworks': [_item(id: 'x-1')],
      });
      final c = items.single.closure;
      expect(c.kind, MapFeatureKind.roadworks);
      expect(c.title, 'A7 | Füssen - Nesselwang');
      expect(c.direction, 'Füssen/Reutte -> Ulm');
      expect(c.start, DateTime(2026, 10, 27, 17));
      expect(c.end, DateTime(2026, 10, 27, 22));
      expect(c.whenText, '27.10.26 von 17:00 bis 22:00 Uhr');
      expect(c.limits, contains('Max. 80 km/h'));
      expect(c.notes, contains('Notstromversorgung'));
      expect(c.notes, isNot(contains('zwischen AS')));
      expect(c.geometry.lines.single, hasLength(2));
      expect(c.ref, 'ab:A7:${autobahnShortId('x-1')}');
      expect(c.source, 'Autobahn GmbH');
      expect(c.restriction, 'Tagesbaustelle');
    });

    test('closures and the blocked flag make a closure', () {
      final items = parseAutobahnItems('A7', {
        'closure': [
          _item(id: 'c', displayType: 'CLOSURE_ENTRY_EXIT'),
          _item(id: 'b', displayType: 'ROADWORKS', isBlocked: 'true'),
        ],
      });
      expect(items.map((i) => i.closure.kind), [
        MapFeatureKind.closure,
        MapFeatureKind.closure,
      ]);
      expect(items.last.closure.blocked, isTrue);
    });

    test('Gesamtmaßnahme end only counts without phase dates', () {
      final c = parseAutobahnItems('A7', {
        'closure': [
          _item(
            id: 'g',
            description: [
              'Die Baustelle ist zu folgenden Zeiträumen gültig:',
              '29.10.26 20:00 bis zum 30.10.26 05:00 Uhr.',
              '(Ende der Gesamtmaßnahme: 30.11.26)',
            ],
          ),
        ],
      }).single.closure;
      expect(c.end, DateTime(2026, 10, 30, 5));
      expect(c.whenText, isNot(contains('Gesamtmaßnahme')));
    });

    test('plain Beginn/Ende uses the date label; location lines drop', () {
      final c = parseAutobahnItems('A96', {
        'roadworks': [
          _item(
            id: 'b',
            title: 'A96 Spartendüker',
            description: [
              'Zeitraum dieser Bauphase:',
              'Beginn: 19.04.26 um 00:00 Uhr',
              'Ende: 31.10.26 um 06:00 Uhr',
              '',
              'Von A96: Lindau -> München, zwischen AS Blumenau und AS Sendling',
              '',
              'A96 Spartendüker',
              '',
              'Tram Westtangente',
            ],
          ),
        ],
      }).single.closure;
      expect(c.whenText, isNull);
      expect(c.datesLabel, '19.04.2026 – 31.10.2026');
      expect(c.notes, 'Tram Westtangente');
    });

    test('malformed input gives nothing, never throws', () {
      expect(parseAutobahnItems('A7', null), isEmpty);
      expect(parseAutobahnItems('A7', {'roadworks': 'x'}), isEmpty);
      expect(
        parseAutobahnItems('A7', {
          'roadworks': [
            'x',
            {'identifier': 'no title'},
            {'title': 'no id'},
          ],
        }),
        isEmpty,
      );
    });

    test('item without geometry falls back to its coordinate', () {
      final raw = _item(id: 'p')..remove('geometry');
      final c = parseAutobahnItems('A7', {
        'roadworks': [raw],
      }).single.closure;
      expect(c.geometry.point?.latitude, closeTo(47.599, 1e-9));
    });
  });

  group('refs', () {
    test('short id is stable and 8 hex chars', () {
      expect(autobahnShortId('abc'), autobahnShortId('abc'));
      expect(autobahnShortId('abc'), isNot(autobahnShortId('abd')));
      expect(autobahnShortId('abc'), matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('parse', () {
      final r = parseAutobahnRef('ab:A7:1a2b3c4d, 5e6f7a8b')!;
      expect(r.$1, 'A7');
      expect(r.$2, ['1a2b3c4d', '5e6f7a8b']);
      expect(parseAutobahnRef('ab:A7:'), isNull);
      expect(parseAutobahnRef('sh:8:1'), isNull);
      expect(parseAutobahnRef('ab:../x:1'), isNull);
    });

    test('a map feature with an ab: ref parses into a resolvable spec', () {
      final c = parseAutobahnItems('A7', {
        'roadworks': [_item(id: 'x-1')],
      }).single.closure;
      final f = closureMapFeature(c);
      expect(f['dates'], '27.10.26 von 17:00 bis 22:00 Uhr');
      expect(f['info'], contains('Füssen/Reutte -> Ulm'));
      final spec = parseMapFeature(
        jsonDecode(jsonEncode(f)) as Map<String, dynamic>,
      )!;
      expect(spec.ref, c.ref);
      expect(spec.needsResolve, isTrue);
    });
  });

  group('distance and grouping', () {
    test('distance uses segments, not only vertices', () {
      // A line from 0.1° west to 0.1° east of the centre, no vertex near.
      final g = ResolvedGeometry(
        lines: [
          [const LatLng(50.0, 9.9), const LatLng(50.0, 10.1)],
        ],
      );
      expect(distanceToGeometryKm(g, 50.0, 10.0), lessThan(0.01));
      expect(distanceToGeometryKm(g, 50.1, 10.0), closeTo(11.06, 0.1));
      expect(
        distanceToGeometryKm(ResolvedGeometry.empty, 50, 10),
        double.infinity,
      );
    });

    test('both directions fold into one entry with a joined ref', () {
      final items = parseAutobahnItems('A7', {
        'roadworks': [
          _item(id: 'n'),
          _item(id: 's', subtitle: ' Ulm -> Füssen/Reutte'),
        ],
      });
      final grouped = groupAutobahnItems(items);
      expect(grouped, hasLength(1));
      expect(
        grouped.single.ref,
        'ab:A7:${autobahnShortId('n')},${autobahnShortId('s')}',
      );
      expect(grouped.single.direction, 'beide Richtungen');
      expect(grouped.single.geometry.lines, hasLength(2));
      // The parsed items stay untouched (they live in the cache).
      expect(items.first.closure.geometry.lines, hasLength(1));
    });

    test('DANord Autobahn copies drop, other DANord entries stay', () {
      final ab = parseAutobahnItems('A24', {
        'roadworks': [
          _item(
            id: 'a',
            title: 'A24 | Kreuz Schwerin',
            lat: 53.6,
            lon: 11.4,
            description: [
              'Beginn: 05.10.26 um 00:00 Uhr',
              'Ende: 01.12.26 um 00:00 Uhr',
            ],
          ),
        ],
      }).map((i) => i.closure).toList();
      RoadClosure danord(int layer, double lat, {String? road = 'A24'}) =>
          RoadClosure(
            layer: layer,
            ids: [1],
            kind: MapFeatureKind.roadworks,
            title: 'Autobahn GmbH: A24, Kreuz Schwerin',
            road: road,
            start: DateTime(2026, 10, 5),
            end: DateTime(2026, 12, 1),
            geometry: ResolvedGeometry(
              lines: [
                [LatLng(lat, 11.4), LatLng(lat + 0.001, 11.4)],
              ],
            ),
          );
      final kept = dropDanordAutobahnCopies([
        danord(10, 53.6), // same measure → dropped
        danord(10, 54.5), // 100 km away → kept
        danord(8, 53.6), // LBV.SH layer, never touched
        danord(5, 53.6, road: null), // point copy, road from the title
      ], ab);
      expect(
        kept.map((c) => (c.layer, c.geometry.lines.first.first.latitude)),
        [(10, 54.5), (8, 53.6)],
      );
    });
  });

  group('AutobahnTrafficService', () {
    late DateTime now;
    late _FakeApi api;
    late AutobahnTrafficService svc;

    setUp(() {
      now = DateTime(2026, 10, 26, 12);
      api = _FakeApi({
        'A7': {
          'roadworks': [_item(id: 'near', lat: 47.599, lon: 10.656)],
          'closure': [_item(id: 'far', lat: 53.5, lon: 9.9)],
        },
        'A1': {
          'roadworks': [_item(id: 'a1', title: 'A1 | x', lat: 53.0, lon: 9.0)],
        },
        'A99': {},
      });
      svc = AutobahnTrafficService(client: api.client, clock: () => now);
    });

    test('finds items within the radius; neutral headers only', () async {
      final r = await svc.closuresAround(lat: 47.6, lon: 10.66, radiusKm: 5);
      expect(r.closures.map((c) => c.title), ['A7 | Füssen - Nesselwang']);
      expect(r.roadsAsked, 3);
      expect(r.roadsFailed, 0);
      expect(r.requests, 1 + 3 * kAutobahnServices.length);
      for (final h in api.headers) {
        expect(h['User-Agent'], 'chuk-chat/1.0');
        expect(h.keys.map((k) => k.toLowerCase()), isNot(contains('from')));
      }
    });

    test('second call within 5 min sends no request', () async {
      await svc.closuresAround(lat: 47.6, lon: 10.66);
      final before = api.total;
      now = now.add(const Duration(minutes: 4));
      final r = await svc.closuresAround(lat: 47.6, lon: 10.66);
      expect(api.total, before);
      expect(r.requests, 0);
      expect(r.closures, hasLength(1));
    });

    test('after 5 min only roads near the point are asked again', () async {
      await svc.closuresAround(lat: 47.6, lon: 10.66);
      now = now.add(const Duration(minutes: 6));
      final r = await svc.closuresAround(lat: 47.6, lon: 10.66);
      // A7 has items near Füssen; A1 (Bremen) and A99 (empty) are skipped.
      expect(r.roadsAsked, 1);
      expect(r.requests, kAutobahnServices.length);
      expect(r.closures, hasLength(1));
    });

    test('after the index expires, every road is asked again', () async {
      await svc.closuresAround(lat: 47.6, lon: 10.66);
      now = now.add(kAutobahnIndexTtl + const Duration(minutes: 1));
      final r = await svc.closuresAround(lat: 47.6, lon: 10.66);
      expect(r.roadsAsked, 3);
    });

    test('a failing road is skipped, not cached, and asked again', () async {
      api.failing.add('A1');
      final r = await svc.closuresAround(lat: 53.0, lon: 9.0);
      expect(r.roadsFailed, 1);
      expect(r.closures, isEmpty);
      api.failing.clear();
      final again = await svc.closuresAround(lat: 53.0, lon: 9.0);
      expect(again.roadsFailed, 0);
      expect(again.closures.single.title, 'A1 | x');
    });

    test('road list failure throws AutobahnUnavailable', () async {
      final broken = AutobahnTrafficService(
        client: MockClient((_) async => http.Response('down', 500)),
        clock: () => now,
      );
      expect(
        broken.closuresAround(lat: 47.6, lon: 10.66),
        throwsA(isA<AutobahnUnavailable>()),
      );
    });

    test('ref geometry: from cache, and by fetching the road', () async {
      final ref = 'ab:A7:${autobahnShortId('near')}';
      final g = await svc.refGeometry(ref);
      expect(g.lines, hasLength(1));
      expect(api.total, kAutobahnServices.length); // one road, no list
      final again = await svc.refGeometry(ref);
      expect(again.lines, hasLength(1));
      expect(api.total, kAutobahnServices.length);
      expect((await svc.refGeometry('ab:A7:ffffffff')).isEmpty, isTrue);
      expect((await svc.refGeometry('ab:A7:near')).lines, hasLength(1));
    });
  });

  group('model text', () {
    test('Autobahn entries are compact and carry their ref', () {
      final c = groupAutobahnItems(
        parseAutobahnItems('A7', {
          'closure': [
            _item(id: 'n', displayType: 'CLOSURE', isBlocked: 'true'),
          ],
        }),
      );
      final text = formatClosuresForModel(
        closures: c,
        placeLabel: 'Füssen',
        lat: 47.57,
        lon: 10.7,
        radiusKm: 5,
        now: DateTime(2026, 10, 26),
        northFeed: false,
        autobahn: true,
      );
      expect(text, contains('Autobahn GmbH'));
      expect(text, contains('CLOSURE · starts 27.10.2026 · A7 | Füssen'));
      expect(text, contains('BLOCKED'));
      expect(text, contains('"ref":"ab:A7:'));
      expect(text, contains('Only motorways are covered'));
      expect(text, isNot(contains('LBV.SH')));
    });

    test('long lists stay under the tool result limit', () {
      final many = [
        for (var i = 0; i < 40; i++)
          ...parseAutobahnItems('A7', {
            'roadworks': [_item(id: 'i$i', title: 'A7 | Abschnitt $i')],
          }).map((it) => it.closure),
      ];
      final text = formatClosuresForModel(
        closures: many,
        placeLabel: 'x',
        lat: 47.6,
        lon: 10.66,
        radiusKm: 25,
        now: DateTime(2026, 10, 26),
        northFeed: false,
        autobahn: true,
        maxItems: 40,
      );
      expect(text.length, lessThan(4000));
      expect(text, contains('more not shown'));
    });
  });

  test('coverage box', () {
    expect(autobahnFeedCovers(48.14, 11.58), isTrue); // München
    expect(autobahnFeedCovers(48.86, 2.35), isFalse); // Paris
  });
}
