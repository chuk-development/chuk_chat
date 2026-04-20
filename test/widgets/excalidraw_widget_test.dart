import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/excalidraw_svg_export.dart';
import 'package:chuk_chat/widgets/excalidraw_widget.dart';

const _sampleScene = '''
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [
    {"type":"rectangle","id":"r1","x":100,"y":100,"width":200,"height":100,
     "strokeColor":"#1e1e1e","backgroundColor":"#a5d8ff","fillStyle":"solid",
     "strokeWidth":2,"roundness":{"type":3}},
    {"type":"text","id":"t1","x":150,"y":138,"width":100,"height":24,
     "text":"Hello","fontSize":20,"fontFamily":1,"textAlign":"center",
     "strokeColor":"#1e1e1e"},
    {"type":"arrow","id":"a1","x":320,"y":150,"width":200,"height":0,
     "points":[[0,0],[200,0]],"endArrowhead":"arrow",
     "strokeColor":"#1e1e1e","strokeWidth":2},
    {"type":"ellipse","id":"e1","x":540,"y":100,"width":120,"height":100,
     "strokeColor":"#2f9e44","backgroundColor":"#b2f2bb","fillStyle":"hachure",
     "strokeWidth":2},
    {"type":"diamond","id":"d1","x":200,"y":260,"width":120,"height":80,
     "strokeColor":"#e03131","strokeStyle":"dashed","strokeWidth":2}
  ],
  "appState":{"viewBackgroundColor":"#ffffff"},
  "files":{}
}
''';

void main() {
  group('ExcalidrawScene.fromJson', () {
    test('parses a valid scene and computes padded bounds', () {
      final scene = ExcalidrawScene.fromJson(_sampleScene);
      expect(scene, isNotNull);
      expect(scene!.elements.length, 5);
      // Raw bounds: x ∈ [100, 660], y ∈ [100, 340] → padded +16 each side.
      expect(scene.sceneWidth, greaterThan(500));
      expect(scene.sceneHeight, greaterThan(200));
      expect(scene.minX, 100);
      expect(scene.minY, 100);
    });

    test('returns null for empty / malformed input', () {
      expect(ExcalidrawScene.fromJson(''), isNull);
      expect(() => ExcalidrawScene.fromJson('not json'), throwsFormatException);
      expect(ExcalidrawScene.fromJson('[]'), isNull);
    });

    test('skips deleted elements', () {
      const json = '''
        {"type":"excalidraw","version":2,"elements":[
          {"type":"rectangle","id":"a","x":0,"y":0,"width":10,"height":10},
          {"type":"rectangle","id":"b","x":20,"y":20,"width":10,"height":10,"isDeleted":true}
        ],"appState":{},"files":{}}
      ''';
      final scene = ExcalidrawScene.fromJson(json);
      expect(scene, isNotNull);
      expect(scene!.elements.length, 1);
      expect(scene.elements.first['id'], 'a');
    });
  });

  group('ExcalidrawWidget', () {
    testWidgets('renders without throwing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: ExcalidrawWidget(jsonString: _sampleScene),
            ),
          ),
        ),
      );
      expect(find.byType(ExcalidrawWidget), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('shows error card on invalid JSON', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ExcalidrawWidget(jsonString: 'not valid json'),
          ),
        ),
      );
      expect(find.textContaining('Excalidraw parse error'), findsOneWidget);
    });

    testWidgets('shows error card for empty scene', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ExcalidrawWidget(
              jsonString: '{"type":"excalidraw","elements":[]}',
            ),
          ),
        ),
      );
      expect(find.textContaining('Empty Excalidraw scene'), findsOneWidget);
    });
  });

  group('excalidrawToSvg', () {
    test('generates a well-formed SVG for a valid scene', () {
      final svg = excalidrawToSvg(_sampleScene);
      expect(svg, isNotNull);
      expect(svg, startsWith('<?xml'));
      expect(svg, contains('<svg '));
      expect(svg, contains('</svg>'));
      // Each major element type should be present.
      expect(svg, contains('<rect '));
      expect(svg, contains('<ellipse '));
      expect(svg, contains('<polygon ')); // diamond
      expect(svg, contains('<polyline ')); // arrow polyline
      expect(svg, contains('<text '));
      expect(svg, contains('Hello'));
    });

    test('returns null for empty / malformed input', () {
      expect(excalidrawToSvg(''), isNull);
      expect(excalidrawToSvg('not json'), isNull);
      expect(
        excalidrawToSvg('{"type":"excalidraw","elements":[]}'),
        isNull,
      );
    });

    test('escapes XML special chars in text content', () {
      const json = '''
        {"type":"excalidraw","version":2,"elements":[
          {"type":"text","id":"t","x":0,"y":0,"width":200,"height":30,
           "text":"A & B <C> \\"D\\"","fontSize":20,"fontFamily":2,
           "textAlign":"left","strokeColor":"#000000"}
        ],"appState":{},"files":{}}
      ''';
      final svg = excalidrawToSvg(json);
      expect(svg, isNotNull);
      expect(svg, contains('A &amp; B &lt;C&gt;'));
      expect(svg, isNot(contains('<C>')));
    });
  });
}
