import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/network_status_service.dart';

void main() {
  setUp(() {
    // Reset state between tests
    NetworkStatusService.resetFailureCount();
    NetworkStatusService.setOnline();
  });

  group('isNetworkError', () {
    test('socketexception is network error', () {
      expect(
        NetworkStatusService.isNetworkError('SocketException: Connection refused'),
        isTrue,
      );
    });

    test('failed host lookup is network error', () {
      expect(
        NetworkStatusService.isNetworkError('Failed host lookup: example.com'),
        isTrue,
      );
    });

    test('network is unreachable', () {
      expect(
        NetworkStatusService.isNetworkError('Network is unreachable'),
        isTrue,
      );
    });

    test('connection refused', () {
      expect(
        NetworkStatusService.isNetworkError('Connection refused'),
        isTrue,
      );
    });

    test('connection timed out', () {
      expect(
        NetworkStatusService.isNetworkError('Connection timed out'),
        isTrue,
      );
    });

    test('no route to host', () {
      expect(
        NetworkStatusService.isNetworkError('No route to host'),
        isTrue,
      );
    });

    test('network error generic', () {
      expect(
        NetworkStatusService.isNetworkError('network error occurred'),
        isTrue,
      );
    });

    test('timeout generic', () {
      expect(
        NetworkStatusService.isNetworkError('Request timeout'),
        isTrue,
      );
    });

    test('case insensitive', () {
      expect(
        NetworkStatusService.isNetworkError('SOCKETEXCEPTION: blah'),
        isTrue,
      );
    });

    test('auth error is NOT network error', () {
      expect(
        NetworkStatusService.isNetworkError('401 Unauthorized'),
        isFalse,
      );
    });

    test('permission error is NOT network error', () {
      expect(
        NetworkStatusService.isNetworkError('403 Forbidden'),
        isFalse,
      );
    });

    test('generic error is NOT network error', () {
      expect(
        NetworkStatusService.isNetworkError('Something went wrong'),
        isFalse,
      );
    });

    test('null returns false', () {
      expect(NetworkStatusService.isNetworkError(null), isFalse);
    });

    test('exception object is checked via toString', () {
      expect(
        NetworkStatusService.isNetworkError(Exception('connection refused')),
        isTrue,
      );
    });
  });

  group('manual status control', () {
    test('default is online', () {
      expect(NetworkStatusService.isOnline, isTrue);
    });

    test('setOffline changes state', () {
      NetworkStatusService.setOffline();
      expect(NetworkStatusService.isOnline, isFalse);
    });

    test('setOnline restores state', () {
      NetworkStatusService.setOffline();
      NetworkStatusService.setOnline();
      expect(NetworkStatusService.isOnline, isTrue);
    });

    test('isOnlineListenable reflects state', () {
      expect(NetworkStatusService.isOnlineListenable.value, isTrue);
      NetworkStatusService.setOffline();
      expect(NetworkStatusService.isOnlineListenable.value, isFalse);
    });
  });

  group('resetFailureCount', () {
    test('does not throw', () {
      expect(() => NetworkStatusService.resetFailureCount(), returnsNormally);
    });
  });
}
