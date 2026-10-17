// Local emulator of the hosted chuk API (api.chuk.chat).
//
// It speaks the same wire protocol as the real server, as the Flutter client
// uses it, so the app and the tests can run offline. The real server code is
// in the api_server repository (main.py, routers/ai/multiplex.py,
// routers/ai/chat_ws.py, routers/ai/brave.py, routers/ai/crawl.py,
// routers/ai/images.py, routers/billing/user.py).
//
// All state is in memory. Any Bearer token is accepted; nothing is checked
// against Supabase. See docs/API_EMULATOR.md.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'src/canned_tools.dart' as tools;
import 'src/fixtures.dart';
import 'src/script.dart';

export 'src/script.dart'
    show ScriptStep, ScriptTurn, parseScript, defaultTurn, splitIntoChunks;

/// Default body of GET /v1/user/status (shape of UserStatusResponse).
Map<String, Object?> defaultUserStatus() => {
  'has_subscription': true,
  'current_plan': 'plus',
  'credits_remaining': 100.0,
  'subscription_status': 'active',
  'free_messages_remaining': 10,
  'free_messages_total': 10,
};

/// Starts the emulator and returns it once it listens.
///
/// [port] 0 picks a free port; read it from [ChukEmulator.port].
/// [chunkDelay] is the pause between two streamed frames of a chat turn.
Future<ChukEmulator> startEmulator({
  int port = 0,
  Object? address,
  Duration chunkDelay = Duration.zero,
  bool quiet = true,
}) async {
  final emulator = ChukEmulator._(chunkDelay: chunkDelay, quiet: quiet);
  final server = await shelf_io.serve(
    emulator.handler,
    address ?? InternetAddress.loopbackIPv4,
    port,
  );
  emulator._server = server;
  return emulator;
}

/// A running emulator. Created by [startEmulator].
class ChukEmulator {
  ChukEmulator._({required this.chunkDelay, required this.quiet});

  /// Pause between two streamed frames of a chat turn.
  final Duration chunkDelay;

  /// When false, each request is printed to stdout.
  final bool quiet;

  late final HttpServer _server;

  /// The underlying dart:io server.
  HttpServer get server => _server;

  /// The port the emulator listens on.
  int get port => _server.port;

  /// HTTP base URL, for example `http://127.0.0.1:8787`. Pass it to the app as
  /// `--dart-define=API_BASE_URL=...`.
  String get baseUrl {
    final host = _server.address.isLoopback
        ? '127.0.0.1'
        : _server.address.address;
    return 'http://$host:$port';
  }

  final List<ScriptTurn> _queuedTurns = [];
  final List<Map<String, Object?>> _requests = [];
  final Map<String, Map<String, Object?>> _artifacts = {};
  final Set<WebSocketChannel> _sockets = {};
  Map<String, Object?> _userStatus = defaultUserStatus();
  int _sequence = 0;

  /// The models served by GET /v1/models_info. Tests may change the list.
  List<Map<String, Object?>> models = _decodeModels();

  /// The request log, oldest first. Each entry is a JSON-safe map.
  List<Map<String, Object?>> get requests => List.unmodifiable(_requests);

  /// The number of scripted turns that are not used yet.
  int get queuedTurns => _queuedTurns.length;

  /// Queues scripted turns. Each chat request uses the next turn.
  void enqueueTurns(List<ScriptTurn> turns) => _queuedTurns.addAll(turns);

  /// Queues one scripted turn given as JSON steps.
  void script(List<Map<String, Object?>> steps) =>
      _queuedTurns.addAll(parseScript(steps));

  /// Clears the script queue, the request log, artifacts and user status.
  void reset() {
    _queuedTurns.clear();
    _requests.clear();
    _artifacts.clear();
    _userStatus = defaultUserStatus();
    models = _decodeModels();
    _sequence = 0;
  }

