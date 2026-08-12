import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A self-contained LOCAL loopback relay plus a phone-style web page, built
/// only on `dart:io` (`HttpServer` + `WebSocketTransformer`). No extra pubspec
/// dependency is needed.
///
/// This is the local stand-in for the CoWork relay and the phone. A demo needs
/// no second device and no production server. You open the served page in a
/// browser tab and it behaves like a phone remote for an AI agent.
///
/// ## Not the real crypto path
///
/// The traffic here is PLAINTEXT JSON over one WebSocket. That is safe only
/// because it never leaves `127.0.0.1` (loopback). The real, end-to-end
/// encrypted wire path already exists and is tested. See
/// `cowork_frame.dart` and `cowork_frame_codec.dart`. Do NOT reimplement that
/// crypto here, and do NOT route real device traffic through this class.
///
/// ## Decoupling
///
/// This file does NOT import chat or tool-loop code. It only exposes streams
/// and callbacks. Something else wires it to the agent:
///  * [injectedMessages] emits the text a phone tab sent.
///  * [pushDelta], [pushToolCall], [pushToolResult], [pushDone], [pushError]
///    fan out agent activity to every connected phone tab.
///
/// ## JSON protocol
///
/// phone -> server:
///  * `{"type":"inject","text":"..."}`
///
/// server -> phone:
///  * `{"type":"delta","text":"..."}`
///  * `{"type":"tool","name":"...","args":"..."}`
///  * `{"type":"toolResult","name":"...","result":"..."}`
///  * `{"type":"done"}`
///  * `{"type":"error","message":"..."}`
class CoworkDemoServer {
  HttpServer? _server;

  /// Every open phone-tab socket. Broadcast targets.
  final Set<WebSocket> _sockets = <WebSocket>{};

  final StreamController<String> _injected =
      StreamController<String>.broadcast();

  /// Text that a phone tab sent with `{"type":"inject"}`.
  Stream<String> get injectedMessages => _injected.stream;

  /// True while the loopback server is listening.
  bool get isRunning => _server != null;

  /// Number of connected phone tabs. Useful for tests and status.
  int get connectionCount => _sockets.length;

  /// Start the loopback relay. Binds to `127.0.0.1` only, never `0.0.0.0`.
  ///
  /// [port] `0` lets the OS assign a free port. Returns the `http://` URL to
  /// open in a browser.
  Future<Uri> start({int port = 0}) async {
    if (_server != null) {
      return _httpUri();
    }
    // loopback only. Never bind a wildcard address for this demo relay.
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server = server;
    server.listen(_handleRequest, onError: (Object e) {
      if (kDebugMode) {
        debugPrint('CoworkDemoServer request error: ${e.runtimeType}');
      }
    });
    if (kDebugMode) {
      debugPrint('CoworkDemoServer listening on 127.0.0.1:${server.port}');
    }
    return _httpUri();
  }

  Uri _httpUri() {
    final s = _server;
    if (s == null) {
      throw StateError('CoworkDemoServer is not running');
    }
    return Uri(scheme: 'http', host: '127.0.0.1', port: s.port);
  }

  void _handleRequest(HttpRequest request) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      unawaited(_handleWebSocket(request));
      return;
    }
    final path = request.uri.path;
    if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
      _serveHtml(request.response);
      return;
    }
    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.text
      ..write('Not found');
    unawaited(request.response.close());
  }

  void _serveHtml(HttpResponse response) {
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store')
      ..write(_phonePageHtml);
    unawaited(response.close());
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('CoworkDemoServer upgrade failed: ${e.runtimeType}');
      }
      return;
    }
    _sockets.add(socket);
    if (kDebugMode) {
      debugPrint('CoworkDemoServer phone connected (total ${_sockets.length})');
    }
    socket.listen(
      (Object? data) => _onSocketMessage(data),
      onDone: () => _removeSocket(socket),
      onError: (Object e) {
        if (kDebugMode) {
          debugPrint('CoworkDemoServer socket error: ${e.runtimeType}');
        }
        _removeSocket(socket);
      },
      cancelOnError: true,
    );
  }

  void _removeSocket(WebSocket socket) {
    if (_sockets.remove(socket)) {
      if (kDebugMode) {
        debugPrint(
          'CoworkDemoServer phone disconnected (total ${_sockets.length})',
        );
      }
    }
    unawaited(socket.close());
  }

  void _onSocketMessage(Object? data) {
    if (data is! String) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      // Ignore malformed frames. Never log the raw text.
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final type = decoded['type'];
    if (type == 'inject') {
      final text = decoded['text'];
      if (text is String && text.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('CoworkDemoServer inject (len ${text.length})');
        }
        _injected.add(text);
      }
    }
  }

  /// Broadcast one JSON frame to every connected phone tab.
  void _broadcast(Map<String, Object?> frame) {
    if (_sockets.isEmpty) {
      return;
    }
    final encoded = jsonEncode(frame);
    // Copy first: closed sockets mutate the set during iteration.
    for (final socket in _sockets.toList(growable: false)) {
      try {
        socket.add(encoded);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('CoworkDemoServer send failed: ${e.runtimeType}');
        }
        _removeSocket(socket);
      }
    }
  }

  /// Assistant token delta -> phone tabs.
  void pushDelta(String text) => _broadcast({'type': 'delta', 'text': text});

  /// Tool activity (call started) -> phone tabs.
  void pushToolCall(String name, String argsPreview) =>
      _broadcast({'type': 'tool', 'name': name, 'args': argsPreview});

  /// Tool result preview -> phone tabs.
  void pushToolResult(String name, String resultPreview) =>
      _broadcast({'type': 'toolResult', 'name': name, 'result': resultPreview});

  /// Turn finished -> phone tabs.
  void pushDone() => _broadcast({'type': 'done'});

  /// Error -> phone tabs.
  void pushError(String message) =>
      _broadcast({'type': 'error', 'message': message});

  /// Stop the relay and close every socket.
  Future<void> stop() async {
    final sockets = _sockets.toList(growable: false);
    _sockets.clear();
    for (final socket in sockets) {
      await socket.close();
    }
    await _server?.close(force: true);
    _server = null;
    await _injected.close();
    if (kDebugMode) {
      debugPrint('CoworkDemoServer stopped');
    }
  }
}

