import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/dashboard/dashboard_controller.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';

class _Harness {
  _Harness({
    this.failSend = false,
    Map<String, String>? kv,
  }) {
    if (kv != null) this.kv.addAll(kv);
    controller = DashboardController(
      send: (Map<String, dynamic> frame) async {
        if (failSend) throw StateError('down');
        sent.add(frame);
      },
      attachedHost: host,
      userId: () => _user,
      readKv: (String key) async => this.kv[key],
      writeKv: (String key, String value) async => this.kv[key] = value,
      clock: () => DateTime(2026, 11, 4, 20),
      newOpId: () => 'op${++_ops}',
      refreshTimeout: const Duration(milliseconds: 50),
    )..init();
  }

  String? _user = 'u1';
  bool failSend;
  int _ops = 0;
  final ValueNotifier<String?> host = ValueNotifier<String?>(null);
  final Map<String, String> kv = <String, String>{};
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  late final DashboardController controller;

  set user(String? v) => _user = v;
}

Map<String, dynamic> state(
  int version,
  List<Map<String, dynamic>> widgets, {
  String? opId,
}) => <String, dynamic>{
  'type': 'dashboard_state',
  'dashboard': <String, dynamic>{'version': version, 'widgets': widgets},
  'op_id': ?opId,
};

Map<String, dynamic> tracker([
  List<Map<String, dynamic>> entries = const <Map<String, dynamic>>[],
]) => <String, dynamic>{
  'id': 'pushups',
  'type': 'tracker',
  'title': 'Push-ups',
  'goal': 100,
  'entries': entries,
};

double today(DashboardController c) =>
    (c.document.byId('pushups')! as TrackerWidget).current(c.now());

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('attach sends get, the state replaces the copy and is cached', () async {
    final _Harness h = _Harness();
    await h.controller.ready();
    h.host.value = 'hostA';
    await settle();
    await settle();
    expect(h.sent.single['type'], 'dashboard_get');
    h.controller.handleFrame(state(3, <Map<String, dynamic>>[tracker()]));
    await settle();
    expect(h.controller.document.version, 3);
    expect(h.kv['dashboard_v1_u1_host'], 'hostA');
    final Object? cached = jsonDecode(
      h.kv[DashboardController.docKeyFor('u1', 'hostA')]!,
    );
    expect((cached! as Map)['version'], 3);
  });

  test(
    'a tap shows at once and settles on the answer with its op_id',
    () async {
      final _Harness h = _Harness();
      h.host.value = 'hostA';
      await settle();
      h.controller.handleFrame(state(1, <Map<String, dynamic>>[tracker()]));
      await h.controller.log('pushups', 10);
      expect(today(h.controller), 10);
      expect(h.controller.pendingCount, 1);
      final Map<String, dynamic> op = h.sent.last;
      expect(op['type'], 'dashboard_op');
      expect(op['action'], 'log');
      expect(op['op_id'], 'op1');
      expect(op['at'], isA<String>());
      // The host's answer carries the entry; the op is not applied twice.
      h.controller.handleFrame(
        state(2, <Map<String, dynamic>>[
          tracker(<Map<String, dynamic>>[
            <String, dynamic>{'at': op['at'], 'value': 10},
          ]),
        ], opId: 'op1'),
      );
      expect(h.controller.pendingCount, 0);
      expect(today(h.controller), 10);
    },
  );

  test(
    'offline taps wait, survive a restart and flush before the get',
    () async {
      final _Harness h = _Harness();
      h.host.value = 'hostA';
      await settle();
      h.controller.handleFrame(state(1, <Map<String, dynamic>>[tracker()]));
      await settle();
      h.host.value = null;
      await h.controller.log('pushups', 25);
      await h.controller.log('pushups', 1);
      expect(today(h.controller), 26);

      // A fresh controller (app restart) reads the copy and the pending list.
      final _Harness again = _Harness(kv: h.kv);
      final DashboardController c = again.controller;
      await c.ready();
      expect(c.pendingCount, 2);
      expect(
        (c.document.byId('pushups')! as TrackerWidget).current(c.now()),
        26,
      );
      again.host.value = 'hostA';
      await settle();
      await settle();
      await settle();
      expect(again.sent.map((Map<String, dynamic> f) => f['type']), <String>[
        'dashboard_op',
        'dashboard_op',
        'dashboard_get',
      ]);
      // The answer to the second op settles the first one too (FIFO).
      c.handleFrame(
        state(3, <Map<String, dynamic>>[
          tracker(),
        ], opId: again.sent[1]['op_id'] as String),
      );
      expect(c.pendingCount, 0);
    },
  );

  test('a refused op is dropped and the user is told', () async {
    final _Harness h = _Harness();
    h.host.value = 'hostA';
    await settle();
    h.controller.handleFrame(state(1, <Map<String, dynamic>>[tracker()]));
    await h.controller.log('pushups', 10);
    h.controller.handleFrame(<String, dynamic>{
      'type': 'dashboard_error',
      'op_id': 'op1',
      'message': 'Widget not found',
    });
    expect(h.controller.pendingCount, 0);
    expect(today(h.controller), 0);
    expect(h.controller.notice.value, 'Widget not found');
  });

  test('a failed send keeps the op pending', () async {
    final _Harness h = _Harness(failSend: true);
    h.host.value = 'hostA';
    await settle();
    h.controller.handleFrame(state(1, <Map<String, dynamic>>[tracker()]));
    await h.controller.log('pushups', 10);
    expect(h.controller.pendingCount, 1);
    expect(today(h.controller), 10);
  });

  test('another user never sees the copy', () async {
    final _Harness h = _Harness();
    h.host.value = 'hostA';
    await settle();
    h.controller.handleFrame(state(1, <Map<String, dynamic>>[tracker()]));
    expect(h.controller.document.widgets, isNotEmpty);
    h.user = 'u2';
    expect(h.controller.document.widgets, isEmpty);
    h.user = null;
    expect(h.controller.document.widgets, isEmpty);
    h.controller.handleFrame(state(9, <Map<String, dynamic>>[tracker()]));
    expect(h.controller.document.widgets, isEmpty);
  });

  test('refresh waits for the answer and says false offline', () async {
    final _Harness h = _Harness();
    expect(await h.controller.refresh(), isFalse);
    h.host.value = 'hostA';
    await settle();
    final Future<bool> r = h.controller.refresh();
    await settle();
    h.controller.handleFrame(state(2, <Map<String, dynamic>>[]));
    expect(await r, isTrue);
  });
}
