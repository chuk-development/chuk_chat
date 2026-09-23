// Speed test for the data work one agent switch starts, without widgets.
//
// A switch mounts (or reloads) the imported chat screen. Before any row is
// painted, that screen reads the model catalogue several times (the model
// name, the custom model name, the picked models, the capabilities) and runs
// the stale tool-call recovery over every message of the thread. In the live
// app this work showed up as full `jsonDecode` calls of the ~200 KB catalogue
// and a decode of every tool-call payload, on the UI isolate, per switch.
//
// The widget test next to this file cannot see that work: the catalogue lives
// in SQLite, and a fake-async widget test never lets a SQLite read finish. So
// this test runs the same calls on the real event loop against a real SQLite
// file in a temp dir, and times one "switch" worth of them.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/model_cache_service.dart';

import '../support/kv_cache_test_env.dart';
import 'perf_support.dart';

/// Catalogue reads one mount of the chat screen makes.
const int _catalogueReadsPerSwitch = 5;

/// Messages per thread; every third answer carries tool calls.
const int _messagesPerThread = 80;

const int _switches = 9;

/// The median data work of one switch must stay under this. Measured on the
/// development machine (JIT, like `flutter test`): 9.6 ms before the caches,
/// 1.7 ms after them. The ceiling (under 9.6, ~4.7x the median) leaves room
/// for a loaded CI runner and still
/// catches the return of a full catalogue decode on every read.
const double _dataCeilingMs = 8;

List<Map<String, dynamic>> _catalogue() => <Map<String, dynamic>>[
  for (int i = 0; i < 450; i++)
    <String, dynamic>{
      'id': 'vendor$i/model-$i',
      'name': 'Vendor $i: Model $i',
      'description':
          'A model with a long description, as the real catalogue has. ' * 4,
      'context_length': 131072,
      'pricing': <String, dynamic>{'prompt': '0.0000002', 'completion': '1e-6'},
      'supported_parameters': <String>['tools', 'reasoning', 'temperature'],
      'providers': <Map<String, dynamic>>[
        for (int p = 0; p < 3; p++)
          <String, dynamic>{'slug': 'provider$p', 'price': p * 0.1},
      ],
    },
];

List<Map<String, String>> _thread() => <Map<String, String>>[
  for (int i = 0; i < _messagesPerThread; i++)
    if (i.isEven)
      <String, String>{'sender': 'user', 'text': 'ask $i'}
    else
      <String, String>{
        'sender': 'ai',
        'text': 'answer $i',
        if (i % 3 == 0)
          'toolCalls': jsonEncode(<Map<String, dynamic>>[
            for (int c = 0; c < 3; c++)
              <String, dynamic>{
                'id': 'call-$i-$c',
                'name': 'shell',
                'arguments': <String, dynamic>{'command': 'ls $i $c'},
                'result': 'file\n' * 20,
                'status': 'completed',
                'startedAt': '2026-09-20T10:00:00.000Z',
                'completedAt': '2026-09-20T10:00:01.000Z',
              },
          ]),
      },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await useTempKvCache();
    ModelCacheService.debugClearMemo();
  });

  tearDown(() async => disposeTempKvCache(tempDir));

  test('the data work of one agent switch: catalogue reads and tool-call '
      'recovery', () async {
    final catalogue = _catalogue();
    await ModelCacheService.saveAvailableModels(catalogue);
    final catalogueBytes = jsonEncode(catalogue).length;
    final threads = <List<Map<String, String>>>[
      for (int t = 0; t < 4; t++) _thread(),
    ];

    Future<void> oneSwitch(int thread) async {
      for (int r = 0; r < _catalogueReadsPerSwitch; r++) {
        final models = await ModelCacheService.loadAvailableModels();
        expect(models, hasLength(catalogue.length));
      }
      // A load maps the stored rows to fresh raw maps and heals them.
      for (final message in threads[thread]) {
        ChatUiHelpers.finalizeStaleToolCallsInRawMessage(
          Map<String, String>.of(message),
        );
      }
    }

    // Warm-up: JIT, the SQLite handle, and the first fill of every cache.
    for (int t = 0; t < 4; t++) {
      await oneSwitch(t);
    }

    final samples = <double>[];
    for (int s = 0; s < _switches; s++) {
      final watch = Stopwatch()..start();
      await oneSwitch(s % 4);
      samples.add(watch.elapsedMicroseconds / 1000);
    }

    PerfTable('agent switch: data work before the first row')
      ..add(
        'catalogue x$_catalogueReadsPerSwitch + recovery of '
        '$_messagesPerThread msgs',
        samples,
        note: '${(catalogueBytes / 1024).toStringAsFixed(0)} KiB catalogue',
      )
      ..report();

    expect(
      median(samples),
      lessThan(_dataCeilingMs),
      reason:
          'the data work of one switch took '
          '${median(samples).toStringAsFixed(1)} ms (median)',
    );
  });
}