/// The whole phone page. Inline CSS and JS, no external assets, offline
/// capable. It opens a WebSocket back to the same origin, auto-reconnects, and
/// renders a mobile-width chat UI.
const String _phonePageHtml = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>CoWork Phone</title>
<style>
  :root {
    --bg: #0f1115;
    --panel: #171a21;
    --panel-2: #1f242e;
    --line: #2a303c;
    --text: #e7ebf2;
    --muted: #9aa4b2;
    --accent: #4f8cff;
    --user: #2a5bd7;
    --assistant: #232a36;
    --tool: #2d2438;
    --tool-text: #cdb4ff;
    --ok: #35c46b;
    --bad: #ff5d5d;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0; height: 100%;
    background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  #app {
    max-width: 430px; margin: 0 auto; height: 100%;
    display: flex; flex-direction: column;
    background: var(--bg);
    border-left: 1px solid var(--line);
    border-right: 1px solid var(--line);
  }
  header {
    display: flex; align-items: center; gap: 10px;
    padding: 14px 16px;
    background: var(--panel);
    border-bottom: 1px solid var(--line);
  }
  header .title { font-weight: 600; font-size: 15px; }
  header .sub { font-size: 12px; color: var(--muted); }
  .dot {
    width: 10px; height: 10px; border-radius: 50%;
    background: var(--bad); flex: 0 0 auto;
    box-shadow: 0 0 0 3px rgba(255,93,93,0.15);
    transition: background .2s, box-shadow .2s;
  }
  .dot.on {
    background: var(--ok);
    box-shadow: 0 0 0 3px rgba(53,196,107,0.15);
  }
  #log {
    flex: 1; overflow-y: auto; padding: 16px;
    display: flex; flex-direction: column; gap: 10px;
  }
  .row { display: flex; }
  .row.user { justify-content: flex-end; }
  .row.assistant { justify-content: flex-start; }
  .bubble {
    max-width: 78%; padding: 10px 13px; border-radius: 16px;
    font-size: 15px; line-height: 1.4; white-space: pre-wrap;
    word-wrap: break-word; overflow-wrap: anywhere;
  }
  .user .bubble {
    background: var(--user); color: #fff;
    border-bottom-right-radius: 5px;
  }
  .assistant .bubble {
    background: var(--assistant); color: var(--text);
    border-bottom-left-radius: 5px;
  }
  .chip {
    align-self: flex-start;
    display: inline-flex; align-items: center; gap: 6px;
    max-width: 88%;
    background: var(--tool); color: var(--tool-text);
    border: 1px solid #3a2f4d;
    font-size: 12px; padding: 5px 10px; border-radius: 999px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .chip .name { font-weight: 600; }
  .chip .args { color: var(--muted); overflow: hidden; text-overflow: ellipsis;
    white-space: nowrap; max-width: 210px; }
  .chip.err { background: #3a1f1f; color: #ffb4b4; border-color: #5a2a2a; }
  #composer {
    display: flex; gap: 8px; padding: 12px;
    background: var(--panel); border-top: 1px solid var(--line);
  }
  #input {
    flex: 1; resize: none; height: 44px; max-height: 120px;
    padding: 11px 13px; border-radius: 12px;
    background: var(--panel-2); color: var(--text);
    border: 1px solid var(--line); font-size: 15px; outline: none;
  }
  #input:focus { border-color: var(--accent); }
  #send {
    flex: 0 0 auto; width: 44px; height: 44px; border-radius: 12px;
    border: none; background: var(--accent); color: #fff;
    font-size: 18px; cursor: pointer;
  }
  #send:disabled { opacity: .5; cursor: default; }
  .empty { color: var(--muted); font-size: 13px; text-align: center;
    margin: auto; max-width: 260px; line-height: 1.5; }
