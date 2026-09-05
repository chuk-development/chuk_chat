import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';

import '../../support/test_app.dart';

/// A phone-sized window (iPhone 14: 390 × 844 logical px) with a 47 px status
/// bar and a 34 px home indicator, so safe areas are real in the tests.
const Size kPhoneSize = Size(390, 844);
const EdgeInsets kPhonePadding = EdgeInsets.only(top: 47, bottom: 34);

/// Finds the `Semantics(identifier: id)` widget the mobile layer wraps each
/// control in. A widget predicate, so no semantics handle is needed.
Finder findId(String id) => find.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.identifier == id,
      description: 'Semantics identifier "$id"',
    );

/// Pumps [child] into a phone-shaped, localised app.
Future<void> pumpPhone(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = kPhoneSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: kPhoneSize,
        padding: kPhonePadding,
        viewPadding: kPhonePadding,
      ),
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // The banner would land in the preview PNGs.
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(body: child),
      ),
    ),
  );
  // The localisation delegates load asynchronously; the first frame is empty.
  await tester.pump();
}

CoworkAgent agent({
  required String id,
  required String name,
  String? role,
  String? brief,
  bool running = false,
  DateTime? lastActivity,
  List<CoworkThreadInfo>? threads,
  bool onHost = false,
}) =>
    CoworkAgent(
      id: id,
      name: name,
      role: role,
      brief: brief,
      running: running,
      onHost: onHost,
      lastActivity: lastActivity,
      threads: threads ??
          <CoworkThreadInfo>[
            CoworkThreadInfo(key: '$id-main', title: 'default'),
          ],
    );

LocalAgentRosterSource rosterWith(List<CoworkAgent> agents) =>
    LocalAgentRosterSource(seed: agents);

/// Loads Roboto and the Material icon font from the Flutter SDK so a golden
/// shows real glyphs instead of Ahem boxes. Test-only; the SDK path is
/// derived from the running `flutter_tester` binary, nothing is hard-coded.
Future<void> loadRealFonts() async {
  final Directory engineDir = File(Platform.resolvedExecutable).parent;
  // …/bin/cache/artifacts/engine/<platform>/flutter_tester
  final Directory fontsDir = Directory(
    '${engineDir.parent.parent.path}/material_fonts',
  );
  if (!fontsDir.existsSync()) return;

  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final String file in files) {
      final File f = File('${fontsDir.path}/$file');
      if (!f.existsSync()) continue;
      final bytes = await f.readAsBytes();
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await load('Roboto', <String>[
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]);
  await load('MaterialIcons', <String>['MaterialIcons-Regular.otf']);
}
