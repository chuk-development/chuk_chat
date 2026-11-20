// The shared UI library: one shape for every state of a list item, and one
// page header on the frosted material (docs/DESIGN.md §2.2).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/ui/components/components.dart';
import 'package:chuk_chat/ui/expressive/top_veil.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

ShapeBorder? _shapeOf(WidgetTester tester, Finder item) => tester
    .widget<Material>(
      find.descendant(of: item, matching: find.byType(Material)).first,
    )
    .shape;

void main() {
  group('listItemRadius', () {
    test('outer corners round, joints stay tight', () {
      final BorderRadius first = listItemRadius(index: 0, length: 3);
      final BorderRadius middle = listItemRadius(index: 1, length: 3);
      final BorderRadius last = listItemRadius(index: 2, length: 3);
      expect(first.topLeft, const Radius.circular(kListItemRadius));
      expect(first.bottomLeft, const Radius.circular(kListItemJointRadius));
      expect(middle, BorderRadius.circular(kListItemJointRadius));
      expect(last.bottomRight, const Radius.circular(kListItemRadius));
      expect(
        listItemRadius(index: 0, length: 1),
        BorderRadius.circular(kListItemRadius),
      );
      expect(
        listItemRadius(index: 0, length: 2, joinTop: true).topLeft,
        const Radius.circular(kListItemJointRadius),
      );
    });
  });

  group('StateSurface', () {
    const BorderRadius shape = BorderRadius.all(Radius.circular(6));

    Future<void> pump(WidgetTester tester, {bool selected = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: StateSurface(
                    key: const ValueKey<String>('item'),
                    borderRadius: shape,
                    color: Colors.grey,
                    selected: selected,
                    selectedColor: Colors.blue,
                    squeeze: true,
                    onTap: () {},
                    padding: const EdgeInsets.all(12),
                    child: const Text('Row'),
                  ),
                ),
              ),
            ),
          ),
        );

    final Finder item = find.byKey(const ValueKey<String>('item'));

    testWidgets('the ink and the fill share the one shape', (tester) async {
      await pump(tester);
      final InkWell ink = tester.widget<InkWell>(
        find.descendant(of: item, matching: find.byType(InkWell)),
      );
      expect(
        ink.customBorder,
        const RoundedRectangleBorder(borderRadius: shape),
      );
      expect(
        _shapeOf(tester, item),
        const RoundedRectangleBorder(borderRadius: shape),
      );
    });

    testWidgets('hover, press and selection keep the shape', (tester) async {
      await pump(tester);
      final ShapeBorder? rest = _shapeOf(tester, item);

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: tester.getCenter(item));
      await tester.pump();
      await mouse.moveBy(const Offset(1, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_shapeOf(tester, item), rest);

      await mouse.down(tester.getCenter(item));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_shapeOf(tester, item), rest);
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();

      await pump(tester, selected: true);
      expect(_shapeOf(tester, item), rest);
      expect(
        tester
            .widget<Material>(
              find.descendant(of: item, matching: find.byType(Material)).first,
            )
            .color,
        Colors.blue,
      );
    });
  });

  testWidgets('a pressed settings tile keeps its place in the group', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExpressiveGroup(
            children: <Widget>[
              ExpressiveRow(title: 'a', onTap: () {}),
              ExpressiveRow(
                key: const ValueKey<String>('mid'),
                title: 'b',
                onTap: () {},
              ),
              ExpressiveRow(title: 'c', onTap: () {}),
            ],
          ),
        ),
      ),
    );
    final Finder mid = find.byKey(const ValueKey<String>('mid'));
    const ShapeBorder joint = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(kExpressiveInnerRadius)),
    );
    expect(_shapeOf(tester, mid), joint);
    final TestGesture press = await tester.startGesture(tester.getCenter(mid));
    await tester.pump(const Duration(milliseconds: 300));
    // The old tile rounded every corner on a press.
    expect(_shapeOf(tester, mid), joint);
    await press.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a selected menu row is a pill of the same shape as its ink', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuTileGroup.single(
            color: Colors.white,
            children: <Widget>[
              MenuActionRow(
                key: const ValueKey<String>('row'),
                label: 'Chosen',
                selected: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    final Finder row = find.byKey(const ValueKey<String>('row'));
    final InkWell ink = tester.widget<InkWell>(
      find.descendant(of: row, matching: find.byType(InkWell)),
    );
    expect(ink.customBorder, _shapeOf(tester, find.byType(StateSurface)));
  });

  group('page header', () {
    testWidgets('every header stands on the frosted material, title in the '
        'app font', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Inter'),
          home: const FloatingPageScaffold(
            appBar: FloatingAppBar(title: Text('Model')),
            body: SizedBox.expand(),
          ),
        ),
      );
      expect(find.byType(PageHeaderBackdrop), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
      final Text title = tester.widget<Text>(find.text('Model'));
      expect(title.style?.fontFamily, 'Inter');
      expect(title.style?.fontSize, 15);
      expect(title.style?.fontWeight, FontWeight.w800);
    });

    testWidgets('a viewer frame draws the same header', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ExpressiveScreen(
                    title: 'Doc.md',
                    builder: (_) => const SizedBox.expand(),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingAppBar), findsOneWidget);
      expect(find.byType(PageHeaderBackdrop), findsOneWidget);
      expect(find.byType(FloatingHeaderButton), findsOneWidget);
      expect(find.text('Doc.md'), findsOneWidget);
    });

    testWidgets('the top veil stands on the same material', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TopVeil(child: SizedBox(height: 40))),
        ),
      );
      expect(find.byType(PageHeaderBackdrop), findsOneWidget);
    });
  });
}