  /// Stops the server and closes open sockets.
  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      // A peer that never answers the close frame must not block shutdown.
      await socket.sink.close().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
    }
    _sockets.clear();
    await _server.close(force: true);
  }

  /// The model catalogue. The fixture keeps the real shape, but its icon
  /// URLs point to production, so they are removed here: an offline run must
  /// not load images from api.chuk.chat, and a screenshot must not depend on
  /// the network.
  static List<Map<String, Object?>> _decodeModels() =>
      (jsonDecode(modelsInfoJson) as List).map((m) {
        final Map<String, Object?> model = Map<String, Object?>.from(m as Map)
          ..['icon_url'] = null;
        final Object? providers = model['providers'];
        if (providers is List) {
          model['providers'] = <Map<String, Object?>>[
            for (final Object? p in providers)
              Map<String, Object?>.from(p! as Map)..['icon_url'] = null,
          ];
        }
        return model;
      }).toList();

  // -------------------------------------------------------------------------
  // HTTP
  // -------------------------------------------------------------------------

  late final Handler _v2Socket = webSocketHandler(
    (WebSocketChannel ws, String? _) => _MultiplexSocket(this, ws).run(),
  );
  late final Handler _v1Socket = webSocketHandler(
    (WebSocketChannel ws, String? _) => _LegacyChatSocket(this, ws).run(),
  );

  /// The shelf handler. Exposed so a test can mount it elsewhere.
  Handler get handler => (Request request) async {
    final path = '/${request.url.path}';
    if (request.method == 'OPTIONS') return _cors(Response.ok(''));
    if (path == '/v2/ws') return _v2Socket(request);
    if (path == '/v1/ai/chat/ws') return _v1Socket(request);

    final bodyBytes = await request.read().expand((b) => b).toList();
    final bodyText = utf8.decode(bodyBytes, allowMalformed: true);
    final body = _decodeBody(request, bodyText);
    if (!path.startsWith('/__emulator/')) {
      _log({
        'transport': 'http',
        'method': request.method,
        'path': path,
        if (request.url.query.isNotEmpty) 'query': request.url.queryParameters,
        'auth': _hasBearer(request),
        if (bodyText.isNotEmpty) 'body': _trimForLog(body ?? bodyText),
      });
    }
    try {
      return _cors(await _route(request, path, body));
    } on tools.ToolInputError catch (e) {
      return _cors(_json({'error': e.detail}, status: 400));
    } on FormatException catch (e) {
      return _cors(_json({'error': e.message}, status: 400));
    }
  };

  Future<Response> _route(Request request, String path, Object? body) async {
    final method = request.method;
    final payload = body is Map
        ? body.map((k, v) => MapEntry(k.toString(), v))
        : <String, Object?>{};
    final base = _requestBase(request);

    // Control endpoints.
    if (path.startsWith('/__emulator/')) {
      switch ('$method $path') {
        case 'POST /__emulator/reset':
          reset();
          return _json({'ok': true});
        case 'POST /__emulator/script':
          final turns = parseScript(body);
          if (request.url.queryParameters['replace'] == '1') {
            _queuedTurns.clear();
          }
          _queuedTurns.addAll(turns);
          return _json({'queued': _queuedTurns.length});
        case 'GET /__emulator/script':
          return _json({
            'queued': _queuedTurns.length,
            'turns': [
              for (final turn in _queuedTurns)
                [for (final step in turn) step.toJson()],
            ],
          });
        case 'GET /__emulator/requests':
          final filter = request.url.queryParameters['path'];
          return _json({
            'requests': filter == null
                ? _requests
                : _requests.where((r) => r['path'] == filter).toList(),
          });
        case 'POST /__emulator/user_status':
          _userStatus = {..._userStatus, ...payload};
          return _json(_userStatus);
      }
      return _json({'error': 'unknown control endpoint'}, status: 404);
    }

    // Public endpoints without auth.
    switch ('$method $path') {
      case 'GET /':
        return _json({'message': 'Welcome to the API'});
      case 'GET /health':
        return _json({
          'status': 'ok',
          'version': 'emulator',
          'git_sha': 'emulator',
          'emulator': true,
        });
      case 'GET /v1/version':
        return _json({
          'version': 'emulator',
          'release_date': '2026-01-01',
          'git_sha': 'emulator',
          'deployed_at': '2026-01-01T00:00:00Z',
        });
      case 'GET /v1/models_info':
        return _json(models);
    }
    if (method == 'GET' && path.startsWith('/v1/ai/image/file/')) {
      return Response.ok(
        base64Decode(fixedPngBase64),
        headers: {'content-type': 'image/png'},
      );
    }
    if (method == 'GET' && path.startsWith('/a/')) {
      final artifact = _artifacts[path.substring(3)];
      if (artifact == null) return _json({'error': 'not_found'}, status: 404);
      return Response.ok(
        artifact['html'] as String,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }

    // Everything below needs a Bearer token (any value).
    if (!_hasBearer(request)) {
      return _json({'detail': 'Not authenticated'}, status: 401);
    }

    switch ('$method $path') {
      case 'GET /v1/ai/models':
        return _json(models);
      case 'GET /v1/user/status':
        return _json(_userStatus);
      case 'POST /v1/tools/brave/search':
        return _json(tools.braveSearch(payload));
      case 'POST /v1/tools/brave/images':
        return _json(tools.braveImages(payload, baseUrl: base));
      case 'POST /v1/tools/brave/news':
        return _json(tools.braveNews(payload));
      case 'POST /v1/tools/brave/rich':
        return _json(tools.braveRich(payload));
      case 'POST /v1/tools/brave/places':
        return _json(tools.bravePlaces(payload));
      case 'POST /v1/tools/crawl':
        return _json(tools.crawl(payload));
      case 'POST /v1/ai/image/generate':
        return _json(
          tools.imageGenerate(payload, baseUrl: base, sequence: ++_sequence),
        );
      case 'POST /v1/artifacts':
        return _json(_saveArtifact(null, payload, base));
    }
    if (path.startsWith('/v1/artifacts/')) {
      final id = Uri.decodeComponent(path.substring('/v1/artifacts/'.length));
      if (!_artifacts.containsKey(id)) {
        return _json({'error': 'not_found'}, status: 404);
      }
      if (method == 'PUT') return _json(_saveArtifact(id, payload, base));
      if (method == 'GET') return _json(_artifactView(id, base));
    }
    return _json({'detail': 'Not Found'}, status: 404);
  }

  Map<String, Object?> _saveArtifact(
    String? id,
    Map<String, Object?> payload,
    String base,
  ) {
    final html = payload['html']?.toString() ?? '';
    if (html.trim().isEmpty) throw tools.ToolInputError('html is required');
    final publicId = id ?? 'art${++_sequence}';
    _artifacts[publicId] = {
      'html': html,
      'title': payload['title']?.toString() ?? _artifacts[publicId]?['title'],
    };
    return _artifactView(publicId, base);
  }

  Map<String, Object?> _artifactView(String id, String base) => {
    'public_id': id,
    'url': '$base/a/$id',
    'download_url': '$base/a/$id?download=1',
    'title': _artifacts[id]?['title'],
  };

  /// Runs a canned server tool by its mux name. Returns null for an unknown
  /// tool.
  Map<String, Object?>? _runTool(
    String name,
    Map<String, Object?> payload,
    String base,
  ) {
    switch (name) {
      case 'brave_search':
        return tools.braveSearch(payload);
      case 'brave_images':
        return tools.braveImages(payload, baseUrl: base);
      case 'brave_news':
        return tools.braveNews(payload);
      case 'brave_rich':
        return tools.braveRich(payload);
      case 'brave_places':
      case 'places_search':
      case 'restaurants_search':
        return tools.bravePlaces(payload);
      case 'crawl':
        return tools.crawl(payload);
      case 'image_generate':
        return tools.imageGenerate(
          payload,
          baseUrl: base,
          sequence: ++_sequence,
        );
    }
    return null;
  }

  ScriptTurn _nextTurn(String message) =>
      _queuedTurns.isEmpty ? defaultTurn(message) : _queuedTurns.removeAt(0);

  void _log(Map<String, Object?> entry) {
    final full = {
      'seq': _requests.length + 1,
      'time': DateTime.now().toUtc().toIso8601String(),
      ...entry,
    };
    _requests.add(full);
    if (!quiet) {
      stdout.writeln(
        '[emulator] ${entry['transport']} ${entry['method'] ?? entry['type']} '
        '${entry['path']}${entry['tool'] != null ? ' ${entry['tool']}' : ''}',
      );
    }
  }

  String _wsBase(Uri requested) =>
      '${requested.scheme == 'wss' || requested.scheme == 'https' ? 'https' : 'http'}'
      '://${requested.host}:${requested.port}';

  String _requestBase(Request request) => _wsBase(request.requestedUri);

  static bool _hasBearer(Request request) {
    final header = request.headers['authorization'] ?? '';
    return header.toLowerCase().startsWith('bearer ') &&
        header.substring(7).trim().isNotEmpty;
  }

  static Object? _decodeBody(Request request, String text) {
    if (text.isEmpty) return null;
    final type = request.headers['content-type'] ?? '';
    if (type.startsWith('multipart/form-data')) {
      return _parseMultipart(type, text);
    }
    // JSON first, whatever the content type says: `curl -d '{...}'` sends
    // JSON labelled as a form.
    try {
      return jsonDecode(text);
    } on FormatException {
      if (type.startsWith('application/x-www-form-urlencoded')) {
        return Uri.splitQueryString(text);
      }
      return null;
    }
  }

  static Map<String, Object?> _parseMultipart(String contentType, String text) {
    final match = RegExp(r'boundary="?([^";]+)"?').firstMatch(contentType);
    if (match == null) return {};
    final fields = <String, Object?>{};
    for (final part in text.split('--${match.group(1)}')) {
      final split = part.indexOf('\r\n\r\n');
      if (split < 0) continue;
      final headers = part.substring(0, split);
      final name = RegExp(r'name="([^"]*)"').firstMatch(headers)?.group(1);
      if (name == null) continue;
      var value = part.substring(split + 4);
      if (value.endsWith('\r\n')) value = value.substring(0, value.length - 2);
      fields[name] = value;
    }
    return fields;
  }

  static Response _json(Object? body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  static Response _cors(Response response) => response.change(
    headers: {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': '*',
      'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
    },
  );
}

/// Shortens long strings (base64 images, big prompts) in a logged value.
Object? _trimForLog(Object? value) {
  const limit = 4096;
  if (value is String) {
    return value.length <= limit
        ? value
        : '${value.substring(0, limit)}...[${value.length} chars]';
  }
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), _trimForLog(v)));
  }
  if (value is List) return value.map(_trimForLog).toList();
  return value;
}

