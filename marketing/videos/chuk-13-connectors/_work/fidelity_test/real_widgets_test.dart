// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the REAL Connectors page and the REAL connector detail page (Clawed dark
// theme) to PNG, as the reference half of the fidelity sheets for episode 13.
// Not part of the app's test suite. No network: every HTTP client is a mock, the
// store is in memory, Supabase is not initialised (the mirror is a no-op).
// Run from the repo root:
//   flutter test marketing/videos/chuk-13-connectors/_work/fidelity_test/real_widgets_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_icon_cache.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';

const String work = 'marketing/videos/chuk-13-connectors/_work';
const double ratio = 2.0;

/// The tools Notion's hosted MCP server lists (the names in the video).
const List<String> notionTools = [
  'notion-search', 'notion-fetch', 'notion-create-pages', 'notion-update-page',
  'notion-move-pages', 'notion-duplicate-page', 'notion-create-database',
  'notion-update-database', 'notion-create-comment', 'notion-get-comments',
  'notion-get-teams', 'notion-get-users', 'notion-get-user', 'notion-get-self',
];

class _MemorySecrets implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
  @override
  Future<void> delete(String key) async => map.remove(key);
}

McpListBackend _memoryList() {
  final map = <String, String>{};
  return McpListBackend(read: (k) async => map[k], write: (k, v) async => map[k] = v);
}

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

ThemeData _theme() {
  final t = buildAppTheme(
    accent: const Color(0xFFD97757),
    iconFg: const Color(0xFFE8E4D8),
    bg: const Color(0xFF262624),
    brightness: Brightness.dark,
    contrast: 0.55,
  );
  // The app leaves ThemeData.fontFamily unset ("system"), so on the Linux desktop
  // every style without a family draws in the system UI font, Ubuntu. A test has
  // no system font: put Ubuntu on each style the theme builds without a family.
  const u = TextStyle(fontFamily: 'Ubuntu');
  ButtonStyle? b(ButtonStyle? s) => s?.copyWith(
    textStyle: WidgetStatePropertyAll((s.textStyle?.resolve(<WidgetState>{}) ?? const TextStyle()).merge(u)),
  );
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: 'Ubuntu'),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Ubuntu'),
    appBarTheme: t.appBarTheme.copyWith(titleTextStyle: (t.appBarTheme.titleTextStyle ?? const TextStyle()).merge(u)),
    chipTheme: t.chipTheme.copyWith(labelStyle: (t.chipTheme.labelStyle ?? const TextStyle()).merge(u)),
    filledButtonTheme: FilledButtonThemeData(style: b(t.filledButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: b(t.textButtonTheme.style)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: b(t.elevatedButtonTheme.style)),
  );
}

McpCatalogueEntry get _notion => kMcpCatalogue.firstWhere((e) => e.id == 'notion');

McpConnection get _notionConnection => McpConnection(
  id: 'notion',
  name: 'Notion',
  url: _notion.url,
  description: _notion.description,
  tools: [for (final n in notionTools) McpTool(name: n)],
);

Future<void> _shoot(WidgetTester tester, Widget page, Size size, String name, {bool pushed = false}) async {
  final key = GlobalKey();
  final nav = GlobalKey<NavigatorState>();
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  await tester.pumpWidget(RepaintBoundary(
    key: key,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorKey: nav,
      home: pushed ? const Scaffold() : page,
    ),
  ));
  if (pushed) {
    // The localizations load first; the navigator exists after that.
    for (var i = 0; i < 4 && nav.currentState == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    // Pushed like the app pushes it, so the floating header shows its back chip.
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => page)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  McpService.unreachable.value = <String>{};
  await tester.pump(const Duration(milliseconds: 100));
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: ratio);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  File('$work/fidelity/real-$name.png').writeAsBytesSync(png!);
  // Layout of every text on screen, in app px, for the HTML rebuild.
  final texts = <Map<String, Object?>>[];
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject! as RenderParagraph;
    if (!ro.attached || !ro.hasSize) continue;
    final o = ro.localToGlobal(Offset.zero);
    if (o.dy > size.height || o.dy + ro.size.height < 0) continue;
    final st = ro.text.style;
    texts.add({
      'text': ro.text.toPlainText(),
      'x': o.dx, 'y': o.dy, 'w': ro.size.width, 'h': ro.size.height,
      'size': st?.fontSize, 'weight': st?.fontWeight?.value, 'ls': st?.letterSpacing,
      'height': st?.height, 'family': st?.fontFamily,
      'color': st?.color == null ? null : '#${st!.color!.toARGB32().toRadixString(16)}',
    });
  }
  File('$work/fidelity/real-$name.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(texts));
}

void main() {
  setUpAll(() async {
    await _font('Ubuntu', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    // Explicit TextStyles without a family fall back to the default (Roboto): on the
    // Linux desktop that is the system UI font, Ubuntu.
    await _font('Roboto', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    await _font('FlutterTest', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    await _font('JetBrains Mono', ['assets/fonts/JetBrainsMono-wght.ttf']);
    final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
    await _font('MaterialIcons', ['$sdk/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppThemeService.instance.setChatFontSize(16.4);
    McpIconCache.httpClient = MockClient((_) async => http.Response('', 404));
    McpService.resetForTest(store: McpStore(secrets: _MemorySecrets(), list: _memoryList()));
    McpService.probeClientFactory = () => MockClient((_) async => http.Response('', 401));
    McpService.unreachable.value = <String>{};
  });

  for (final w in [600.0, 376.0]) {
    final tag = w.toInt();
    testWidgets('connectors list $tag', (tester) async {
      await _shoot(tester, const McpConnectorsPage(), Size(w, 900), 'list-$tag');
    });

    testWidgets('connectors list, Notion connected $tag', (tester) async {
      await McpService.store.upsert(_notionConnection, accessToken: 'x');
      await _shoot(tester, const McpConnectorsPage(), Size(w, 900), 'list-connected-$tag');
    });

    testWidgets('Notion detail $tag', (tester) async {
      await _shoot(tester, McpConnectorDetailPage(id: 'notion', entry: _notion), Size(w, 760), 'detail-$tag', pushed: true);
    });

    testWidgets('Notion detail connected $tag', (tester) async {
      await McpService.store.upsert(_notionConnection, accessToken: 'x');
      await McpService.load();
      await _shoot(tester, McpConnectorDetailPage(id: 'notion', entry: _notion), Size(w, 760), 'detail-connected-$tag', pushed: true);
    });
  }
}
