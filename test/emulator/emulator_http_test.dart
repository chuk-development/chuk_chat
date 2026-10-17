// HTTP side of the chuk API emulator (tool/emulator). Starts it in-process.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../tool/emulator/emulator.dart';

void main() {
  late ChukEmulator emu;
  const auth = {
    'Authorization': 'Bearer any-token',
    'Content-Type': 'application/json',
  };

  setUp(() async {
    emu = await startEmulator(port: 0);
  });

  tearDown(() async {
    await emu.close();
  });

  Uri url(String path) => Uri.parse('${emu.baseUrl}$path');

  Future<Object?> getJson(String path, {Map<String, String>? headers}) async {
    final res = await http.get(url(path), headers: headers);
    expect(res.statusCode, 200, reason: res.body);
    return jsonDecode(res.body);
  }

  Future<Map<String, dynamic>> postJson(String path, Object body) async {
    final res = await http.post(
      url(path),
      headers: auth,
      body: jsonEncode(body),
    );
    expect(res.statusCode, 200, reason: res.body);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  test('health and version answer without auth', () async {
    final health = await getJson('/health') as Map;
    expect(health['status'], 'ok');
    final version = await getJson('/v1/version') as Map;
    expect(version.keys, containsAll(['version', 'git_sha', 'deployed_at']));
  });

  test('models_info has no icon URL that leaves the machine', () async {
    final models = await getJson('/v1/models_info') as List;
    for (final m in models.cast<Map>()) {
      expect(m['icon_url'], isNull, reason: '${m['id']}');
      for (final p in (m['providers'] as List? ?? const []).cast<Map>()) {
        expect(p['icon_url'], isNull, reason: '${m['id']} / ${p['slug']}');
      }
    }
  });

  test('models_info serves the real catalogue shape', () async {
    final models = await getJson('/v1/models_info') as List;
    final ids = models.map((m) => (m as Map)['id']).toList();
    expect(ids, contains('deepseek/deepseek-v4-flash-0731'));
    expect(ids, contains('z-ai/glm-5.3-flash'));
    final flash = models.cast<Map>().firstWhere(
      (m) => m['id'] == 'deepseek/deepseek-v4-flash-0731',
    );
    expect(flash['supports_tools'], isTrue);
    expect(flash['supports_reasoning'], isTrue);
    final providers = flash['providers'] as List;
    expect(providers, isNotEmpty);
    expect((providers.first as Map)['slug'], isA<String>());
    expect((providers.first as Map)['pricing'], isA<Map>());
  });

  test('auth: any Bearer token works, no token is 401', () async {
    final denied = await http.get(url('/v1/user/status'));
    expect(denied.statusCode, 401);
    final status = await getJson('/v1/user/status', headers: auth) as Map;
    expect(status.keys, containsAll(defaultUserStatus().keys));
    expect(status['has_subscription'], isTrue);
  });

  test('brave and crawl routes return canned results', () async {
    final search = await postJson('/v1/tools/brave/search', {
      'query': 'kiel',
      'count': 3,
    });
    expect(search['query'], 'kiel');
    expect(search['results'], hasLength(3));
    expect(
      (search['results'] as List).first,
      containsPair('url', isA<String>()),
    );

    final news = await postJson('/v1/tools/brave/news', {'query': 'kiel'});
    expect(news['results'], isNotEmpty);
    final places = await postJson('/v1/tools/brave/places', {'query': 'cafe'});
    expect(places['places'], isNotEmpty);
    final rich = await postJson('/v1/tools/brave/rich', {'query': 'weather'});
    expect(rich['vertical'], 'weather');

    final crawl = await postJson('/v1/tools/crawl', {
      'url': 'https://example.org/a',
    });
    expect(crawl['url'], 'https://example.org/a');
    expect(crawl['content'], contains('example.org/a'));
    final batch = await postJson('/v1/tools/crawl', {
      'urls': ['https://a.test', 'https://b.test'],
    });
    expect(batch['results'], hasLength(2));

    final missing = await http.post(
      url('/v1/tools/brave/search'),
      headers: auth,
      body: jsonEncode({'query': ''}),
    );
    expect(missing.statusCode, 400);
  });

  test('image generate (multipart form) returns a URL to a PNG', () async {
    final request = http.MultipartRequest('POST', url('/v1/ai/image/generate'))
      ..headers['Authorization'] = 'Bearer x'
      ..fields['model'] = 'turbo'
      ..fields['prompt'] = 'a red fox';
    final res = await http.Response.fromStream(await request.send());
    expect(res.statusCode, 200, reason: res.body);
    final body = jsonDecode(res.body) as Map;
    expect(body['prompt'], 'a red fox');
    final png = await http.get(Uri.parse(body['image_url'] as String));
    expect(png.headers['content-type'], 'image/png');
    expect(png.bodyBytes.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
  });

  test('artifacts can be created, updated and read', () async {
    final created = await postJson('/v1/artifacts', {
      'html': '<p>one</p>',
      'title': 'T',
    });
    final id = created['public_id'] as String;
    expect(created['url'], endsWith('/a/$id'));
    final updated = await http.put(
      url('/v1/artifacts/$id'),
      headers: auth,
      body: jsonEncode({'html': '<p>two</p>'}),
    );
    expect(updated.statusCode, 200);
    final page = await http.get(Uri.parse(created['url'] as String));
    expect(page.body, '<p>two</p>');
    final unknown = await http.put(
      url('/v1/artifacts/nope'),
      headers: auth,
      body: jsonEncode({'html': 'x'}),
    );
    expect(unknown.statusCode, 404);
  });

  test('control endpoints: request log, script queue, reset', () async {
    await http.get(url('/v1/models_info'));
    var log = await getJson('/__emulator/requests') as Map;
    expect(
      (log['requests'] as List).map((r) => (r as Map)['path']),
      contains('/v1/models_info'),
    );

    final queued = await http.post(
      url('/__emulator/script'),
      body: jsonEncode([
        {'type': 'text', 'text': 'hi'},
      ]),
    );
    expect(jsonDecode(queued.body), {'queued': 1});
    expect(emu.queuedTurns, 1);

    final bad = await http.post(
      url('/__emulator/script'),
      body: jsonEncode([
        {'type': 'nope'},
      ]),
    );
    expect(bad.statusCode, 400);

    await http.post(url('/__emulator/reset'));
    expect(emu.queuedTurns, 0);
    log = await getJson('/__emulator/requests') as Map;
    expect(log['requests'], isEmpty);
  });
}