// ---------------------------------------------------------------------------
// Chat turns (shared by /v2/ws and /v1/ai/chat/ws)
// ---------------------------------------------------------------------------

typedef _Emit = Future<void> Function(String kind, Object? data, String? code);

enum _TurnEnd { completed, failed, cancelled, disconnected }

/// Plays one turn and sends its frames through [emit]. Does not send `done`;
/// the caller does, because the two protocols end a turn differently.
Future<_TurnEnd> _playTurn({
  required ChukEmulator emulator,
  required Map<String, Object?> payload,
  required _Emit emit,
  required bool Function() isCancelled,
  required Future<void> Function() disconnect,
}) async {
  final message = payload['message']?.toString() ?? '';
  final history = payload['history'];
  if (message.trim().isEmpty && (history is! List || history.isEmpty)) {
    await emit('error', 'Message cannot be empty', 'invalid_payload');
    return _TurnEnd.failed;
  }
  final modelId = payload['model_id']?.toString() ?? '';
  final providerSlug = payload['provider_slug']?.toString() ?? '';
  final model = emulator.models.firstWhere(
    (m) => m['id'] == modelId,
    orElse: () => {'id': modelId, 'name': modelId},
  );
  await emit('meta', {
    'model': {
      'id': modelId,
      'name': model['name'],
      'icon_url': model['icon_url'],
    },
    if (providerSlug.isNotEmpty)
      'provider': {
        'slug': providerSlug,
        'name': providerSlug,
        'icon_url': null,
      },
  }, null);

  final turn = emulator._nextTurn(message);
  var usageSent = false;
  var outputChunks = 0;
  var toolIndex = 0;

  Future<bool> pause() async {
    await Future<void>.delayed(emulator.chunkDelay);
    return isCancelled();
  }

  for (var i = 0; i < turn.length; i++) {
    if (isCancelled()) return _TurnEnd.cancelled;
    final step = turn[i];
    switch (step.type) {
      case 'text':
      case 'reasoning':
        final kind = step.type == 'text' ? 'content' : 'reasoning';
        for (final chunk in step.textChunks) {
          if (await pause()) return _TurnEnd.cancelled;
          await emit(kind, chunk, null);
          outputChunks++;
        }
      case 'tool_call':
        // Consecutive tool_call steps are one assistant message with parallel
        // calls; the server flushes them together in one frame.
        final calls = <Map<String, Object?>>[];
        var j = i;
        while (j < turn.length && turn[j].type == 'tool_call') {
          final call = turn[j];
          calls.add({
            'id': call.data['id']?.toString() ?? 'call_emu_${toolIndex++}',
            'type': 'function',
            'function': {
              'name': call.data['name'],
              'arguments': call.toolArguments,
            },
          });
          j++;
        }
        i = j - 1;
        if (await pause()) return _TurnEnd.cancelled;
        await emit('tool_calls', calls, null);
        outputChunks++;
      case 'usage':
        final usage = Map<String, Object?>.from(step.data)..remove('type');
        await emit('usage', usage, null);
        usageSent = true;
      case 'error':
        await emit(
          'error',
          step.data['message'],
          step.data['code']?.toString() ?? 'upstream_status',
        );
        return _TurnEnd.failed;
      case 'disconnect':
        await disconnect();
        return _TurnEnd.disconnected;
      case 'delay':
        await Future<void>.delayed(
          Duration(milliseconds: (step.data['ms'] as num).toInt()),
        );
    }
  }
  if (!usageSent) {
    final prompt = splitIntoChunks(message).length;
    await emit('usage', {
      'prompt_tokens': prompt,
      'completion_tokens': outputChunks,
      'total_tokens': prompt + outputChunks,
    }, null);
  }
  return _TurnEnd.completed;
}

