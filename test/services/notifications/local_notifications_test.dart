import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/notifications/local_notifications.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';

/// The default avatar lookup, kept so a test can put it back.
final Future<String?> Function(String agentId, String name)
defaultAvatarPathForTest = LocalNotifications.avatarPath;

/// Records every call; the platform plugin never runs in a test.
class FakeBackend implements LocalNotificationsBackend {
  bool initOk = true;
  String? launch;
  bool permission = true;
  void Function(String? payload)? tap;
  final List<Map<String, Object?>> shown = <Map<String, Object?>>[];
  final List<(int, String)> cancelled = <(int, String)>[];

  @override
  Future<bool> initialize({
    required void Function(String? payload) onTap,
  }) async {
    tap = onTap;
    return initOk;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required String tag,
    String? iconPath,
  }) async {
    shown.add(<String, Object?>{
      'id': id,
      'title': title,
      'body': body,
      'payload': payload,
      'tag': tag,
      'icon': iconPath,
    });
  }

  @override
  Future<void> cancel({required int id, required String tag}) async {
    cancelled.add((id, tag));
  }

  @override
  Future<String?> launchPayload() async => launch;

  @override
  Future<bool> requestPermission() async => permission;
}

void main() {
  late FakeBackend backend;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocalNotifications.avatarPath = (String agentId, String name) async =>
        '/avatars/$agentId.png';
    LocalNotifications.instance.reset();
    NotificationRouter.instance.reset();
    backend = FakeBackend();
  });

  tearDown(() {
    LocalNotifications.avatarPath = defaultAvatarPathForTest;
    LocalNotifications.instance.reset();
    NotificationRouter.instance.reset();
  });

  test('a toast is titled with the agent; no answer: a plain body', () async {
    await LocalNotifications.instance.initialize(backend: backend);
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: 'thread-1',
      threadLabel: 'Chief of Staff',
      runId: 'run-9',
    );
    expect(backend.shown, hasLength(1));
    final shown = backend.shown.single;
    expect(shown['title'], 'Chief of Staff');
    expect(shown['body'], 'Your answer is ready.');
    expect(shown['tag'], 'thread-1');
    expect(shown['id'], LocalNotifications.idFor('thread-1'));
    expect(shown['icon'], isNull, reason: 'no agent id: the app logo');
    final payload = jsonDecode(shown['payload']! as String) as Map;
    expect(payload, <String, String>{
      'session_key': 'thread-1',
      'run_id': 'run-9',
    });
  });

  test('the preview is on by default: the body is the answer', () async {
    expect(await LocalNotifications.answerPreviewEnabled(), isTrue);
    await LocalNotifications.instance.initialize(backend: backend);
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: 'thread-1',
      threadLabel: 'Research',
      preview: 'Drei Quellen gefunden.',
      agentId: 'agent-7',
    );
    final shown = backend.shown.single;
    expect(shown['title'], 'Research');
    expect(shown['body'], 'Drei Quellen gefunden.');
    expect(shown['icon'], '/avatars/agent-7.png');
  });

  test('preview setting off: no answer text in the body', () async {
    await LocalNotifications.setAnswerPreviewEnabled(false);
    await LocalNotifications.instance.initialize(backend: backend);
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: 'thread-1',
      threadLabel: 'Research',
      preview: 'Das Passwort ist hunter2.',
    );
    final shown = backend.shown.single;
    expect(shown['title'], 'Research');
    expect(shown['body'], LocalNotifications.defaultBody);
    expect(shown['body'], isNot(contains('hunter2')));
  });

  test(
    'a stopped run keeps its plain sentence, even with the preview on',
    () async {
      await LocalNotifications.instance.initialize(backend: backend);
      await LocalNotifications.instance.showAnswerReady(
        sessionKey: 'thread-1',
        threadLabel: 'Research',
        preview: 'partial secret',
        stopped: true,
      );
      expect(backend.shown.single['body'], LocalNotifications.stoppedBody);
    },
  );

  test('an avatar lookup that fails leaves the app logo', () async {
    LocalNotifications.avatarPath = (String agentId, String name) async =>
        throw StateError('no disk');
    await LocalNotifications.instance.initialize(backend: backend);
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: 't',
      threadLabel: 'Research',
      agentId: 'agent-7',
    );
    expect(backend.shown.single['icon'], isNull);
  });

  test('the setting round-trips through SharedPreferences', () async {
    await LocalNotifications.setAnswerPreviewEnabled(false);
    expect(await LocalNotifications.answerPreviewEnabled(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(LocalNotifications.showAnswerPreviewKey), isFalse);
    await LocalNotifications.setAnswerPreviewEnabled(true);
    expect(await LocalNotifications.answerPreviewEnabled(), isTrue);
  });

  test('preview: the body is the answer, cut short and free of '
      'markdown', () async {
    await LocalNotifications.instance.initialize(backend: backend);
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: 'thread-1',
      threadLabel: 'Research',
      preview: '# Report\n\nSee [the source](https://x.y) and `code`.',
    );
    expect(backend.shown.single['body'], 'Report See the source and code.');
  });

  group('notificationPreview', () {
    test('drops code blocks and render tags', () {
      expect(
        notificationPreview(
          'Hier:\n```dart\nvoid main() {}\n```\n<chart>{"a":1}</chart> fertig',
        ),
        'Hier: fertig',
      );
    });

    test('cuts at a word and marks the cut', () {
      final String long = List<String>.filled(100, 'wort').join(' ');
      final String out = notificationPreview(long, maxChars: 40);
      expect(out.length, lessThanOrEqualTo(41));
      expect(out.endsWith('\u2026'), isTrue);
      expect(out.contains('wor\u2026'), isFalse, reason: 'no cut mid-word');
    });

    test('clips to 300 characters by default (spec rule 2)', () {
      final String long = List<String>.filled(200, 'wort').join(' ');
      final String out = notificationPreview(long);
      expect(out.length, lessThanOrEqualTo(301));
      expect(out.length, greaterThan(250));
      expect(out.endsWith('\u2026'), isTrue);
    });

    test('collapses whitespace and keeps link text', () {
      expect(
        notificationPreview('Hallo\n\n  *Welt*   [hier](https://a.b)\t_ok_'),
        'Hallo Welt hier ok',
      );
    });

    test('nothing readable is empty', () {
      expect(notificationPreview('   '), '');
      expect(notificationPreview('```\nonly code\n```'), '');
    });
  });

  test('Android details are private; the ticker carries no body', () {
    final AndroidNotificationDetails details =
        LocalNotifications.androidDetails(
          title: 'Research',
          body: 'answer text',
          tag: 'thread-1',
        );
    expect(details.visibility, NotificationVisibility.private);
    expect(details.ticker, 'Research');
    expect(details.largeIcon, isNull);
    expect(details.icon, 'ic_notification');
    expect(details.tag, 'thread-1');
    expect(details.channelId, kAgentsNotificationChannelId);
  });

  test('Android: the avatar is the large icon, the small icon stays', () {
    final AndroidNotificationDetails details =
        LocalNotifications.androidDetails(
          title: 'Research',
          body: 'answer text',
          tag: 'thread-1',
          largeIconPath: '/avatars/a.png',
        );
    expect(details.icon, 'ic_notification');
    expect(details.largeIcon, isA<FilePathAndroidBitmap>());
    expect(
      (details.largeIcon! as FilePathAndroidBitmap).data,
      '/avatars/a.png',
    );
  });

  test('id is stable per thread and non-negative', () {
    expect(LocalNotifications.idFor('a'), LocalNotifications.idFor('a'));
    expect(LocalNotifications.idFor('a'), isNot(LocalNotifications.idFor('b')));
    expect(LocalNotifications.idFor('anything'), greaterThanOrEqualTo(0));
  });

  test('an empty label falls back to the app name', () async {
    await LocalNotifications.instance.initialize(backend: backend);
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: 't',
      threadLabel: '   ',
    );
    expect(backend.shown.single['title'], 'Chuk Chat');
  });

  test('a tap routes the thread and clears the toast', () async {
    await LocalNotifications.instance.initialize(backend: backend);
    backend.tap!(LocalNotifications.payloadFor('thread-2', runId: 'r'));
    await Future<void>.delayed(Duration.zero);
    expect(
      NotificationRouter.instance.pending.value,
      const NotificationTarget(sessionKey: 'thread-2', runId: 'r'),
    );
    expect(backend.cancelled, <(int, String)>[
      (LocalNotifications.idFor('thread-2'), 'thread-2'),
    ]);
  });

  test('a bad or empty payload is ignored', () async {
    await LocalNotifications.instance.initialize(backend: backend);
    backend.tap!(null);
    backend.tap!('');
    backend.tap!('not json');
    backend.tap!('{"nothing":1}');
    expect(NotificationRouter.instance.pending.value, isNull);
  });

  test('a cold start from a toast reaches the router', () async {
    backend.launch = LocalNotifications.payloadFor('thread-3');
    await LocalNotifications.instance.initialize(backend: backend);
    await LocalNotifications.instance.checkLaunchNotification();
    expect(NotificationRouter.instance.pending.value?.sessionKey, 'thread-3');
  });

  test('without a backend every call is a no-op', () async {
    backend.initOk = false;
    await LocalNotifications.instance.initialize(backend: backend);
    expect(LocalNotifications.instance.isInitialized, isFalse);
    await LocalNotifications.instance.showAnswerReady(
      sessionKey: 't',
      threadLabel: 'x',
    );
    await LocalNotifications.instance.cancelForSession('t');
    expect(await LocalNotifications.instance.requestPermission(), isFalse);
    expect(backend.shown, isEmpty);
    expect(backend.cancelled, isEmpty);
  });

  test('NotificationTarget.fromData reads both key spellings', () {
    expect(
      NotificationTarget.fromData(<String, Object?>{
        'session_key': 'a',
        'run_id': 'r',
      }),
      const NotificationTarget(sessionKey: 'a', runId: 'r'),
    );
    expect(
      NotificationTarget.fromData(<String, Object?>{
        'sessionKey': 'a',
        'runId': '',
      }),
      const NotificationTarget(sessionKey: 'a'),
    );
    expect(
      NotificationTarget.fromData(<String, Object?>{'session_key': ''}),
      isNull,
    );
    expect(NotificationTarget.fromData(null), isNull);
  });

  test('the Linux toast has an icon file to draw', () {
    // A D-Bus notification draws the app logo only when the sender hands the
    // picture over; a missing asset is a blank slot in the toast, which is
    // exactly the bug this guards.
    expect(kAgentsNotificationIconAsset, 'assets/icons/app_icon.png');
    expect(File(kAgentsNotificationIconAsset).existsSync(), isTrue);
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('- assets/icons/'),
    );
  });
}
