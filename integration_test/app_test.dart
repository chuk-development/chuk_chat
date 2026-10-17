// End-to-end walk through the real app, with one screenshot per screen.
//
// The app runs against the local E2E stack (local Supabase + the chuk API
// emulator), never against production. The full command is in
// docs/INTEGRATION_TESTS.md. It sets XDG_DATA_HOME, XDG_CACHE_HOME and
// XDG_STATE_HOME to new, empty folders under _scratch/, so the test does not
// touch the data of the installed app. The test fails without them.
//
// Screenshots: build/integration_shots/<NN>_<screen>.png

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/main.dart' as app;
import 'package:chuk_chat/services/api_config_base.dart'
    show getAgentsRelayBaseUrl, getApiBaseUrl;
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart'
    show debugSbChatTimeOfDayOverride;
import 'package:chuk_chat/widgets/icons/icon_map.dart' show AppIcon;

import 'support/shots.dart';

const String _apiBaseUrl = String.fromEnvironment('API_BASE_URL');
const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const String _email = String.fromEnvironment('E2E_EMAIL');

/// Other URL defines the app reads. Each one that is set must be loopback.
const Map<String, String> _otherUrlDefines = <String, String>{
  'PRODUCTION_API_URL': String.fromEnvironment('PRODUCTION_API_URL'),
  'LOCAL_API_URL': String.fromEnvironment('LOCAL_API_URL'),
  'AGENTS_RELAY_URL': String.fromEnvironment('AGENTS_RELAY_URL'),
  'AGENTS_DEV_HOST': String.fromEnvironment('AGENTS_DEV_HOST'),
  'ARTIFACTS_BASE_URL': String.fromEnvironment('ARTIFACTS_BASE_URL'),
  'SKILLS_CATALOG_BASE': String.fromEnvironment('SKILLS_CATALOG_BASE'),
  'VOICE_TOKEN_URL': String.fromEnvironment('VOICE_TOKEN_URL'),
};
const String _apiHost = String.fromEnvironment('API_HOST');
const bool _linuxKeyring = bool.fromEnvironment('FEATURE_LINUX_KEYRING');
const String _password = String.fromEnvironment('E2E_PASSWORD');

/// The message the test sends. The emulator answers with `Echo: <message>`.
const String _message = 'Hello from the integration test';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // A blinking caret makes two runs give different PNG bytes. With this
  // debug flag the caret is drawn solid and has no blink timer.
  EditableText.debugDeterministicCursor = true;
  // The chat list shows the creation time of today's chats. A fixed text
  // keeps the chat list screenshots the same from minute to minute.
  debugSbChatTimeOfDayOverride = '12:00';

  setUpAll(() {
    // The test runs inside the app process. Without its own XDG folders the
    // app uses the data folders of the installed app and replaces its login,
    // chat cache and send queue.
    for (final String key in <String>[
      'XDG_DATA_HOME',
      'XDG_CACHE_HOME',
      'XDG_STATE_HOME',
    ]) {
      if ((Platform.environment[key] ?? '').isEmpty) {
        fail(
          '$key is not set. The test would use the data folders of the '
          'installed app. Use the command in docs/INTEGRATION_TESTS.md.',
        );
      }
    }

    // Rule: tests are offline. Refuse to run against anything that is not
    // on the loopback interface: the two stack URLs, the URLs the app
    // resolves from all its defines, and every other URL define that is set.
    final Map<String, String> urls = <String, String>{
      'API_BASE_URL': _apiBaseUrl,
      'SUPABASE_URL': _supabaseUrl,
      'resolved API base URL': getApiBaseUrl(),
      'resolved Agents relay URL': getAgentsRelayBaseUrl(),
      for (final MapEntry<String, String> e in _otherUrlDefines.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    urls.forEach((String name, String url) {
      if (!_isLoopbackHost(Uri.tryParse(url)?.host ?? '')) {
        fail(
          '$name must point to the local E2E stack (got "$url"). '
          'Use --dart-define-from-file=_scratch/e2e.defines.json.',
        );
      }
    });
    if (_apiHost.isNotEmpty && !_isLoopbackHost(_apiHost)) {
      fail('API_HOST must be empty or a loopback host (got "$_apiHost").');
    }
    // The XDG folders do not isolate the system keyring.
    if (_linuxKeyring) {
      fail(
        'FEATURE_LINUX_KEYRING must be false: the system keyring is shared '
        'with the installed app.',
      );
    }
    if (_email.isEmpty || _password.isEmpty) {
      fail('E2E_EMAIL and E2E_PASSWORD are not set. Use the defines file.');
    }
  });

  testWidgets('walk the main screens and take screenshots', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(_resetEmulator);
    await tester.runAsync(_deleteServerChats);

    await app.main();
    await tester.pump();

    // 1. Sign-in page.
    final Finder emailField = find.bySemanticsIdentifier('login_email_field');
    await _pumpUntil(tester, emailField, 'the sign-in page');
    final AppLocalizations l = AppLocalizations.of(
      tester.element(emailField),
    )!;
    await tester.enterText(
      find.descendant(of: emailField, matching: find.byType(EditableText)),
      _email,
    );
    await tester.enterText(
      find.descendant(
        of: find.bySemanticsIdentifier('login_password_field'),
        matching: find.byType(EditableText),
      ),
      _password,
    );
    await tester.pump();
    await takeShot(tester, '01_sign_in');

    // 2. Signed in: empty chat with the composer and the chat list.
    await tester.tap(find.bySemanticsIdentifier('login_submit_button'));
    final Finder composerHint = find.text(l.askMeAnything);
    await _pumpUntil(tester, composerHint, 'the chat screen after sign-in');
    await _settle(tester);
    await takeShot(tester, '02_chat_home');

    // 3. Send a message and wait for the emulated answer.
    final Finder composer = find.ancestor(
      of: composerHint,
      matching: find.byType(TextField),
    );
    await tester.enterText(composer.first, _message);
    await tester.pump();
    await tester.tap(_appIcon(Icons.arrow_upward_rounded).last);
    await tester.pump();
    final Finder answer = find.textContaining(
      'Echo: $_message',
      findRichText: true,
    );
    await _pumpUntil(
      tester,
      answer,
      'the emulated answer',
      timeout: const Duration(seconds: 60),
    );
    await _settle(tester);
    await takeShot(tester, '03_chat_answer');

    // 4. New chat, then open the sidebar: the sent chat is in the chat list.
    await tester.tap(find.byTooltip(l.newChat).first);
    await _settle(tester);
    await _openSidebar(tester);
    final Finder listEntry = find.textContaining(_message);
    await _pumpUntil(tester, listEntry, 'the chat in the chat list');
    await takeShot(tester, '04_chat_list');

    // 5. Open the chat from the list.
    await tester.tap(listEntry.first);
    await _pumpUntil(
      tester,
      answer,
      'the reopened chat',
      timeout: const Duration(seconds: 30),
    );
    await _settle(tester);
    await takeShot(tester, '05_chat_open');

    // 6. Settings (the button is in the sidebar header).
    if (find.byTooltip(l.settings).hitTestable().evaluate().isEmpty) {
      await _openSidebar(tester);
    }
    await tester.tap(find.byTooltip(l.settings).hitTestable().first);
    await _settle(tester, const Duration(seconds: 2));
    await takeShot(tester, '06_settings');
  });
}