/// One /v2/ws connection: auth handshake, then multiplexed chat and tool
/// requests keyed by `req_id` (routers/ai/multiplex.py).
class _MultiplexSocket {
  _MultiplexSocket(this.emulator, this.ws);

  final ChukEmulator emulator;
  final WebSocketChannel ws;
  final Set<String> _inflight = {};
  final Set<String> _cancelled = {};
  bool _authed = false;
  bool _closed = false;

  String get _base => 'http://127.0.0.1:${emulator.port}';

  void run() {
    emulator._sockets.add(ws);
    ws.stream.listen(
      _onRaw,
      onDone: () {
        _closed = true;
        emulator._sockets.remove(ws);
      },
      onError: (Object _) {
        _closed = true;
        emulator._sockets.remove(ws);
      },
      cancelOnError: true,
    );
  }

  void _send(Map<String, Object?> frame) {
    if (_closed) return;
    ws.sink.add(jsonEncode(frame));
  }

  Future<void> _emit(String reqId, String kind, Object? data, String? code) {
    final frame = <String, Object?>{'req_id': reqId, 'kind': kind};
    if (kind == 'error') {
      frame['detail'] = data is String ? data : '$data';
      if (code != null) frame['code'] = code;
    } else if (kind != 'done') {
      frame['data'] = data;
    }
    _send(frame);
    return Future.value();
  }

