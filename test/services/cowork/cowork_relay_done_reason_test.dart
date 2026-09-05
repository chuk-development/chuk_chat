import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// `done.reason` semantics the thread view relies on (docs/WIRE_CONTRACT.md,
/// "done"): a stop, the ESTOP file and the host's wall-clock guard (Bead
/// cowork-qxa, `timeout`) all read as "stopped short of an answer".
void main() {
  CoworkRelayDone done(String reason) =>
      CoworkRelayDone(reason: reason, finalAnswer: null, iterations: 1);

  test('interrupted, estop and timeout are stops', () {
    expect(done('interrupted').wasStopped, isTrue);
    expect(done('estop').wasStopped, isTrue);
    expect(done('timeout').wasStopped, isTrue);
  });

  test('a finished, failed or replay terminal is not a stop', () {
    expect(done('finished').wasStopped, isFalse);
    expect(done('failed').wasStopped, isFalse);
    expect(done('host_restarted').wasStopped, isFalse);
    expect(done('replay').wasStopped, isFalse);
    expect(done('replay').isHistoryEnd, isTrue);
  });
}
