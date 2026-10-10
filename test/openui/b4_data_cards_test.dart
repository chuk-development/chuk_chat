// Widget tests of the B4 components: data display and card blocks
// (lib/openui/components/data_cards.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

import 'openui_test_helper.dart';

/// Pumps [source] at [width] (the chat column) and settles.
Future<RecordingOpenUiHandler> pumpAt(
  WidgetTester tester,
  String source, {
  double width = OpenUiTokens.chatColumnWidth,
  Brightness brightness = Brightness.dark,
  bool isStreaming = false,
}) async {
  final h = RecordingOpenUiHandler();
  await tester.binding.setSurfaceSize(Size(width + 64, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    openUiTestApp(
      OpenUiView(source: source, isStreaming: isStreaming, actionHandler: h),
      brightness: brightness,
      width: width,
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

const String _all = '''
root = Card([tags, tagOne, el, lb, t1, t2, it, imt, imtl, m1, m2, snip, ov, ctx, comp, vis])
tags = TagBlock(["Fast", "Cheap", 3], "sm")
tagOne = Tag("Verified", Icon("circle-check"), "md", "success")
el = EntityList([{left: "Price", right: "12.50", rightVariant: "number"}, {left: "Seats", right: "4"}], "default", {left: "Item", right: "Value"}, {left: "Total", right: "16.50", rightVariant: "number"})
lb = ListBlock([ListItem("First", "Sub one"), ListItem("Second", "Sub two", {src: "https://example.com/a.png", alt: "A"})], "number")
t1 = Text("text", "Plain value", "+4.2%", "metric", "md")
t2 = BoldText("number", "1,204", "-3 today", "metric", "lg")
it = IconText(Icon("map-pin", "navigation"), "info", "m", "Berlin", "Germany", true, "horizontal")
imt = ImageText("https://example.com/p.png", "Portrait", "Ada", "Engineer", false, "horizontal", 40)
imtl = ImageTextLarge("https://example.com/b.png", "Banner", "Big title", "Under it")
m1 = MetricIndicatorInline("48.7M", "tourists", {direction: "up", value: 2.5})
m2 = MetricIndicatorWithStrikethrough("19 EUR", "per month", "29 EUR", {direction: "down", value: 34})
snip = SnippetCardBlock([SnippetCardItem("s1", IconText(Icon("clock"), "neutral", "s", "Opens"), Text("text", "9:00")), SnippetCardItem("s2", IconText(Icon("star"), "warning", "s", "Rating"), BoldText("number", "4.8"))])
ov = OverviewCardBlock([OverviewCardItem("o1", IconText(Icon("users"), "neutral", "m", "Visitors", "2024", false, "vertical"), MetricIndicatorInline("2.1M", "per year", {direction: "up", value: 3})), OverviewCardItem("o2", Text("text", "Revenue"), MetricIndicatorInline("9B"))], "grid", true)
ctx = ContextCardBlock([ContextCardItem("c1", "Art", "143 **museums**", "gray"), ContextCardItem("c2", Tag("Food", Icon("utensils"), "sm", "info"), "9,000+ restaurants")])
comp = CompositeCardBlock([CompositeCardItem("p1", IconText(Icon("plane"), "soft", "m", "Flight", "Direct"), [Text("text", "Leaves 9:40"), TagBlock(["Window", "Meal"]), EntityList([{left: "Bags", right: "1"}])], {price: "199 EUR"})])
vis = VisualCardBlock([VisualCardItem(BoldText("text", "Eiffel Tower", "Open daily"), "v1", "https://example.com/e.jpg", Tag("Must-See", Icon("star"), "sm", "info"), "Tower")], "carousel")
''';

void main() {
  group('render', () {
    for (final brightness in Brightness.values) {
      testWidgets('every component renders ($brightness)', (tester) async {
        await pumpAt(tester, _all, brightness: brightness);
        expect(tester.takeException(), isNull);
        for (final text in <String>[
          'Fast',
          '3',
          'Verified',
          'Price',
          '16.50',
          'First',
          'Sub two',
          'Plain value',
          '+4.2%',
          '1,204',
          'Berlin',
          'Ada',
          'Big title',
          '48.7M',
          '+2.5%',
          '29 EUR',
          '−34%',
          'Opens',
          '9:00',
          'Visitors',
          '2.1M',
          'Art',
          'Food',
          'Flight',
          'Leaves 9:40',
          'Window',
          '199 EUR',
          'Eiffel Tower',
          'Must-See',
        ]) {
          expect(find.textContaining(text), findsWidgets, reason: text);
        }
        // Icons are the app's own set.
        expect(find.byType(HugeIcon), findsWidgets);
      });
    }

    testWidgets('renders at phone and desktop width', (tester) async {
      await pumpAt(tester, _all, width: 328);
      expect(tester.takeException(), isNull);
      await pumpAt(tester, _all, width: 720);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Text("x") with the value in the first slot still shows', (
      tester,
    ) async {
      await pumpAt(tester, 'root = Card([Text("Hello there")])');
      expect(find.text('Hello there'), findsOneWidget);
    });

    testWidgets('small EntityList drops header and footer', (tester) async {
      await pumpAt(
        tester,
        'root = Card([EntityList([{left: "a", right: "b"}], "small", '
        '{left: "H", right: "V"}, {left: "F", right: "T"})])',
      );
      expect(find.text('a'), findsOneWidget);
      expect(find.text('H'), findsNothing);
      expect(find.text('T'), findsNothing);
    });
  });

  group('bad and partial input', () {
    const bad = <String>[
      'root = Card([Tag()])',
      'root = Card([Tag(5, "notAnIcon", "huge", "purple")])',
      'root = Card([TagBlock("one")])',
      'root = Card([TagBlock([{a: 1}, null])])',
      'root = Card([EntityList("x", 3, "y", [1])])',
      'root = Card([EntityList([1, "a", {left: 2}])])',
      'root = Card([ListBlock(5)])',
      'root = Card([ListBlock([ListItem(), "x", 3], "weird", "huge")])',
      'root = Card([Text()])',
      'root = Card([BoldText({a: 1}, [2])])',
      'root = Card([IconText()])',
      'root = Card([IconText("star", "bogus", "giant", "Title")])',
      'root = Card([ImageText("javascript:alert(1)", "", "T")])',
      'root = Card([ImageTextLarge("file:///etc/passwd", "", "T")])',
      'root = Card([MetricIndicatorInline("1", "s", {direction: "sideways", value: 3})])',
      'root = Card([MetricIndicatorWithStrikethrough("1", "", "", {direction: "up", value: "x"})])',
      'root = Card([Icon()])',
      'root = Card([Icon(42, 7)])',
      'root = Card([SnippetCardBlock([1, "x", SnippetCardItem()])])',
      'root = Card([SnippetCardBlock(null, "grid", "yes", 5, "huge")])',
      'root = Card([OverviewCardBlock([OverviewCardItem()], "sideways")])',
      'root = Card([ContextCardBlock([ContextCardItem(1, 2, 3, 4, 5, 6)])])',
      'root = Card([CompositeCardBlock([CompositeCardItem("a", "b", "c", "d")], "carousel")])',
      'root = Card([CompositeCardBlock([CompositeCardItem("a", null, [], {price: 3, button: "x"})])])',
      'root = Card([VisualCardBlock([VisualCardItem()], "grid", false, null, -5)])',
      'root = Card([VisualCardBlock("nope")])',
    ];
    for (final source in bad) {
      testWidgets('does not throw: $source', (tester) async {
        await pumpAt(tester, source);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('every prefix of a streamed program renders', (tester) async {
      // Cut the program at many points, as a stream does.
      for (var end = 10; end < _all.length; end += 97) {
        await pumpAt(tester, _all.substring(0, end), isStreaming: true);
        expect(tester.takeException(), isNull, reason: 'cut at $end');
      }
    });
  });

  group('layout', () {
    const four = '''
root = Card([b])
b = OverviewCardBlock([OverviewCardItem("a", Text("text", "One")), OverviewCardItem("b", Text("text", "Two")), OverviewCardItem("c", Text("text", "Three")), OverviewCardItem("d", Text("text", "Four"))], "grid", true)
''';

    testWidgets('a narrow grid is one column', (tester) async {
      await pumpAt(tester, four, width: 360);
      final one = tester.getTopLeft(find.text('One'));
      final two = tester.getTopLeft(find.text('Two'));
      expect(two.dy, greaterThan(one.dy));
      expect(two.dx, one.dx);
    });

    testWidgets('a wide grid puts cards side by side', (tester) async {
      await pumpAt(tester, four, width: 720);
      final one = tester.getTopLeft(find.text('One'));
      final two = tester.getTopLeft(find.text('Two'));
      expect(two.dy, one.dy);
      expect(two.dx, greaterThan(one.dx));
    });

    testWidgets('responsive false keeps the rows when narrow', (tester) async {
      await pumpAt(tester, four.replaceAll('"grid", true', '"grid", false'));
      final one = tester.getTopLeft(find.text('One'));
      final two = tester.getTopLeft(find.text('Two'));
      expect(two.dy, one.dy);
    });

    testWidgets('cards in one row share the same height', (tester) async {
      const src = '''
root = Card([b])
b = SnippetCardBlock([SnippetCardItem("a", IconText(Icon("star"), "neutral", "s", "Short")), SnippetCardItem("b", IconText(Icon("star"), "neutral", "s", "A much longer title", "With a subtitle that wraps over more than one line here"))])
''';
      await pumpAt(tester, src, width: 720);
      final cards = find.byType(DecoratedBox).evaluate().where((e) {
        final w = e.widget as DecoratedBox;
        final d = w.decoration;
        return d is BoxDecoration && d.border != null && d.color != null;
      }).toList();
      expect(cards.length, greaterThanOrEqualTo(2));
      final h0 = (cards[0].renderObject! as RenderBox).size.height;
      final h1 = (cards[1].renderObject! as RenderBox).size.height;
      expect(h0, h1);
    });

    testWidgets('a carousel scrolls sideways', (tester) async {
      await pumpAt(
        tester,
        four.replaceAll('"grid", true', '"carousel", true'),
        width: 360,
      );
      final one = tester.getTopLeft(find.text('One'));
      final two = tester.getTopLeft(find.text('Two'));
      expect(two.dy, one.dy);
      expect(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.text('Four'),
        ),
        findsOneWidget,
      );
    });
  });

  group('actions', () {
    testWidgets('a context card sends its title and the item context', (
      tester,
    ) async {
      final h = await pumpAt(tester, '''
root = Card([b])
b = ContextCardBlock([ContextCardItem("c1", "Art", "Museums"), ContextCardItem("c2", "Food", "Restaurants")], "grid", true, {type: "continue_conversation", context: "Tell me more"})
''');
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();
      expect(h.messages, hasLength(1));
      expect(h.messages.single.text, 'Food');
      final ctx = h.messages.single.context!;
      expect(ctx, contains('Tell me more'));
      expect(ctx, contains('Selected item:'));
      expect(ctx, contains('"itemIndex":1'));
      expect(ctx, contains('"itemId":"c2"'));
      expect(ctx, contains('"itemBody":"Restaurants"'));
    });

    testWidgets('a snippet card reads the title its child wrote', (
      tester,
    ) async {
      final h = await pumpAt(tester, '''
root = Card([b])
b = SnippetCardBlock([SnippetCardItem("s1", IconText(Icon("clock"), "neutral", "s", "Opens", "Mon-Fri"), Text("text", "9:00"))], "grid", true, Action([@ToAssistant("Show hours")]))
''');
      await tester.tap(find.text('Opens'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'Show hours');
      final ctx = h.messages.single.context!;
      expect(ctx, contains('"itemTitle":"Opens"'));
      expect(ctx, contains('"itemSubtitle":"Mon-Fri"'));
      expect(ctx, contains('"itemValue":"9:00"'));
    });

    testWidgets('overview, composite and visual cards fire their action', (
      tester,
    ) async {
      final h = await pumpAt(tester, '''
root = Card([o, c, v])
o = OverviewCardBlock([OverviewCardItem("o1", Text("text", "Visitors"), MetricIndicatorInline("2M"))], "grid", true, {type: "continue_conversation"})
c = CompositeCardBlock([CompositeCardItem("p1", IconText(Icon("plane"), "soft", "m", "Flight"), [Text("text", "Direct")])], "grid", true, {type: "continue_conversation"})
v = VisualCardBlock([VisualCardItem(BoldText("text", "Louvre"), "v1", "", Tag("Museum"))], "grid", true, {type: "continue_conversation"})
''');
      await tester.tap(find.text('Visitors'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Louvre'));
      await tester.pumpAndSettle();
      expect(h.messages.map((m) => m.text).toList(), <String>[
        'Visitors',
        'Flight',
        'Louvre',
      ]);
      expect(h.messages[0].context, contains('"itemMetricValue":"2M"'));
      expect(h.messages[2].context, contains('"itemTag":"Museum"'));
    });

    testWidgets('an open_url action opens the URL', (tester) async {
      final h = await pumpAt(tester, '''
root = Card([b])
b = ContextCardBlock([ContextCardItem("c1", "Docs")], "grid", true, {type: "open_url", url: "https://example.com/docs"})
''');
      await tester.tap(find.text('Docs'));
      await tester.pumpAndSettle();
      expect(h.urls, <String>['https://example.com/docs']);
    });

    testWidgets('cards without an action are not clickable', (tester) async {
      final h = await pumpAt(tester, '''
root = Card([b])
b = ContextCardBlock([ContextCardItem("c1", "Art", "Museums")])
''');
      await tester.tap(find.text('Art'));
      await tester.pumpAndSettle();
      expect(h.messages, isEmpty);
    });

    testWidgets('a list item with an action sends its title', (tester) async {
      final h = await pumpAt(tester, '''
root = Card([ListBlock([ListItem("Plain"), ListItem("Clickable", "Sub", null, "Open", Action([@ToAssistant("Open it")]))])])
''');
      expect(find.text('Open'), findsOneWidget);
      await tester.tap(find.text('Plain'));
      await tester.pumpAndSettle();
      expect(h.messages, isEmpty);
      await tester.tap(find.text('Clickable'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'Open it');
    });

    testWidgets('a card block does not take taps while it streams', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        '''
root = Card([b])
b = ContextCardBlock([ContextCardItem("c1", "Art", "Museums")], "grid", true, {type: "continue_conversation"}''',
        isStreaming: true,
      );
      if (find.text('Art').evaluate().isNotEmpty) {
        await tester.tap(find.text('Art'), warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      expect(h.messages, isEmpty);
    });
  });
}
