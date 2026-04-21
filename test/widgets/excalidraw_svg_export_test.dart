import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/excalidraw_svg_export.dart';

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
     "strokeWidth":2}
  ],
  "appState":{"viewBackgroundColor":"#ffffff"},
  "files":{}
}
''';

void main() {
  group('excalidrawToSvg', () {
    test('generates a well-formed SVG for a valid scene', () {
      final svg = excalidrawToSvg(_sampleScene);
      expect(svg, isNotNull);
      expect(svg, contains('<svg'));
      expect(svg, contains('</svg>'));
      expect(svg, contains('Hello'));
    });

    test('returns null for empty / malformed input', () {
      expect(excalidrawToSvg(''), isNull);
      expect(excalidrawToSvg('   '), isNull);
      expect(excalidrawToSvg('not json'), isNull);
      expect(excalidrawToSvg('[]'), isNull);
    });

    test('escapes XML special chars in text content', () {
      const hostile = '''
{"type":"excalidraw","elements":[
  {"type":"text","id":"t1","x":0,"y":0,"width":200,"height":24,
   "text":"<script>alert('x')</script> & more","fontSize":16,"fontFamily":1,
   "strokeColor":"#1e1e1e"}
],"appState":{},"files":{}}
''';
      final svg = excalidrawToSvg(hostile);
      expect(svg, isNotNull);
      expect(svg, isNot(contains('<script>')));
      expect(svg, contains('&lt;script&gt;'));
      expect(svg, contains('&amp;'));
    });
  });
}
