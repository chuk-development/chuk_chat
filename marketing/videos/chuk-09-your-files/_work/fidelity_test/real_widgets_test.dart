// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the REAL app widgets (Clawed dark theme) to PNG, as the reference half of the
// fidelity sheets for episode 09. Not part of the app's test suite.
// Run from the repo root:
//   flutter test marketing/videos/chuk-09-your-files/_work/fidelity_test/real_widgets_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

const String work = 'marketing/videos/chuk-09-your-files/_work';
const String jpg = '$work/gen/lab-report.jpg';
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

Future<void> _shoot(WidgetTester tester, Widget child, Size size, String name) async {
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
  for (var i = 0; i < 4; i++) {
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

void main() {
  setUpAll(() async {
    Directory('$work/fidelity').createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _font('Ubuntu', ['$work/../assets/fonts/Ubuntu-wght.ttf']);
    await _font('JetBrains Mono', ['assets/fonts/JetBrainsMono-wght.ttf']);
    // Material glyphs that AppIcon falls back to (cloud_upload has no HugeIcon)
    final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
    await _font('MaterialIcons', ['$sdk/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('attachment card in the composer', (tester) async {
    final file = AttachedFile(
      id: 'a1',
      fileName: 'IMG_2041.jpg',
      localPath: jpg,
      fileSizeBytes: File(jpg).lengthSync(),
      isImage: true,
    );
    await _shoot(
      tester,
      Container(
        color: const Color(0xFF262624),
        padding: const EdgeInsets.all(20),
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14, left: 2, right: 52),
            child: AttachmentPreviewBar(files: [file], onRemove: (_) {}),
          ),
        ),
      ),
      const Size(340, 140),
      'attachment',
    );
  });

  testWidgets('user message with an image', (tester) async {
    AppThemeService.instance.setChatFontFamily(kChatFontFamilyJetBrainsMono);
    AppThemeService.instance.setChatFontSize(16.4);
    final url = 'data:image/jpeg;base64,${base64Encode(File(jpg).readAsBytesSync())}';
    await _shoot(
      tester,
      Container(
        color: const Color(0xFF262624),
        padding: const EdgeInsets.all(20),
        alignment: Alignment.topRight,
        child: SizedBox(
          width: 728,
          child: MessageBubble(
            message: 'what does this say about my thyroid?',
            isUser: true,
            maxWidth: 728 * 0.8,
            images: [url],
          ),
        ),
      ),
      const Size(768, 420),
      'user-image',
    );
  });

  // The drop overlay is inline in chat_ui_desktop.dart (_isDraggingFiles); this is that
  // block copied verbatim, with accent/bg/iconFg taken from the theme the same way.
  testWidgets('drag-and-drop overlay', (tester) async {
    await _shoot(
      tester,
      Builder(builder: (context) {
        final Color accent = Theme.of(context).colorScheme.primary;
        final Color bg = Theme.of(context).scaffoldBackgroundColor;
        final Color iconFg = Theme.of(context).iconTheme.color!;
        return Container(
          color: bg,
          child: Container(
            color: accent.withValues(alpha: 0.1),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent, width: 2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(Icons.cloud_upload, color: accent, size: 32),
                    const SizedBox(width: 16),
                    Text(
                      'Drop files here to upload',
                      style: TextStyle(color: iconFg, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
      const Size(640, 240),
      'drop',
    );
  });
}
