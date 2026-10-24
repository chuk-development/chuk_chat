import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:chuk_chat/utils/map_features.dart';

void main() {
  group('isFeaturesMap', () {
    test('features list or closure type', () {
      expect(isFeaturesMap({'features': []}), isTrue);
      expect(isFeaturesMap({'type': 'closures'}), isTrue);
      expect(isFeaturesMap({'type': 'markers', 'markers': []}), isFalse);
    });
  });

  group('parseLatLng', () {
    test('reads map, list and string forms', () {
      expect(parseLatLng({'lat': 54.2, 'lon': 10.3}), const LatLng(54.2, 10.3));
      expect(parseLatLng({'latitude': '54.2', 'lng': '10.3'}),
          const LatLng(54.2, 10.3));
      expect(parseLatLng([54.2, 10.3]), const LatLng(54.2, 10.3));
      expect(parseLatLng('54.2, 10.3'), const LatLng(54.2, 10.3));
    });

    test('swaps an unambiguous lon/lat pair', () {
      expect(parseLatLng([120.0, 45.0]), const LatLng(45.0, 120.0));
    });

    test('rejects garbage and null island', () {
      expect(parseLatLng({'lat': 'abc', 'lon': 1}), isNull);
      expect(parseLatLng([0, 0]), isNull);
      expect(parseLatLng([200, 200]), isNull);
      expect(parseLatLng('Preetz'), isNull);
    });
  });

  group('parseLatLngLines', () {
    test('single, multi, flat and string lines', () {
      expect(parseLatLngLines([
        [54.0, 10.0],
        [54.1, 10.1],
      ]), hasLength(1));
      expect(
        parseLatLngLines([
          [
            [54.0, 10.0],
            [54.1, 10.1],
          ],
          [
            {'lat': 54.2, 'lon': 10.2},
            {'lat': 54.3, 'lon': 10.3},
          ],
        ]),
        hasLength(2),
      );
      expect(parseLatLngLines([54.0, 10.0, 54.1, 10.1]).single, hasLength(2));
      expect(parseLatLngLines('54,10; 54.1,10.1').single, hasLength(2));
    });
  });

  group('parseMapFeatures', () {
    test('road + town + cross streets, with map-level town default', () {
      final block = parseMapFeatures({
        'title': 'Sperrungen Preetz',
        'town': 'Preetz',
        'features': [
          {
            'kind': 'Vollsperrung',
            'road': 'Wakendorfer Straße',
            'from': 'Rethwischer Weg',
            'to': 'Urnenweg',
            'dates': '26.10. – 30.10.',
            'detour': 'über Kührener Straße',
          },
        ],
      });
      expect(block.title, 'Sperrungen Preetz');
      final f = block.features.single;
      expect(f.kind, MapFeatureKind.closure);
      expect(f.road, 'Wakendorfer Straße');
      expect(f.town, 'Preetz');
      expect(f.from?.street, 'Rethwischer Weg');
      expect(f.to?.street, 'Urnenweg');
      expect(f.label, 'Wakendorfer Straße');
      expect(f.detour, 'über Kührener Straße');
      expect(f.needsResolve, isTrue);
    });

    test('kind words in German and English', () {
      expect(parseFeatureKind('Baustelle'), MapFeatureKind.roadworks);
      expect(parseFeatureKind('roadworks'), MapFeatureKind.roadworks);
      expect(parseFeatureKind('Umleitung'), MapFeatureKind.detour);
      expect(parseFeatureKind('closed'), MapFeatureKind.closure);
      expect(parseFeatureKind('marker'), MapFeatureKind.info);
      expect(parseFeatureKind('???', fallback: MapFeatureKind.info),
          MapFeatureKind.info);
    });

    test('a point without kind is info, a road without kind is closure', () {
      final block = parseMapFeatures({
        'features': [
          {'lat': 54.2, 'lon': 10.3, 'label': 'Hier'},
          {'road': 'Markt', 'town': 'Preetz'},
        ],
      });
      expect(block.features[0].kind, MapFeatureKind.info);
      expect(block.features[0].needsResolve, isFalse);
      expect(block.features[1].kind, MapFeatureKind.closure);
    });

    test('area as name or polygon, between as list or string', () {
      final block = parseMapFeatures({
        'features': [
          {'area': 'Marktplatz, Preetz'},
          {
            'area': [
              [54.0, 10.0],
              [54.0, 10.1],
              [54.1, 10.1],
            ],
          },
          {
            'road': 'A',
            'between': ['B', [54.2, 10.3]],
          },
          {'road': 'A', 'between': 'B und C'},
        ],
      });
      expect(block.features[0].areaName, 'Marktplatz, Preetz');
      expect(block.features[1].polygons.single, hasLength(3));
      expect(block.features[1].needsResolve, isFalse);
      expect(block.features[2].from?.street, 'B');
      expect(block.features[2].to?.point, const LatLng(54.2, 10.3));
      expect(block.features[3].to?.street, 'C');
    });

    test('skips junk without crashing and keeps the rest', () {
      final block = parseMapFeatures({
        'features': [
          'nonsense',
          42,
          {'label': 'no geometry'},
          {'line': 'garbage'},
          {'ref': 'sh:8:1', 'start': '01.11.', 'end': '05.11.'},
        ],
        'markers': [
          {'lat': 54.3, 'lon': 10.1, 'label': 'Kiel'},
        ],
      });
      expect(block.features, hasLength(2));
      expect(block.features[0].dates, '01.11. – 05.11.');
      expect(block.features[1].kind, MapFeatureKind.info);
    });
  });

  group('foreign geometry', () {
    test('GeoJSON lon/lat order', () {
      final g = geometryFromGeoJson({
        'type': 'LineString',
        'coordinates': [
          [10.0, 54.0],
          [10.1, 54.1],
        ],
      });
      expect(g.lines.single.first, const LatLng(54.0, 10.0));
      expect(
        geometryFromGeoJson({
          'type': 'Polygon',
          'coordinates': [
            [
              [10.0, 54.0],
              [10.1, 54.0],
              [10.1, 54.1],
              [10.0, 54.0],
            ],
          ],
        }).polygons.single,
        hasLength(4),
      );
      expect(geometryFromGeoJson('x').isEmpty, isTrue);
    });

    test('ArcGIS paths and points', () {
      final g = geometryFromArcgis({
        'paths': [
          [
            [10.35, 54.21],
            [10.36, 54.22],
          ],
        ],
      });
      expect(g.lines.single.last, const LatLng(54.22, 10.36));
      expect(geometryFromArcgis({'x': 10.3, 'y': 54.2}).point,
          const LatLng(54.2, 10.3));
    });
  });

  group('road stretch between cross streets', () {
    // A street in two OSM segments sharing the node at (54.002, 10.0),
    // running south to north, with cross streets meeting it at the
    // vertices (54.001, 10.0) and (54.003, 10.0).
    final road = [
      [
        const LatLng(54.000, 10.0),
        const LatLng(54.001, 10.0),
        const LatLng(54.002, 10.0),
      ],
      [
        const LatLng(54.002, 10.0),
        const LatLng(54.003, 10.0),
        const LatLng(54.004, 10.0),
      ],
    ];
    final crossA = [
      [const LatLng(54.001, 9.999), const LatLng(54.001, 10.0)],
    ];
    final crossB = [
      [const LatLng(54.003, 10.0), const LatLng(54.003, 10.001)],
    ];

    test('finds shared vertices as crossings', () {
      expect(intersectionCandidates(road, crossA),
          [const LatLng(54.001, 10.0)]);
    });

    test('falls back to the nearest vertex within range, else none', () {
      final near = [
        [const LatLng(54.00301, 10.0001), const LatLng(54.0031, 10.001)],
      ];
      expect(intersectionCandidates(road, near), [const LatLng(54.003, 10.0)]);
      final far = [
        [const LatLng(55.0, 11.0), const LatLng(55.1, 11.1)],
      ];
      expect(intersectionCandidates(road, far), isEmpty);
    });

    test('clips across segments', () {
      final a = intersectionCandidates(road, crossA);
      final b = intersectionCandidates(road, crossB);
      final clipped = clipRoadBetween(road, a, b)!;
      expect(clipped.first, const LatLng(54.001, 10.0));
      expect(clipped.last, const LatLng(54.003, 10.0));
      expect(clipped, hasLength(3));
      expect(pathLength(clipped), closeTo(222, 3));
    });

    test('picks the shortest pair when a street crosses twice', () {
      final clipped = clipRoadBetween(
        road,
        [const LatLng(54.000, 10.0), const LatLng(54.002, 10.0)],
        [const LatLng(54.003, 10.0)],
      )!;
      expect(clipped.first, const LatLng(54.002, 10.0));
    });

    test('disconnected or identical ends give null', () {
      final split = [
        [const LatLng(54.0, 10.0), const LatLng(54.001, 10.0)],
        [const LatLng(54.01, 10.0), const LatLng(54.011, 10.0)],
      ];
      expect(
        shortestPathOnRoad(
          split,
          const LatLng(54.0, 10.0),
          const LatLng(54.011, 10.0),
        ),
        isNull,
      );
      expect(
        shortestPathOnRoad(
          road,
          const LatLng(54.001, 10.0),
          const LatLng(54.001, 10.0),
        ),
        isNull,
      );
    });

    test('label point sits halfway along the longest line', () {
      final g = ResolvedGeometry(lines: [road[0]]);
      final p = g.labelPoint!;
      expect(p.latitude, closeTo(54.001, 1e-6));
    });
  });
}
