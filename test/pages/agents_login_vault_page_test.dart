import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/agents_login_vault_page.dart';
import 'package:chuk_chat/services/agents/agents_login_vault.dart';
import 'package:chuk_chat/services/agents/agents_reply_frames.dart';

import '../support/test_app.dart';

/// Plays the host: records each frame and answers with [answer].
class _Host {
  _Host(this.bus);

  final AgentsReplyFrames bus;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
  String? nextError;

  Future<void> send(Map<String, dynamic> frame) async {
    frames.add(Map<String, dynamic>.of(frame));
    final String? error = nextError;
    nextError = null;
    final Map<String, dynamic> reply = <String, dynamic>{
      'type': 'login_vault',
      'entries': entries,
      'error': ?error,
      'request_id': ?frame['request_id'],
    };
    if (error == null && frame['type'] == 'login_vault_set') {
      reply['saved'] = <String, dynamic>{
        'id': 'new1',
        'origin': frame['origin'],
        'username': frame['username'],
      };
    }
    Future<void>.microtask(() => bus.add(reply));
  }
}

Map<String, dynamic> _github({bool totp = true}) => <String, dynamic>{
  'id': 'gh1',
  'origin': 'https://github.com',
  'username': 'octo@example.com',
  'label': 'work',
  'has_totp': totp,
  'created_at': 1762300000000,
  'last_used_at': 1762310000000,
};

