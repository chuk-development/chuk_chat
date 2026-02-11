import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/upload_rate_limiter.dart';

void main() {
  late UploadRateLimiter limiter;

  setUp(() {
    limiter = UploadRateLimiter();
    limiter.clearAllHistory();
  });

  group('constants', () {
    test('maxUploadsPerWindow is 10', () {
      expect(UploadRateLimiter.maxUploadsPerWindow, equals(10));
    });

    test('timeWindowMinutes is 5', () {
      expect(UploadRateLimiter.timeWindowMinutes, equals(5));
    });
  });

  group('isUploadAllowed', () {
    test('first upload is allowed', () {
      expect(limiter.isUploadAllowed('user1'), isTrue);
    });

    test('uploads within limit are allowed', () {
      for (int i = 0; i < 9; i++) {
        limiter.recordUpload('user1');
      }
      expect(limiter.isUploadAllowed('user1'), isTrue);
    });

    test('exceeding limit is denied', () {
      for (int i = 0; i < 10; i++) {
        limiter.recordUpload('user1');
      }
      expect(limiter.isUploadAllowed('user1'), isFalse);
    });

    test('different users tracked separately', () {
      for (int i = 0; i < 10; i++) {
        limiter.recordUpload('user1');
      }
      // user1 is blocked but user2 is not
      expect(limiter.isUploadAllowed('user1'), isFalse);
      expect(limiter.isUploadAllowed('user2'), isTrue);
    });
  });

  group('recordUpload', () {
    test('recording increases count', () {
      expect(limiter.getUploadsRemaining('user1'), equals(10));
      limiter.recordUpload('user1');
      expect(limiter.getUploadsRemaining('user1'), equals(9));
    });

    test('recording for new user creates history', () {
      limiter.recordUpload('newuser');
      expect(limiter.getUploadsRemaining('newuser'), equals(9));
    });
  });

  group('getUploadsRemaining', () {
    test('new user has max remaining', () {
      expect(limiter.getUploadsRemaining('user1'), equals(10));
    });

    test('decreases with each upload', () {
      limiter.recordUpload('user1');
      limiter.recordUpload('user1');
      limiter.recordUpload('user1');
      expect(limiter.getUploadsRemaining('user1'), equals(7));
    });

    test('at limit returns 0', () {
      for (int i = 0; i < 10; i++) {
        limiter.recordUpload('user1');
      }
      expect(limiter.getUploadsRemaining('user1'), equals(0));
    });
  });

  group('getTimeUntilReset', () {
    test('no uploads returns null', () {
      expect(limiter.getTimeUntilReset('user1'), isNull);
    });

    test('under limit returns null', () {
      limiter.recordUpload('user1');
      expect(limiter.getTimeUntilReset('user1'), isNull);
    });

    test('at limit returns positive seconds', () {
      for (int i = 0; i < 10; i++) {
        limiter.recordUpload('user1');
      }
      final reset = limiter.getTimeUntilReset('user1');
      // Should be positive (up to 5 minutes)
      expect(reset, isNotNull);
      expect(reset!, greaterThan(0));
      expect(reset, lessThanOrEqualTo(300));
    });
  });

  group('clearUserHistory', () {
    test('clears specific user', () {
      limiter.recordUpload('user1');
      limiter.recordUpload('user2');

      limiter.clearUserHistory('user1');

      expect(limiter.getUploadsRemaining('user1'), equals(10));
      expect(limiter.getUploadsRemaining('user2'), equals(9));
    });

    test('clearing non-existent user is safe', () {
      limiter.clearUserHistory('nonexistent');
      expect(limiter.getUploadsRemaining('nonexistent'), equals(10));
    });
  });

  group('clearAllHistory', () {
    test('clears all users', () {
      limiter.recordUpload('user1');
      limiter.recordUpload('user2');

      limiter.clearAllHistory();

      expect(limiter.getUploadsRemaining('user1'), equals(10));
      expect(limiter.getUploadsRemaining('user2'), equals(10));
    });
  });
}
