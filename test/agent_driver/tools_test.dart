// Tool layer of the agent driver, against a fake app.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/agent_driver/bin/agent_driver.dart' show substituteVars;
import '../../tool/agent_driver/src/tools.dart';
import 'fake_app.dart';

void main() {
  late FakeApp app;
  late AgentTools tools;
  late Directory shots;

  setUp(() {
    // Inside the repository, not in /tmp.
    final Directory base = Directory('_scratch/test_agent_driver')
      ..createSync(recursive: true);
    shots = base.createTempSync('shots_');
    app = FakeApp();
    tools = AgentTools(app, shotsDir: shots.path);
  });

  tearDown(() {
    if (shots.existsSync()) shots.deleteSync(recursive: true);
  });

  test('every tool has a name, a description and an object schema', () {
    final Set<String> names = <String>{};
    for (final Map<String, Object?> t in toolDefinitions) {
      expect(names.add(t['name']! as String), isTrue);
      expect((t['description']! as String).isNotEmpty, isTrue);
      expect((t['inputSchema']! as Map<String, Object?>)['type'], 'object');
    }
    expect(
      names,
      containsAll(<String>[
        'app_start',
        'app_stop',
        'screenshot',
        'read_state',
        'tap',
        'tap_at',
        'enter_text',
        'wait_for',
      ]),
    );
  });

  test('app_start passes headless and fresh, with safe defaults', () async {
    final ToolResult r = await tools.call('app_start', <String, Object?>{});
    expect(r.isError, isFalse);
    final Map<String, Object?> json =
        jsonDecode(r.text) as Map<String, Object?>;
    expect(json['headless'], isTrue);
    expect(json['fresh'], isTrue);
  });

  test('tap sends a hit-testable Agent finder to the driver', () async {
    final ToolResult r = await tools.call('tap', <String, Object?>{
      'by': 'semantics_id',
      'value': 'login_submit_button',
    });
    expect(r.isError, isFalse);
    expect(app.driverCalls.single, <String, String>{
      'command': 'tap',
      'timeout': '10000',
      'finderType': 'Agent',
      'by': 'semantics_id',
      'value': 'login_submit_button',
      'index': '0',
      'hittable': 'true',
    });
  });

  test(
    'enter_text with a finder waits, focuses the field, then types',
    () async {
      await tools.call('enter_text', <String, Object?>{
        'by': 'text',
        'value': 'Ask me anything',
        'text': 'hello',
      });
      expect(
        app.driverCalls.map((Map<String, String> c) => c['command']),
        <String>['waitFor', 'enter_text'],
      );
      expect(app.extensionCalls, <String>['ext.chuk.agent.focus']);
      expect(app.extensionArgs.single['value'], 'Ask me anything');
      expect(app.driverCalls.last['text'], 'hello');
    },
  );

  test('enter_text without a finder only types', () async {
    await tools.call('enter_text', <String, Object?>{'text': 'x'});
    expect(app.driverCalls.single['command'], 'enter_text');
  });

  test('wait_for with absent uses waitForAbsent and the timeout', () async {
    await tools.call('wait_for', <String, Object?>{
      'by': 'text',
      'value': 'Loading',
      'absent': true,
      'timeout_ms': 500,
    });
    expect(app.driverCalls.single['command'], 'waitForAbsent');
    expect(app.driverCalls.single['timeout'], '500');
    expect(app.driverCalls.single['hittable'], 'false');
  });

  test('scroll converts milliseconds to microseconds', () async {
    await tools.call('scroll', <String, Object?>{
      'by': 'type',
      'value': 'ListView',
      'dx': 0,
      'dy': -300,
    });
    final Map<String, String> c = app.driverCalls.single;
    expect(c['command'], 'scroll');
    expect(c['dy'], '-300.0');
    expect(c['duration'], '300000');
  });

  test('bad arguments give an error result, not an exception', () async {
    final ToolResult a = await tools.call('tap', <String, Object?>{
      'by': 'xpath',
      'value': '//x',
    });
    expect(a.isError, isTrue);
    final ToolResult b = await tools.call('tap', <String, Object?>{
      'by': 'text',
      'value': 'x',
      'index': -1,
    });
    expect(b.isError, isTrue);
    final ToolResult c = await tools.call('nope', <String, Object?>{});
    expect(c.isError, isTrue);
    expect(app.driverCalls, isEmpty);
  });

  test('a driver error becomes an error result', () async {
    app.failDriverWith = 'Timeout while executing tap';
    final ToolResult r = await tools.call('tap', <String, Object?>{
      'by': 'text',
      'value': 'Missing',
    });
    expect(r.isError, isTrue);
    expect(r.text, contains('Timeout while executing tap'));
  });

  test('screenshot writes the PNG and returns it inline', () async {
    final ToolResult r = await tools.call('screenshot', <String, Object?>{
      'name': 'home',
    });
    expect(r.isError, isFalse);
    final File f = File(p.join(shots.path, 'home.png'));
    expect(f.existsSync(), isTrue);
    expect(f.readAsBytesSync().sublist(1, 4), utf8.encode('PNG'));
    expect(r.content.last['type'], 'image');
    expect(r.content.last['mimeType'], 'image/png');
  });

  test('screenshot refuses a name with a path in it', () async {
    final ToolResult r = await tools.call('screenshot', <String, Object?>{
      'name': '../../evil',
    });
    expect(r.isError, isTrue);
    expect(app.extensionCalls, isEmpty);
  });

  test('screenshot without a name counts up', () async {
    await tools.call('screenshot', <String, Object?>{'inline': false});
    await tools.call('screenshot', <String, Object?>{'inline': false});
    expect(File(p.join(shots.path, 'shot_01.png')).existsSync(), isTrue);
    expect(File(p.join(shots.path, 'shot_02.png')).existsSync(), isTrue);
  });

  test('read_state and tap_at call the app extensions', () async {
    final ToolResult s = await tools.call('read_state', <String, Object?>{
      'include_hidden': true,
    });
    expect(s.text, contains('"Hi"'));
    await tools.call('tap_at', <String, Object?>{'x': 10, 'y': 20.5});
    expect(app.extensionCalls, <String>[
      'ext.chuk.agent.state',
      'ext.chuk.agent.tapAt',
    ]);
    expect(app.extensionArgs.first['includeHidden'], 'true');
    expect(app.extensionArgs.last, <String, String>{'x': '10', 'y': '20.5'});
  });

  test('substituteVars fills placeholders from the defines', () {
    final Map<String, Object?> out = substituteVars(
      <String, Object?>{'text': '{{E2E_EMAIL}}', 'n': 3, 'v': '{{UNKNOWN}}'},
      <String, String>{'E2E_EMAIL': 'e2e@example.test'},
    );
    expect(out, <String, Object?>{
      'text': 'e2e@example.test',
      'n': 3,
      'v': '{{UNKNOWN}}',
    });
  });
}