bool _isLoopbackHost(String host) {
  String h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  return h == '127.0.0.1' || h == 'localhost' || h == '::1';
}

/// Finds an [AppIcon] that draws [icon].
Finder _appIcon(IconData icon) => find.byWidgetPredicate(
  (Widget w) => w is AppIcon && w.icon == icon,
  description: 'AppIcon($icon)',
);

/// Taps the menu button of the desktop shell, so the folded sidebar opens.
Future<void> _openSidebar(WidgetTester tester) async {
  await tester.tap(_appIcon(Icons.menu_rounded).first);
  await _settle(tester);
}

/// Clears the emulator script queue and request log, so the default echo turn
/// answers the message.
Future<void> _resetEmulator() async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri.parse('$_apiBaseUrl/__emulator/reset'),
    );
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    if (response.statusCode != 200) {
      fail('Emulator reset failed: HTTP ${response.statusCode}');
    }
  } finally {
    client.close(force: true);
  }
}

/// Deletes every chat of the test user in the local Supabase.
///
/// Without this, each run adds one chat to the list, so the chat list
/// screenshots differ from run to run. The row-level security policy lets a
/// user delete their own rows, so the anon key and the user's token are
/// enough.
Future<void> _deleteServerChats() async {
  if (_supabaseAnonKey.isEmpty) {
    fail('SUPABASE_ANON_KEY is not set. Use the defines file.');
  }
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest signIn = await client.postUrl(
      Uri.parse('$_supabaseUrl/auth/v1/token?grant_type=password'),
    );
    signIn.headers
      ..set('apikey', _supabaseAnonKey)
      ..contentType = ContentType.json;
    signIn.write(jsonEncode(<String, String>{
      'email': _email,
      'password': _password,
    }));
    final HttpClientResponse signInResponse = await signIn.close();
    final String body = await utf8.decodeStream(signInResponse);
    if (signInResponse.statusCode != 200) {
      fail('Test user sign-in failed: HTTP ${signInResponse.statusCode}');
    }
    final Map<String, dynamic> session =
        jsonDecode(body) as Map<String, dynamic>;
    final String token = session['access_token'] as String;
    final String userId =
        (session['user'] as Map<String, dynamic>)['id'] as String;

    final HttpClientRequest delete = await client.deleteUrl(
      Uri.parse('$_supabaseUrl/rest/v1/encrypted_chats?user_id=eq.$userId'),
    );
    delete.headers
      ..set('apikey', _supabaseAnonKey)
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final HttpClientResponse deleteResponse = await delete.close();
    await deleteResponse.drain<void>();
    if (deleteResponse.statusCode >= 300) {
      fail('Deleting old test chats failed: HTTP ${deleteResponse.statusCode}');
    }
  } finally {
    client.close(force: true);
  }
}

/// Pumps frames until [finder] finds a widget, or fails after [timeout].
///
/// `pumpAndSettle` is not used: the app has endless animations (spinners,
/// the streaming cursor), so it would never settle.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final DateTime end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail(
    'Timed out after ${timeout.inSeconds}s waiting for $what.\n'
    'Visible texts: ${jsonEncode(_visibleTexts())}',
  );
}

/// Pumps frames for [duration] so animations and async loads can finish.
Future<void> _settle(
  WidgetTester tester, [
  Duration duration = const Duration(seconds: 1),
]) async {
  final DateTime end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<String> _visibleTexts() {
  final List<String> out = <String>[];
  for (final Element e in find.byType(Text).evaluate()) {
    final String? data = (e.widget as Text).data;
    if (data != null && data.trim().isNotEmpty) out.add(data);
  }
  return out.take(80).toList();
}
