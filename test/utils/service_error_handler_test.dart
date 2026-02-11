import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/service_error_handler.dart';

void main() {
  /// Helper to create a DioException with a specific type
  DioException makeDioException(
    DioExceptionType type, {
    int? statusCode,
    dynamic data,
  }) {
    return DioException(
      type: type,
      requestOptions: RequestOptions(path: '/test'),
      response: statusCode != null
          ? Response(
              statusCode: statusCode,
              data: data,
              requestOptions: RequestOptions(path: '/test'),
            )
          : null,
    );
  }

  group('handleDioException', () {
    test('connectionTimeout', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.connectionTimeout),
      );
      expect(msg, contains('Connection timeout'));
    });

    test('sendTimeout', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.sendTimeout),
      );
      expect(msg, contains('Request timeout'));
    });

    test('receiveTimeout', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.receiveTimeout),
      );
      expect(msg, contains('Server response timeout'));
    });

    test('badCertificate', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badCertificate),
      );
      expect(msg, contains('SSL'));
    });

    test('cancel', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.cancel),
      );
      expect(msg, contains('cancelled'));
    });

    test('connectionError', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.connectionError),
      );
      expect(msg, contains('Connection error'));
    });

    test('unknown', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.unknown),
      );
      expect(msg, contains('Network error'));
    });

    test('badResponse 400', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 400),
      );
      expect(msg, contains('Invalid request'));
    });

    test('badResponse 401', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 401),
      );
      expect(msg, contains('Authentication failed'));
    });

    test('badResponse 403', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 403),
      );
      expect(msg, contains('Access denied'));
    });

    test('badResponse 404', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 404),
      );
      expect(msg, contains('not found'));
    });

    test('badResponse 429', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 429),
      );
      expect(msg, contains('Too many requests'));
    });

    test('badResponse 500', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 500),
      );
      expect(msg, contains('Server error'));
    });

    test('badResponse 502', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 502),
      );
      expect(msg, contains('Bad gateway'));
    });

    test('badResponse 503', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 503),
      );
      expect(msg, contains('unavailable'));
    });

    test('badResponse 504', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 504),
      );
      expect(msg, contains('Gateway timeout'));
    });

    test('badResponse with Map error data', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(
          DioExceptionType.badResponse,
          statusCode: 400,
          data: {'error': 'Custom error message'},
        ),
      );
      expect(msg, equals('Custom error message'));
    });

    test('badResponse with String error data', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(
          DioExceptionType.badResponse,
          statusCode: 500,
          data: 'String error from server',
        ),
      );
      expect(msg, equals('String error from server'));
    });

    test('badResponse with null statusCode', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse),
      );
      expect(msg, contains('Unknown error'));
    });

    test('badResponse generic 4xx', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 422),
      );
      expect(msg, contains('Client error'));
      expect(msg, contains('422'));
    });

    test('badResponse generic 5xx', () {
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.badResponse, statusCode: 505),
      );
      expect(msg, contains('Server error'));
      expect(msg, contains('505'));
    });

    test('with context parameter', () {
      // The context is used for debug logging, not in the returned message
      // but should not throw
      final msg = ServiceErrorHandler.handleDioException(
        makeDioException(DioExceptionType.connectionTimeout),
        context: 'chat send',
      );
      expect(msg, isNotEmpty);
    });
  });

  group('handleGenericException', () {
    test('DioException delegates to handleDioException', () {
      final msg = ServiceErrorHandler.handleGenericException(
        makeDioException(DioExceptionType.connectionTimeout),
      );
      expect(msg, contains('Connection timeout'));
    });

    test('non-Dio exception returns generic message', () {
      final msg = ServiceErrorHandler.handleGenericException(
        Exception('some error'),
      );
      expect(msg, contains('unexpected error'));
    });

    test('with context', () {
      final msg = ServiceErrorHandler.handleGenericException(
        Exception('fail'),
        context: 'upload',
      );
      expect(msg, isNotEmpty);
    });
  });

  group('isNetworkError', () {
    test('connectionError is network error', () {
      expect(
        ServiceErrorHandler.isNetworkError(
          makeDioException(DioExceptionType.connectionError),
        ),
        isTrue,
      );
    });

    test('connectionTimeout is network error', () {
      expect(
        ServiceErrorHandler.isNetworkError(
          makeDioException(DioExceptionType.connectionTimeout),
        ),
        isTrue,
      );
    });

    test('sendTimeout is network error', () {
      expect(
        ServiceErrorHandler.isNetworkError(
          makeDioException(DioExceptionType.sendTimeout),
        ),
        isTrue,
      );
    });

    test('receiveTimeout is network error', () {
      expect(
        ServiceErrorHandler.isNetworkError(
          makeDioException(DioExceptionType.receiveTimeout),
        ),
        isTrue,
      );
    });

    test('badResponse is NOT network error', () {
      expect(
        ServiceErrorHandler.isNetworkError(
          makeDioException(DioExceptionType.badResponse, statusCode: 500),
        ),
        isFalse,
      );
    });

    test('non-Dio error is NOT network error', () {
      expect(
        ServiceErrorHandler.isNetworkError(Exception('random')),
        isFalse,
      );
    });
  });

  group('isAuthError', () {
    test('401 is auth error', () {
      expect(
        ServiceErrorHandler.isAuthError(
          makeDioException(DioExceptionType.badResponse, statusCode: 401),
        ),
        isTrue,
      );
    });

    test('403 is auth error', () {
      expect(
        ServiceErrorHandler.isAuthError(
          makeDioException(DioExceptionType.badResponse, statusCode: 403),
        ),
        isTrue,
      );
    });

    test('500 is NOT auth error', () {
      expect(
        ServiceErrorHandler.isAuthError(
          makeDioException(DioExceptionType.badResponse, statusCode: 500),
        ),
        isFalse,
      );
    });

    test('non-Dio error is NOT auth error', () {
      expect(
        ServiceErrorHandler.isAuthError(Exception('auth fail')),
        isFalse,
      );
    });
  });

  group('isRateLimitError', () {
    test('429 is rate limit error', () {
      expect(
        ServiceErrorHandler.isRateLimitError(
          makeDioException(DioExceptionType.badResponse, statusCode: 429),
        ),
        isTrue,
      );
    });

    test('500 is NOT rate limit error', () {
      expect(
        ServiceErrorHandler.isRateLimitError(
          makeDioException(DioExceptionType.badResponse, statusCode: 500),
        ),
        isFalse,
      );
    });
  });

  group('isServerError', () {
    test('500 is server error', () {
      expect(
        ServiceErrorHandler.isServerError(
          makeDioException(DioExceptionType.badResponse, statusCode: 500),
        ),
        isTrue,
      );
    });

    test('503 is server error', () {
      expect(
        ServiceErrorHandler.isServerError(
          makeDioException(DioExceptionType.badResponse, statusCode: 503),
        ),
        isTrue,
      );
    });

    test('400 is NOT server error', () {
      expect(
        ServiceErrorHandler.isServerError(
          makeDioException(DioExceptionType.badResponse, statusCode: 400),
        ),
        isFalse,
      );
    });

    test('non-badResponse is NOT server error', () {
      expect(
        ServiceErrorHandler.isServerError(
          makeDioException(DioExceptionType.connectionTimeout),
        ),
        isFalse,
      );
    });
  });

  group('getRetryDelay', () {
    test('rate limit error gets 30s * attempt', () {
      final delay = ServiceErrorHandler.getRetryDelay(
        makeDioException(DioExceptionType.badResponse, statusCode: 429),
        2,
      );
      expect(delay, equals(const Duration(seconds: 60)));
    });

    test('server error gets exponential delay capped at 30s', () {
      final delay = ServiceErrorHandler.getRetryDelay(
        makeDioException(DioExceptionType.badResponse, statusCode: 500),
        3,
      );
      expect(delay, equals(const Duration(seconds: 6)));
    });

    test('network error gets 2s * attempt', () {
      final delay = ServiceErrorHandler.getRetryDelay(
        makeDioException(DioExceptionType.connectionTimeout),
        2,
      );
      expect(delay, equals(const Duration(seconds: 4)));
    });

    test('unknown error returns null (no retry)', () {
      final delay = ServiceErrorHandler.getRetryDelay(
        Exception('unknown'),
        1,
      );
      expect(delay, isNull);
    });

    test('auth error returns null (no retry)', () {
      final delay = ServiceErrorHandler.getRetryDelay(
        makeDioException(DioExceptionType.badResponse, statusCode: 401),
        1,
      );
      expect(delay, isNull);
    });
  });

  group('tryAsync', () {
    test('returns result on success', () async {
      final result = await ServiceErrorHandler.tryAsync<String>(
        operation: () async => 'data',
        context: 'test',
      );
      expect(result, equals('data'));
    });

    test('returns null on DioException', () async {
      String? errorMsg;
      final result = await ServiceErrorHandler.tryAsync<String>(
        operation: () async => throw makeDioException(
          DioExceptionType.connectionTimeout,
        ),
        context: 'test',
        onError: (msg) => errorMsg = msg,
      );
      expect(result, isNull);
      expect(errorMsg, isNotNull);
      expect(errorMsg, contains('Connection timeout'));
    });

    test('returns null on generic exception', () async {
      String? errorMsg;
      final result = await ServiceErrorHandler.tryAsync<String>(
        operation: () async => throw Exception('boom'),
        context: 'test',
        onError: (msg) => errorMsg = msg,
      );
      expect(result, isNull);
      expect(errorMsg, isNotNull);
    });
  });
}
