import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/map_block_renderer.dart';

Widget _host(String json) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: MapBlockWidget(jsonString: json)),
  ),
);

void main() {
  testWidgets('features map lists every feature and opens its details', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host('''
{"title":"Sperrungen Preetz","features":[
 {"kind":"closure","line":[[54.2417,10.2894],[54.2430,10.2900]],"label":"Wakendorfer Straße","dates":"26.10. – 30.10.","detour":"über Kührener Straße"},
 {"kind":"detour","line":"54.24,10.28; 54.25,10.29","label":"Umleitung"},
 {"kind":"info","lat":54.23,"lon":10.28,"label":"Rathaus"}
]}'''),
    );
    await tester.pump();

    expect(find.text('Sperrungen Preetz'), findsOneWidget);
    expect(find.text('Wakendorfer Straße'), findsOneWidget);
    expect(find.text('Umleitung'), findsWidgets);
    expect(find.text('Rathaus'), findsOneWidget);

    await tester.tap(find.text('Wakendorfer Straße'));
    await tester.pumpAndSettle();
    expect(find.textContaining('über Kührener Straße'), findsOneWidget);
    expect(find.text('26.10. – 30.10.'), findsWidgets);
  });

  testWidgets('a block with no usable geometry renders nothing, no error', (
    tester,
  ) async {
    await tester.pumpWidget(_host('{"features":[{"label":"x"}, 5]}'));
    await tester.pump();
    expect(find.textContaining('Map parse error'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
