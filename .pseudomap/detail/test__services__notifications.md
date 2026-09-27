# test/services/notifications · Signaturen

## test/services/notifications/agents_notifications_test.dart  (110 Z.)
- L10 `void main()`

## test/services/notifications/local_notifications_test.dart  (167 Z.)
- L10 `class FakeBackend implements LocalNotificationsBackend`  — Records every call; the platform plugin never runs in a test.
  - L11 `bool initOk = true`
  - L12 `String? launch`
  - L13 `bool permission = true`
  - L14 `void Function(String? payload)? tap`
  - L15 `final List<Map<String, Object>> shown = <Map<String, Object>>[]`
  - L16 `final List<(int, String)> cancelled = <(int, String)>[]`
  - L19 `Future<bool> initialize({required void Function(String? payload) onTap})`
  - L25 `Future<void> show({ required int id, required String title, required String body, required String payload, required String tag, })`
  - L42 `Future<void> cancel({required int id, required String tag})`
  - L47 `Future<String?> launchPayload()`
  - L50 `Future<bool> requestPermission()`
- L53 `void main()`

## test/services/notifications/push_service_test.dart  (221 Z.)
- L10 `class FakeTransport implements PushTransport`  — Firebase, faked: the tests drive tokens and taps by hand.
  - L11 `bool available = true`
  - L12 `String? currentToken = 'tok-1'`
  - L13 `PushMessage? initial`
  - L14 `int permissionRequests = 0`
  - L15 `final StreamController<String> refresh = StreamController<String>.broadcast()`
  - L16 `final StreamController<PushMessage> opened = StreamController<PushMessage>.broadcast()`
  - L20 `Future<bool> initialize()`
  - L23 `Future<String?> token()`
  - L26 `Stream<String> get onTokenRefresh`
  - L29 `Stream<PushMessage> get onMessageOpenedApp`
  - L32 `Future<PushMessage?> initialMessage()`
  - L35 `Future<void> requestPermission()`
- L38 `class FakeStore implements DeviceTokenStore`
  - L39 `final List<Map<String, String>> upserts = <Map<String, String>>[]`
  - L40 `final List<(String, String)> deletes = <(String, String)>[]`
  - L43 `Future<void> upsert({ required String userId, required String deviceId, required String token, required String platform, })`
  - L58 `Future<void> delete({required String userId, required String deviceId})`
- L63 `void main()`
- L207 `class _ThrowingStore implements DeviceTokenStore`
  - L209 `Future<void> upsert({ required String userId, required String deviceId, required String token, required String platform, })`
  - L218 `Future<void> delete({required String userId, required String deviceId})`