</style>
</head>
<body>
<div id="app">
  <header>
    <span class="dot" id="dot"></span>
    <div>
      <div class="title">CoWork Phone</div>
      <div class="sub" id="status">connecting...</div>
    </div>
  </header>
  <div id="log">
    <div class="empty" id="empty">Remote for your AI agent. Type below to send a task to the laptop.</div>
  </div>
  <div id="composer">
    <textarea id="input" placeholder="Message the agent..." autocomplete="off"></textarea>
    <button id="send" title="Send">&#8593;</button>
  </div>
</div>
<script>
(function () {
  var log = document.getElementById('log');
  var empty = document.getElementById('empty');
  var input = document.getElementById('input');
  var send = document.getElementById('send');
  var dot = document.getElementById('dot');
  var status = document.getElementById('status');

  var ws = null;
  var reconnectTimer = null;
  var backoff = 500;
  var assistantBubble = null; // current streaming assistant bubble

  function wsUrl() {
    var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return proto + '//' + location.host + '/';
  }

  function clearEmpty() {
    if (empty && empty.parentNode) { empty.parentNode.removeChild(empty); empty = null; }
  }

  function atBottom() {
    return log.scrollHeight - log.scrollTop - log.clientHeight < 60;
  }
  function scroll() { log.scrollTop = log.scrollHeight; }

  function addBubble(role, text) {
    clearEmpty();
    var stick = atBottom();
    var row = document.createElement('div');
    row.className = 'row ' + role;
    var b = document.createElement('div');
    b.className = 'bubble';
    b.textContent = text;
    row.appendChild(b);
    log.appendChild(row);
    if (stick) scroll();
    return b;
  }

  function addChip(cls, name, detail) {
    clearEmpty();
    var stick = atBottom();
    var chip = document.createElement('div');
    chip.className = 'chip' + (cls ? ' ' + cls : '');
    var n = document.createElement('span');
    n.className = 'name'; n.textContent = name;
    chip.appendChild(n);
    if (detail) {
      var d = document.createElement('span');
      d.className = 'args'; d.textContent = detail;
      chip.appendChild(d);
    }
    log.appendChild(chip);
    if (stick) scroll();
  }

  function appendDelta(text) {
    clearEmpty();
    var stick = atBottom();
    if (!assistantBubble) {
      assistantBubble = addBubble('assistant', '');
    }
    assistantBubble.textContent += text;
    if (stick) scroll();
  }

  function setConnected(on) {
    dot.className = on ? 'dot on' : 'dot';
    status.textContent = on ? 'connected' : 'reconnecting...';
    send.disabled = !on;
  }

  function connect() {
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    try { ws = new WebSocket(wsUrl()); }
    catch (e) { scheduleReconnect(); return; }

    ws.onopen = function () { backoff = 500; setConnected(true); };
    ws.onclose = function () { setConnected(false); scheduleReconnect(); };
    ws.onerror = function () { try { ws.close(); } catch (e) {} };
    ws.onmessage = function (ev) {
      var msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (!msg || typeof msg !== 'object') return;
      switch (msg.type) {
        case 'delta': appendDelta(String(msg.text || '')); break;
        case 'tool': addChip('', String(msg.name || 'tool'), String(msg.args || '')); break;
        case 'toolResult': addChip('', String(msg.name || 'tool') + ' →', String(msg.result || '')); break;
        case 'done': assistantBubble = null; break;
        case 'error':
          assistantBubble = null;
          addChip('err', 'error', String(msg.message || ''));
          break;
      }
    };
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      connect();
    }, backoff);
    backoff = Math.min(backoff * 2, 8000);
  }

  function doSend() {
    var text = input.value.trim();
    if (!text) return;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type: 'inject', text: text }));
    addBubble('user', text);
    assistantBubble = null; // next delta starts a fresh assistant bubble
    input.value = '';
    input.style.height = '44px';
    scroll();
  }

  send.addEventListener('click', doSend);
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); doSend(); }
  });
  input.addEventListener('input', function () {
    input.style.height = '44px';
    input.style.height = Math.min(input.scrollHeight, 120) + 'px';
  });

  setConnected(false);
  connect();
})();
</script>
</body>
</html>''';
