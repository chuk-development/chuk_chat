import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/notifications/local_notifications.dart';
import 'package:cowork/services/notifications/notification_router.dart';

/// Records every call; the platform plugin never runs in a test.
class FakeBackend implements LocalNotificationsBackend {
  bool initOk = true;
  String? launch;
  bool permission = true;
  void Function(String? payload)? tap;
  final List<Map<String, Object>> shown = <Map<String, Object>>[];
  final List<(int, String)> cancelled = <(int, String)>[];

  @override
  Future<bool> initialize({required void Function(String? payload) onTap}) async {
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
  }) async {
    shown.add(<String, Object>{
      'id': id,
      'title': title,
      'body': body,
      'payload': payload,
      'tag': tag,
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
    LocalNotifications.instance.reset();
    NotificationRouter.instance.reset();
    backend = FakeBackend();
  });

  tearDown(() {
    LocalNotifications.instance.reset();
    NotificationRouter.instance.reset();
  });

  test('a toast names the coworker and never carries the answer', () async {
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
    final payload = jsonDecode(shown['payload']! as String) as Map;
    expect(payload, <String, String>{'session_key': 'thread-1', 'run_id': 'run-9'});
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
    expect(backend.shown.single['title'], 'CoWork');
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
      NotificationTarget.fromData(<String, Object?>{'session_key': 'a', 'run_id': 'r'}),
      const NotificationTarget(sessionKey: 'a', runId: 'r'),
    );
    expect(
      NotificationTarget.fromData(<String, Object?>{'sessionKey': 'a', 'runId': ''}),
      const NotificationTarget(sessionKey: 'a'),
    );
    expect(NotificationTarget.fromData(<String, Object?>{'session_key': ''}), isNull);
    expect(NotificationTarget.fromData(null), isNull);
  });

  test('the Linux toast has an icon file to draw', () {
    // A D-Bus notification draws the app logo only when the sender hands the
    // picture over; a missing asset is a blank slot in the toast, which is
    // exactly the bug this guards.
    expect(kCoworkNotificationIconAsset, 'assets/icons/app_icon.png');
    expect(File(kCoworkNotificationIconAsset).existsSync(), isTrue);
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('- assets/icons/'),
    );
  });
}
