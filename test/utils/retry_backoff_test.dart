import 'dart:math';

import 'package:chuk_chat/utils/retry_backoff.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [Random] whose nextDouble always returns [value].
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

void main() {
  test('the middle of the jitter range is plain 700 ms * 2^n', () {
    final mid = _FixedRandom(0.5);
    expect(reconnectBackoff(0, random: mid), const Duration(milliseconds: 700));
    expect(
      reconnectBackoff(1, random: mid),
      const Duration(milliseconds: 1400),
    );
    expect(
      reconnectBackoff(2, random: mid),
      const Duration(milliseconds: 2800),
    );
  });

  test('jitter moves the delay by at most 10 %', () {
    expect(
      reconnectBackoff(0, random: _FixedRandom(0)),
      const Duration(milliseconds: 630),
    );
    expect(
      reconnectBackoff(0, random: _FixedRandom(0.999999)),
      const Duration(milliseconds: 770),
    );
    final random = Random(1);
    for (var i = 0; i < 200; i++) {
      final ms = reconnectBackoff(1, random: random).inMilliseconds;
      expect(ms, inInclusiveRange(1260, 1540));
    }
  });

  test('the delay is capped', () {
    expect(
      reconnectBackoff(10, random: _FixedRandom(0.999999)),
      kReconnectBackoffCap,
    );
    expect(reconnectBackoff(1000), lessThanOrEqualTo(kReconnectBackoffCap));
  });
}