void main() {
  late AgentsReplyFrames bus;
  late _Host host;
  late AgentsLoginVault vault;

  setUp(() {
    bus = AgentsReplyFrames();
    host = _Host(bus);
    vault = AgentsLoginVault(send: host.send, replies: bus);
  });

  Future<void> setWidth(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  for (final double width in <double>[360, 1280]) {
    group('at $width px', () {
      testWidgets('the page lists the logins without a password', (
        tester,
      ) async {
        await setWidth(tester, width);
        host.entries = <Map<String, dynamic>>[_github()];
        await tester.pumpWidget(testApp(AgentsLoginVaultPage(vault: vault)));
        await tester.pumpAndSettle();

        expect(host.frames.first['type'], 'login_vault_list');
        expect(host.frames.first['request_id'], isA<String>());
        expect(find.text('Logins'), findsWidgets);
        expect(find.text('https://github.com'), findsOneWidget);
        expect(find.textContaining('octo@example.com'), findsOneWidget);
        expect(find.textContaining('work'), findsWidgets);
        expect(
          find.byKey(const ValueKey<String>('login-vault-2fa-gh1')),
          findsOneWidget,
        );
        expect(find.textContaining('Last used'), findsOneWidget);
        expect(find.textContaining('never sees'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('an error keeps the sheet open and clears the password', (
        tester,
      ) async {
        await setWidth(tester, width);
        await tester.pumpWidget(testApp(AgentsLoginVaultPage(vault: vault)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey<String>('login-vault-add')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey<String>('login-vault-field-site')),
          'GitHub.com/login',
        );
        await tester.pump();
        expect(find.text('Saved for https://github.com'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey<String>('login-vault-field-username')),
          'octo',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('login-vault-field-password')),
          'hunter2',
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.enterText(
          find.byKey(const ValueKey<String>('login-vault-field-totp')),
          'JBSWY3DPEHPK3PXP',
        );
        // A person types slower than the undo history's 500 ms throttle: the
        // secrets are on the undo stack before Save.
        await tester.pump(const Duration(milliseconds: 600));
        host.nextError =
            'totp_secret must be a base32 key or an otpauth:// URI';
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('login-vault-save')),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('login-vault-save')),
        );
        await tester.pumpAndSettle();

        final Map<String, dynamic> sent = host.frames.last;
        expect(sent['type'], 'login_vault_set');
        expect(sent['origin'], 'https://github.com');
        expect(sent['password'], 'hunter2');
        expect(sent['totp_secret'], 'JBSWY3DPEHPK3PXP');
        // The sheet stays, says why, and holds no secret any more.
        expect(find.byType(LoginVaultForm), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('login-vault-error')),
          findsOneWidget,
        );
        TextField field(String key) => tester.widget<TextField>(
          find.byKey(ValueKey<String>('login-vault-field-$key')),
        );
        expect(field('password').controller?.text, isEmpty);
        expect(field('totp').controller?.text, isEmpty);
        expect(field('password').obscureText, isTrue);
        expect(field('password').enableSuggestions, isFalse);
        expect(field('password').autocorrect, isFalse);
        expect(field('password').enableInteractiveSelection, isFalse);
        expect(field('password').keyboardType, TextInputType.visiblePassword);
        expect(tester.takeException(), isNull);

        // An undo does not bring a cleared secret back (review of b8e3343c,
        // finding 9): the undo history went with the text.
        for (final (String key, String secret) in <(String, String)>[
          ('password', 'hunter2'),
          ('totp', 'JBSWY3DPEHPK3PXP'),
        ]) {
          expect(field(key).undoController?.value.canUndo, isFalse);
          final Finder input = find.byKey(
            ValueKey<String>('login-vault-field-$key'),
          );
          await tester.enterText(input, 'x');
          await tester.pump(const Duration(milliseconds: 600));
          final List<String> seen = <String>[];
          for (int i = 0; i < 4; i++) {
            // Ctrl+Z, the undo shortcut of a text field.
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump(const Duration(milliseconds: 600));
            seen.add(field(key).controller?.text ?? '');
          }
          expect(seen, isNot(contains(secret)), reason: key);
          await tester.enterText(input, '');
          await tester.pump(const Duration(milliseconds: 600));
        }

        // A second try with a fresh password succeeds and closes the sheet.
        await tester.enterText(
          find.byKey(const ValueKey<String>('login-vault-field-password')),
          'hunter3',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('login-vault-save')),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('login-vault-save')),
        );
        await tester.pumpAndSettle();
        expect(host.frames.last['password'], 'hunter3');
        expect(host.frames.last.containsKey('totp_secret'), isFalse);
        expect(find.byType(LoginVaultForm), findsNothing);
      });
    });
  }

  testWidgets('the show toggle reveals the password', (tester) async {
    await setWidth(tester, 360);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(children: <Widget>[LoginVaultForm(vault: vault)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    TextField password() => tester.widget<TextField>(
      find.byKey(const ValueKey<String>('login-vault-field-password')),
    );
    expect(password().obscureText, isTrue);
    await tester.tap(
      find.byKey(const ValueKey<String>('login-vault-toggle-password')),
    );
    await tester.pumpAndSettle();
    expect(password().obscureText, isFalse);
  });

  testWidgets('a bad site is refused before anything is sent', (tester) async {
    await setWidth(tester, 360);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(children: <Widget>[LoginVaultForm(vault: vault)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-vault-field-site')),
      'http://github.com',
    );
    await tester.tap(find.byKey(const ValueKey<String>('login-vault-save')));
    await tester.pumpAndSettle();
    expect(host.frames, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('login-vault-help-site')),
      findsOneWidget,
    );
  });

  testWidgets('edit fixes origin and username and can remove the key', (
    tester,
  ) async {
    await setWidth(tester, 1280);
    final AgentsLoginEntry entry = AgentsLoginEntry.fromJson(_github())!;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: <Widget>[LoginVaultForm(vault: vault, entry: entry)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    TextField field(String key) => tester.widget<TextField>(
      find.byKey(ValueKey<String>('login-vault-field-$key')),
    );
    expect(field('site').enabled, isFalse);
    expect(field('username').enabled, isFalse);
    expect(field('password').controller?.text, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey<String>('login-vault-remove-totp')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-vault-field-password')),
      'new-pass',
    );
    await tester.tap(find.byKey(const ValueKey<String>('login-vault-save')));
    await tester.pumpAndSettle();
    final Map<String, dynamic> sent = host.frames.single;
    expect(sent['origin'], 'https://github.com');
    expect(sent['username'], 'octo@example.com');
    expect(sent.containsKey('totp_secret'), isTrue);
    expect(sent['totp_secret'], isNull);
    expect(sent['label'], 'work');
  });

  testWidgets('delete asks first, then sends the id', (tester) async {
    await setWidth(tester, 360);
    host.entries = <Map<String, dynamic>>[_github()];
    await tester.pumpWidget(testApp(AgentsLoginVaultPage(vault: vault)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('login-vault-menu-gh1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete the login for https://github.com?'), findsOne);
    host.entries = <Map<String, dynamic>>[];
    await tester.tap(
      find.byKey(const ValueKey<String>('login-vault-delete-confirm')),
    );
    await tester.pumpAndSettle();
    expect(Map<String, dynamic>.of(host.frames.last)..remove('request_id'), <
      String,
      dynamic
    >{
      'type': 'login_vault_delete',
      'id': 'gh1',
    });
    expect(find.text('https://github.com'), findsNothing);
  });
}
