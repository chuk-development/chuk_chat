// Probe: renders the current row states and a page header to PNG.
// UI_LIB_PNG=1 writes into _scratch/ui_lib/<UI_LIB_TAG>/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';
import 'package:chuk_chat/widgets/settings_surface.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

import '../platform_specific/mobile/mobile_support.dart';
import '../support/test_app.dart';

final bool _write = Platform.environment['UI_LIB_PNG'] == '1';
final String _tag = Platform.environment['UI_LIB_TAG'] ?? 'probe';

ThemeData _theme(Brightness b) => b == Brightness.dark
    ? buildAppTheme(
        accent: kDefaultAccentColor,
        iconFg: kDefaultIconFgColor,
        bg: kDefaultBgColor,
        brightness: Brightness.dark,
        palette: kPlaneDarkPalette,
      )
    : buildAppTheme(
        accent: const Color(0xFF45484A),
        iconFg: const Color(0xFF0F0F10),
        bg: const Color(0xFFFFFFFF),
        brightness: Brightness.light,
      );

Future<void> _png(WidgetTester tester, String name) async {
  if (!_write) return;
  final RenderRepaintBoundary rb = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey<String>('shot')),
  );
  await tester.runAsync(() async {
    final ui.Image image = await rb.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final File out = File('_scratch/ui_lib/$_tag/$name.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Widget _app(Brightness b, Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: _theme(b),
  localizationsDelegates: kTestLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: RepaintBoundary(key: const ValueKey<String>('shot'), child: home),
);

/// Rest (item 2 selected in the build), mouse hover on item 1, mouse press
/// on item 3 (hover + press, as on a desktop), touch press on item 4. Each
/// state starts from a fresh pump, so one gesture cannot leak into the next.
Future<void> _states(
  WidgetTester tester,
  String name,
  String key,
  Future<void> Function() pump,
) async {
  Finder item(int i) => find.byKey(ValueKey<String>('$key$i'));
  await pump();
  await _png(tester, '${name}_0rest');

  await pump();
  final TestGesture hover = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await hover.addPointer(location: tester.getCenter(item(1)));
  await tester.pump();
  await hover.moveBy(const Offset(2, 0));
  await tester.pump(const Duration(milliseconds: 400));
  await _png(tester, '${name}_1hover');
  await hover.removePointer();

  await pump();
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer(location: tester.getCenter(item(3)));
  await tester.pump();
  await mouse.moveBy(const Offset(2, 0));
  await tester.pump(const Duration(milliseconds: 200));
  await mouse.down(tester.getCenter(item(3)));
  await tester.pump(const Duration(milliseconds: 400));
  await _png(tester, '${name}_2mousepress');
  await mouse.up();
  await mouse.removePointer();

  await pump();
  final TestGesture touch = await tester.startGesture(
    tester.getCenter(item(4)),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await _png(tester, '${name}_3touchpress');
  await touch.up();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);

  for (final Brightness b in Brightness.values) {
    testWidgets('real desktop sidebar ${b.name}', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final DateTime now = DateTime.now();
      final DateTime midnight = DateTime(now.year, now.month, now.day);
      ChatStorageState.chatsById.clear();
      addTearDown(ChatStorageState.chatsById.clear);
      for (int i = 0; i < 6; i++) {
        ChatStorageState.chatsById['c$i'] = StoredChat.forSidebar(
          id: 'c$i',
          createdAt: midnight.add(Duration(minutes: 60 - i)),
          updatedAt: midnight.add(Duration(minutes: 60 - i)),
          isStarred: false,
          title: 'Chat number $i',
        );
      }
      Future<void> pump() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _app(
            b,
            Scaffold(
              body: SidebarDesktop(
                onChatSelected: (_) {},
                onSettingsTapped: () {},
                onWorkspacesTapped: () {},
                onMediaTapped: () {},
                onNewChatTapped: () {},
                selectedChatId: 'c2',
                isCompactMode: false,
                showWorkspacesButton: false,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        // Name each chat card the way _states looks for it.
      }

      await pump();
      Finder card(int i) => find.ancestor(
        of: find.text('Chat number $i'),
        matching: find.byType(SbCard),
      );
      await _png(tester, 'realsidebar_${b.name}_0rest');
      final TestGesture hover = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await hover.addPointer(location: tester.getCenter(card(1)));
      await tester.pump();
      await hover.moveBy(const Offset(2, 0));
      await tester.pump(const Duration(milliseconds: 400));
      await _png(tester, 'realsidebar_${b.name}_1hover');
      await hover.moveTo(tester.getCenter(card(3)));
      await tester.pump(const Duration(milliseconds: 300));
      await hover.down(tester.getCenter(card(3)));
      await tester.pump(const Duration(milliseconds: 400));
      await _png(tester, 'realsidebar_${b.name}_2mousepress');
      await hover.up();
      await hover.moveTo(tester.getCenter(card(2)));
      await tester.pump(const Duration(milliseconds: 300));
      await hover.down(tester.getCenter(card(2)));
      await tester.pump(const Duration(milliseconds: 400));
      await _png(tester, 'realsidebar_${b.name}_3selectedpress');
      await hover.up();
      await hover.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('sidebar rows ${b.name}', (tester) async {
      tester.view.physicalSize = const Size(340, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const int n = 6;
      Future<void> pump() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _app(
            b,
            Scaffold(
              body: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: <Widget>[
                    for (int i = 0; i < n; i++)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 3, 8, 0),
                        child: SbCardShape(
                          radius: sbBlockRadiusFor(index: i + 1, length: n + 1),
                          child: SbChatTile(
                            key: ValueKey<String>('tile$i'),
                            title: 'Chat number $i',
                            dateLine: 'Nov 20',
                            selected: i == 2,
                            onTap: () {},
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await _states(tester, 'sidebar_${b.name}', 'tile', pump);
    });

    testWidgets('settings rows ${b.name}', (tester) async {
      tester.view.physicalSize = const Size(412, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> pump() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _app(
            b,
            Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ExpressiveGroup(
                  children: <Widget>[
                    for (int i = 0; i < 5; i++)
                      ExpressiveRow(
                        key: ValueKey<String>('row$i'),
                        icon: Icons.tune,
                        title: 'Row $i',
                        subtitle: 'Subtitle',
                        onTap: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await _states(tester, 'settings_rows_${b.name}', 'row', pump);
    });

    for (final bool desktop in <bool>[true, false]) {
      testWidgets('header ${desktop ? 'desktop' : 'mobile'} ${b.name}', (
        tester,
      ) async {
        final Size size = desktop
            ? const Size(1440, 900)
            : const Size(412, 915);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final ScrollController controller = ScrollController();
        Widget page(BuildContext _) => FloatingPageScaffold(
          appBar: const FloatingAppBar(title: Text('Model')),
          body: SettingsListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: <Widget>[
              ExpressiveGroup(
                children: <Widget>[
                  for (int i = 0; i < 14; i++)
                    ExpressiveRow(
                      icon: Icons.schedule_outlined,
                      title: 'DeepSeek V4.1 Flash 1017 row $i',
                      subtitle: 'via Fireworks',
                      onTap: () {},
                    ),
                ],
              ),
            ],
          ),
        );
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: desktop
                  ? EdgeInsets.zero
                  : const EdgeInsets.only(top: 24),
              viewPadding: desktop
                  ? EdgeInsets.zero
                  : const EdgeInsets.only(top: 24),
            ),
            child: _app(
              b,
              desktop
                  ? Scaffold(
                      body: SettingsModalFrame(
                        builder: (context, panel) => SettingsSurfaceNavigator(
                          builder: page,
                          onClose: () {},
                        ),
                      ),
                    )
                  : Builder(builder: page),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final String n = '${desktop ? 'desktop' : 'mobile'}_${b.name}';
        await _png(tester, 'header_${n}_top');
        for (final double off in <double>[22, 48]) {
          controller.jumpTo(off);
          await tester.pump();
          await _png(tester, 'header_${n}_scroll${off.toInt()}');
        }
      });
    }
  }
}
