// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the REAL app widgets (Clawed dark theme) to PNG, as the reference half of the
// fidelity sheets for episode 10. Not part of the app's test suite.
// Run from the repo root:
//   flutter test marketing/videos/chuk-10-private-images/_work/fidelity_test/real_widgets_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/pages/desktop_media_modal.dart';
import 'package:chuk_chat/pages/media_manager_page.dart' show kMediaFilterBarHeight;
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

const String work = 'marketing/videos/chuk-10-private-images/_work';
const String jpg = '$work/gen/bruno.jpg';
const String prompt = 'a watercolour of our dog Bruno on the beach';
const String answer = "Here's Bruno on the beach, in watercolour.";
const double ratio = 2.0;

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
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: 'Ubuntu'),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Ubuntu'),
  );
}

Future<void> _shoot(WidgetTester tester, Widget child, Size size, String name,
    {int pumps = 4}) async {
  final key = GlobalKey();
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: DefaultTextStyle(
      style: const TextStyle(fontFamily: 'Ubuntu'),
      child: Scaffold(body: RepaintBoundary(key: key, child: child)),
    ),
  ));
  for (var i = 0; i < pumps; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: ratio);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  File('$work/fidelity/real-$name.png').writeAsBytesSync(png!);
}

Widget _aiColumn(Widget bubble) => Container(
      color: const Color(0xFF262624),
      padding: const EdgeInsets.all(20),
      alignment: Alignment.topLeft,
      child: SizedBox(width: 620, child: bubble),
    );

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _font('Ubuntu', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    await _font('JetBrains Mono', ['assets/fonts/JetBrainsMono-wght.ttf']);
    final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
    await _font('MaterialIcons', ['$sdk/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    Directory('$work/fidelity').createSync(recursive: true);
    AppThemeService.instance.setChatFontFamily(kChatFontFamilyJetBrainsMono);
    AppThemeService.instance.setChatFontSize(16.4);
  });

  // The image block while generate_image runs: the activity row and the loader tile.
  testWidgets('image block, generating', (tester) async {
    final call = ToolCall(
      id: 'g1',
      name: 'generate_image',
      arguments: const {'prompt': prompt, 'image_size': 'landscape_4_3'},
      status: ToolCallStatus.running,
    );
    await _shoot(
      tester,
      _aiColumn(MessageBubble(
        message: '',
        isUser: false,
        maxWidth: 620,
        isStreamingMessage: true,
        toolCalls: [call],
        contentBlocks: [ContentBlock.toolCalls([call])],
        turnStartedAt: DateTime.now().subtract(const Duration(seconds: 4)),
      )),
      const Size(660, 640),
      'generating',
      pumps: 2,
    );
  });

  // The finished turn: activity row, the image at its own ratio with the model pill, text.
  testWidgets('image block, done', (tester) async {
    final url = 'data:image/jpeg;base64,${base64Encode(File(jpg).readAsBytesSync())}';
    final call = ToolCall(
      id: 'g1',
      name: 'generate_image',
      arguments: const {'prompt': prompt, 'image_size': 'landscape_4_3'},
      result: 'IMAGE:{"url":"images/u/x.enc","model":"Krea 2 Large"}',
      status: ToolCallStatus.completed,
    );
    await _shoot(
      tester,
      _aiColumn(MessageBubble(
        message: answer,
        isUser: false,
        maxWidth: 620,
        toolCalls: [call],
        contentBlocks: [ContentBlock.toolCalls([call]), const ContentBlock.text(answer)],
        workedFor: const Duration(seconds: 9),
        images: [url],
        imageMetas: const [ImageMeta(source: 'generated', model: 'Krea 2 Large')],
      )),
      const Size(660, 860),
      'done',
    );
  });

  // The real desktop media modal (header, toolbar). Without a signed-in user the
  // library itself cannot load here; its loaded grid is the next test.
  testWidgets('media modal chrome', (tester) async {
    await _shoot(
      tester,
      const SizedBox(width: 1000, height: 640, child: DesktopMediaModal()),
      const Size(1000, 640),
      'modal',
      pumps: 3,
    );
  });

  // The loaded library: media_manager_page.dart _buildToolbar (no selection),
  // _MediaFilterBar, _buildDesktopGrid and _ImageTile (hovered: overlay, actions,
  // date · size line) copied verbatim, since the page's state classes are private.
  testWidgets('media library grid', (tester) async {
    final bytes = File(jpg).readAsBytesSync();
    final others = [
      for (final n in ['other1', 'other2', 'other3', 'other4'])
        File('$work/gen/$n.jpg').readAsBytesSync(),
    ];
    await _shoot(
      tester,
      Builder(builder: (context) {
        final theme = Theme.of(context);
        return Container(
          color: theme.scaffoldBackgroundColor,
          width: 1000,
          height: 460,
          child: Column(children: [
            const _Toolbar(count: 5),
            Expanded(
              child: Stack(children: [
                Positioned.fill(
                  child: GridView(
                    padding: const EdgeInsets.fromLTRB(20, kMediaFilterBarHeight + 8, 20, 20),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 1,
                    ),
                    children: [
                      _Tile(bytes: bytes, hovered: true, dateLine: '26/10/2026', sizeLine: '182.5 KB'),
                      for (final o in others) _Tile(bytes: o),
                    ],
                  ),
                ),
                const Positioned(top: 0, left: 12, right: 12, child: _FilterBar(imageCount: 5)),
              ]),
            ),
          ]),
        );
      }),
      const Size(1000, 460),
      'grid',
    );
  });
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final m3 = theme.m3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
      child: SizedBox(
        height: kFloatingAppBarTarget,
        child: Row(children: [
          Text('$count image${count == 1 ? '' : 's'}',
              style: theme.textTheme.bodyMedium?.copyWith(color: m3.onSurfaceVariant)),
          const Spacer(),
          FloatingHeaderButton(icon: Icons.refresh_rounded, onPressed: () {}, tooltip: 'Refresh'),
        ]),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.imageCount});
  final int imageCount;
  @override
  Widget build(BuildContext context) {
    return FloatingChromeSurface(
      radius: 999,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: kMediaFilterBarHeight - 8,
        child: Row(children: [
          Expanded(child: _segment(context, true, 'Images', imageCount)),
          Expanded(child: _segment(context, false, 'Artifacts', 0)),
        ]),
      ),
    );
  }

  Widget _segment(BuildContext context, bool selected, String label, int count) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? theme.colorScheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count == 0 ? label : '$label  $count',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: selected ? theme.colorScheme.onPrimary : m3.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.bytes, this.hovered = false, this.dateLine, this.sizeLine});
  final Uint8List bytes;
  final bool hovered;
  final String? dateLine;
  final String? sizeLine;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final m3 = theme.m3;
    const double radius = 18;
    final bool showChrome = hovered;
    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 420, filterQuality: FilterQuality.medium),
        if (hovered)
          IgnorePointer(
            child: DecoratedBox(decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.12))),
          ),
        if (showChrome)
          Positioned(
            top: 6,
            right: 6,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const _TileAction(icon: Icons.download_rounded),
              const SizedBox(width: 6),
              _TileAction(icon: Icons.delete_outline_rounded, tone: theme.colorScheme.error),
            ]),
          ),
        if (showChrome && (dateLine != null || sizeLine != null))
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withValues(alpha: 0.66), Colors.transparent],
                ),
              ),
              child: Text(
                [if (dateLine != null) dateLine!, if (sizeLine != null) sizeLine!].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ),
      ]),
    );
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({required this.icon, this.tone});
  final IconData icon;
  final Color? tone;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(width: 30, height: 30, child: AppIcon(icon, size: 17, color: tone ?? Colors.white)),
    );
  }
}
