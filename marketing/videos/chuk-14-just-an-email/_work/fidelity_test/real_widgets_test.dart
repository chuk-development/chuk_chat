// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the REAL app widgets (Clawed dark theme) to PNG, as the reference half of the
// fidelity sheets for episode 14. Not part of the app's test suite.
// Run from the repo root (fake Supabase values only hide the "not configured" notice;
// no .env is read, see flutter_test_config.dart):
//   flutter test --dart-define=SUPABASE_URL=https://example.supabase.co \
//     --dart-define=SUPABASE_ANON_KEY=example \
//     marketing/videos/chuk-14-just-an-email/_work/fidelity_test/real_widgets_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/pages/otp_verification_page.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

const String work = 'marketing/videos/chuk-14-just-an-email/_work';
const double ratio = 2.0;
const String email = 'sam@example.com';
const String pw = 'Tide-Lantern-48!';

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
  // The app leaves ThemeData.fontFamily unset (system font: Ubuntu on the owner's Linux
  // desktop). The test engine has no system font, so the button text style (which names
  // no family) gets Ubuntu here explicitly, same size/weight/spacing as _kButtonTextStyle.
  const btn = WidgetStatePropertyAll<TextStyle>(TextStyle(
    fontFamily: 'Ubuntu',
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  ));
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: 'Ubuntu'),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Ubuntu'),
    textButtonTheme: TextButtonThemeData(style: t.textButtonTheme.style!.copyWith(textStyle: btn)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: t.elevatedButtonTheme.style!.copyWith(textStyle: btn)),
    filledButtonTheme: FilledButtonThemeData(style: t.filledButtonTheme.style!.copyWith(textStyle: btn)),
  );
}

final GlobalKey _shotKey = GlobalKey();

Future<void> _mount(WidgetTester tester, Widget child, Size size) async {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  await tester.pumpWidget(RepaintBoundary(
    key: _shotKey,
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
      home: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'Ubuntu'),
        child: child,
      ),
    ),
  ));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _save(WidgetTester tester, String name) async {
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: ratio);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  File('$work/fidelity/real-$name.png').writeAsBytesSync(png!);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _font('Ubuntu', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
    await _font('MaterialIcons', ['$sdk/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('sign-up page', (tester) async {
    await _mount(tester, const LoginPage(), const Size(480, 900));
    await _save(tester, 'signin');
    await tester.tap(find.text("Don't have an account? Sign up"));
    await _settle(tester);
    await _save(tester, 'signup-empty');
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), email);
    await tester.enterText(fields.at(2), 'Tide-La');
    await _settle(tester);
    await _save(tester, 'signup-typing');
    await tester.enterText(fields.at(2), pw);
    await tester.enterText(fields.at(3), pw);
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.tap(find.byType(Checkbox).at(1));
    await _settle(tester);
    // drop the focus so no field shows the focused outline in the reference
    FocusManager.instance.primaryFocus?.unfocus();
    await _settle(tester);
    await _save(tester, 'signup-filled');
  });

  testWidgets('one-time code page', (tester) async {
    await _mount(
      tester,
      OtpVerificationPage(
        email: email,
        body: 'We emailed a 6-digit code to $email. Enter it below to confirm your account.',
        onSubmit: (_) async {},
        onResend: () async {},
      ),
      const Size(480, 640),
    );
    await tester.enterText(find.byType(TextFormField), '482915');
    await _settle(tester);
    await _save(tester, 'otp');
    // unmount before the 60 s resend countdown would keep the test alive
    await tester.pumpWidget(const SizedBox());
  });

  // The danger zone of account_settings_page.dart, copied verbatim (SettingsListView padding 16).
  testWidgets('account deletion', (tester) async {
    late BuildContext ctx0;
    await _mount(
      tester,
      Scaffold(
        body: Builder(builder: (context) {
          ctx0 = context;
          final l = AppLocalizations.of(context)!;
          final cs = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExpressiveSectionHeader('Danger zone', color: cs.error),
                ExpressiveInfoCard(
                  text: l.deleteAccountWarning,
                  icon: Icons.warning_amber_rounded,
                  tone: cs.errorContainer,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.errorContainer,
                      foregroundColor: cs.onErrorContainer,
                    ),
                    icon: const AppIcon(Icons.delete_forever),
                    onPressed: () {},
                    label: Text(l.deleteAccount),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
      const Size(640, 760),
    );
    await _save(tester, 'danger');

    final l = AppLocalizations.of(ctx0)!;
    final cs = Theme.of(ctx0).colorScheme;
    // Step 1, verbatim from _deleteAccount
    showDialog<bool>(
      context: ctx0,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            AppIcon(Icons.warning_amber_rounded, color: cs.error, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(l.deleteAccountQuestion)),
          ],
        ),
        content: Text(l.deleteAccountConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.yesDelete),
          ),
        ],
      ),
    );
    await _settle(tester);
    await _save(tester, 'delete-1');
    Navigator.of(ctx0).pop();
    await _settle(tester);

    // Step 2
    showDialog<bool>(
      context: ctx0,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            AppIcon(Icons.delete_forever, color: cs.error, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(l.thisIsPermanent)),
          ],
        ),
        content: Text(l.finalDeleteWarning),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l.noKeepMyAccount)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.deleteEverything),
          ),
        ],
      ),
    );
    await _settle(tester);
    await _save(tester, 'delete-2');
    Navigator.of(ctx0).pop();
    await _settle(tester);

    // Step 3: password confirmation
    final passwordController = TextEditingController();
    showDialog<String>(
      context: ctx0,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l.confirmYourPassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.confirmPasswordBody),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l.password,
                prefixIcon: const AppIcon(Icons.lock_outline),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l.cancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: () {},
            child: Text(l.verifyAndDelete),
          ),
        ],
      ),
    );
    await _settle(tester);
    await _save(tester, 'delete-3-empty');
    passwordController.text = pw;
    await _settle(tester);
    await _save(tester, 'delete-3');
  });
}