  Future<void> _disconnect() async {
    _closed = true;
    emulator._sockets.remove(ws);
    await ws.sink.close(4000, 'emulator disconnect');
  }

  Future<void> _onRaw(dynamic raw) async {
    if (raw is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }

    if (!_authed) {
      if (decoded is! Map || decoded['type'] != 'auth') {
        _send({'type': 'auth_error', 'detail': 'First frame must be auth'});
        await _disconnect();
        return;
      }
      final token = decoded['token'];
      if (token is! String || token.isEmpty) {
        _send({'type': 'auth_error', 'detail': 'Missing token'});
        await _disconnect();
        return;
      }
      _authed = true;
      emulator._log({'transport': 'ws', 'path': '/v2/ws', 'type': 'auth'});
      _send({'type': 'auth_ok'});
      return;
    }

    if (decoded is! Map) {
      _send({
        'type': 'error',
        'detail': decoded == null ? 'Invalid JSON' : 'Frame must be an object',
        'code': decoded == null ? 'invalid_json' : 'invalid_frame',
      });
      return;
    }
    final frame = decoded.map((k, v) => MapEntry(k.toString(), v));
    final type = frame['type'];
    if (type == 'ping') {
      _send({'type': 'pong'});
      return;
    }
    if (type == 'auth_refresh') {
      emulator._log({
        'transport': 'ws',
        'path': '/v2/ws',
        'type': 'auth_refresh',
      });
      final token = frame['token'];
      if (token is! String || token.isEmpty) {
        _send({'type': 'auth_refresh_failed', 'detail': 'Missing token'});
      } else {
        final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        _send({'type': 'auth_refreshed', 'expires_at': expires});
      }
      return;
    }

    final reqId = frame['req_id'];
    if (reqId is! String || reqId.isEmpty || reqId.length > 64) {
      _send({
        'type': 'error',
        'detail': 'Invalid req_id',
        'code': 'invalid_req_id',
      });
      return;
    }
    if (type == 'cancel') {
      emulator._log({
        'transport': 'ws',
        'path': '/v2/ws',
        'type': 'cancel',
        'req_id': reqId,
      });
      if (_inflight.contains(reqId)) _cancelled.add(reqId);
      return;
    }
    final payload = frame['payload'] is Map
        ? (frame['payload'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, Object?>{};
    payload.remove('token');
    emulator._log({
      'transport': 'ws',
      'path': '/v2/ws',
      'type': type,
      'req_id': reqId,
      if (frame['tool'] != null) 'tool': frame['tool'],
      'payload': _trimForLog(payload),
    });

    if (type != 'chat' && type != 'tool') {
      await _emit(reqId, 'error', 'Unknown type: $type', 'invalid_type');
      await _emit(reqId, 'done', null, null);
      return;
    }
    if (_inflight.contains(reqId)) {
      await _emit(reqId, 'error', 'Duplicate req_id', 'duplicate_req_id');
      await _emit(reqId, 'done', null, null);
      return;
    }
    _inflight.add(reqId);
    try {
      if (type == 'chat') {
        await _runChat(reqId, payload);
      } else {
        await _runTool(reqId, frame['tool']?.toString() ?? '', payload);
      }
    } finally {
      _inflight.remove(reqId);
      _cancelled.remove(reqId);
    }
  }

  Future<void> _runChat(String reqId, Map<String, Object?> payload) async {
    final end = await _playTurn(
      emulator: emulator,
      payload: payload,
      emit: (kind, data, code) => _emit(reqId, kind, data, code),
      isCancelled: () => _closed || _cancelled.contains(reqId),
      disconnect: _disconnect,
    );
    if (end == _TurnEnd.disconnected) return;
    if (end == _TurnEnd.cancelled) {
      await _emit(reqId, 'error', 'Request cancelled.', 'cancelled');
    }
    await _emit(reqId, 'done', null, null);
  }

  Future<void> _runTool(
    String reqId,
    String name,
    Map<String, Object?> payload,
  ) async {
    if (name.isEmpty) {
      await _emit(reqId, 'error', 'Missing tool name', 'invalid_tool');
    } else {
      try {
        final result = emulator._runTool(name, payload, _base);
        if (result == null) {
          await _emit(reqId, 'error', "Unknown tool: '$name'", 'unknown_tool');
        } else {
          await _emit(reqId, 'result', result, null);
        }
      } on tools.ToolInputError catch (e) {
        await _emit(reqId, 'error', e.detail, 'http_400');
      }
    }
    await _emit(reqId, 'done', null, null);
  }
}

/// One /v1/ai/chat/ws connection: the legacy protocol older app builds use.
/// Every request carries its own `token`; frames are flat objects such as
/// `{"content": "..."}` and `{"done": true}` (routers/ai/chat_ws.py).
class _LegacyChatSocket {
  _LegacyChatSocket(this.emulator, this.ws);

  final ChukEmulator emulator;
  final WebSocketChannel ws;
  bool _closed = false;

  void run() {
    emulator._sockets.add(ws);
    ws.stream.listen(
      _onRaw,
      onDone: () {
        _closed = true;
        emulator._sockets.remove(ws);
      },
      onError: (Object _) {
        _closed = true;
        emulator._sockets.remove(ws);
      },
      cancelOnError: true,
    );
  }

  void _send(Map<String, Object?> frame) {
    if (_closed) return;
    ws.sink.add(jsonEncode(frame));
  }

  Future<void> _onRaw(dynamic raw) async {
    if (raw is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      _send({'error': 'Invalid JSON'});
      return;
    }
    if (decoded is! Map) {
      _send({'error': 'Invalid JSON'});
      return;
    }
    final payload = decoded.map((k, v) => MapEntry(k.toString(), v));
    final token = payload.remove('token');
    emulator._log({
      'transport': 'ws',
      'path': '/v1/ai/chat/ws',
      'type': 'chat',
      'payload': _trimForLog(payload),
    });
    if (token is! String || token.isEmpty) {
      _send({'error': 'Missing authentication token'});
      return;
    }
    final end = await _playTurn(
      emulator: emulator,
      payload: payload,
      emit: (kind, data, code) async {
        _send(kind == 'error' ? {'error': data} : {kind: data});
      },
      isCancelled: () => _closed,
      disconnect: () async {
        _closed = true;
        emulator._sockets.remove(ws);
        await ws.sink.close(4000, 'emulator disconnect');
      },
    );
    if (end == _TurnEnd.completed) _send({'done': true});
  }
}
