# chuk API emulator

The emulator is a local fake of the hosted chuk API (`api.chuk.chat`). It lets
the app and the tests run without the network and without model costs. The
idea comes from Rakazo's emulators for third-party APIs.

The emulator speaks the same wire protocol as the real server, as the Flutter
client uses it. The real server code is in the `api_server` repository
(`main.py`, `routers/ai/multiplex.py`, `routers/ai/chat_ws.py`,
`routers/ai/brave.py`, `routers/ai/crawl.py`, `routers/ai/images.py`,
`routers/billing/user.py`). When the server protocol changes, change the
emulator too.

Bead: `chuk_chat-0wvt`.

## Files

| Path | Content |
|------|---------|
| `tool/emulator/emulator.dart` | Library: `startEmulator()`, HTTP routes, `/v2/ws`, `/v1/ai/chat/ws` |
| `tool/emulator/src/script.dart` | Script steps, the default echo turn |
| `tool/emulator/src/canned_tools.dart` | Canned Brave, crawl and image results |
| `tool/emulator/src/fixtures.dart` | Model catalogue (copied from `api_server/model_info/models_cache.json`), the PNG |
| `tool/emulator/bin/chuk_emulator.dart` | Command line |
| `test/emulator/` | Tests |

## Run it

```bash
dart run tool/emulator/bin/chuk_emulator.dart --port 8787
```

Options:

| Option | Default | Meaning |
|--------|---------|---------|
| `--port <n>` | `8787` | Port. `0` picks a free port. |
| `--host <address>` | `127.0.0.1` | Bind address. |
| `--chunk-delay-ms <n>` | `30` | Pause between two streamed chat frames. |
| `--script <file>` | none | JSON script to queue at start. Same body as `POST /__emulator/script`. |
| `--quiet` | off | Do not print each request. |

All state is in memory. A restart clears it.

## Point the app at it

The app reads the API base URL from `API_BASE_URL`:

```bash
flutter run -d linux \
  --dart-define-from-file=.env \
  --dart-define=API_BASE_URL=http://127.0.0.1:8787 \
  --dart-define=ARTIFACTS_BASE_URL=http://127.0.0.1:8787
```

With `./run-hot.sh`, add the same two defines to the run.

Notes:

- The app still signs in with Supabase. The emulator does not replace
  Supabase. It accepts any Bearer token and does not check it.
- `ARTIFACTS_BASE_URL` is a separate setting. The app accepts `http://` for
  artifacts only in debug builds.
- Android emulator or phone: the app blocks cleartext HTTP except to
  `127.0.0.1` and `localhost` (`network_security_config.xml`). Do not use
  `10.0.2.2`. Forward the port and use the loopback address:

  ```bash
  adb reverse tcp:8787 tcp:8787
  # then build with --dart-define=API_BASE_URL=http://127.0.0.1:8787
  ```

## Endpoints

Endpoints without auth:

| Method and path | Answer |
|-----------------|--------|
| `GET /health` | `{"status":"ok", ...}` |
| `GET /v1/version` | Version fields |
| `GET /v1/models_info` | Model list. Includes `deepseek/deepseek-v4-flash-0731`, `deepseek/deepseek-v4-pro-0813`, `z-ai/glm-5.3-flash`, `moonshotai/kimi-k3` |
| `GET /v1/ai/image/file/<name>` | A 16x16 PNG |
| `GET /a/<public_id>` | The HTML of an artifact |

Endpoints that need `Authorization: Bearer <any value>` (else `401`):

| Method and path | Answer |
|-----------------|--------|
| `GET /v1/ai/models` | Same as `/v1/models_info` |
| `GET /v1/user/status` | `UserStatusResponse` shape, a paid plan by default |
| `POST /v1/tools/brave/search` | `{"query", "results": [{title, url, description, extra_snippets, age}]}` |
| `POST /v1/tools/brave/images` | `{"query", "results": [{title, image_url, thumbnail_url, ...}]}` |
| `POST /v1/tools/brave/news` | `{"query", "results": [...]}` |
| `POST /v1/tools/brave/rich` | `{"vertical": "weather", "query", "data"}` |
| `POST /v1/tools/brave/places` | `{"query", "places": [...]}` |
| `POST /v1/tools/crawl` | `{"url", "content", "chars", "truncated"}`, or `{"results": [...]}` for `urls` |
| `POST /v1/ai/image/generate` | Multipart form. `{"image_url", "width", "height", "seed", "prompt", "billing"}` |
| `POST /v1/artifacts` | `{"public_id", "url", "download_url", "title"}` |
| `PUT /v1/artifacts/<id>` | Same shape. `404` for an unknown id. |
| `GET /v1/artifacts/<id>` | Same shape |

A missing `query`, `url` or `prompt` gives `400` with `{"error": "..."}`.

### `/v2/ws` (multiplex, the protocol the app uses)

1. The client sends `{"type":"auth","token":"<any>"}`. The emulator answers
   `{"type":"auth_ok"}`.
2. The client sends requests with a `req_id`:
   - `{"req_id","type":"chat","payload":{message, model_id, provider_slug, history, tools, ...}}`
   - `{"req_id","type":"tool","tool":"<name>","payload":{...}}`
   - `{"req_id","type":"cancel"}`
3. The emulator answers with frames
   `{"req_id","kind":"meta|content|reasoning|tool_calls|usage|result","data":...}`,
   `{"req_id","kind":"error","detail","code"}`, and always last
   `{"req_id","kind":"done"}`.

Connection frames without `req_id`: `ping` gives `pong`. `auth_refresh` gives
`auth_refreshed`.

Tool names: `brave_search`, `brave_images`, `brave_news`, `brave_rich`,
`brave_places`, `places_search`, `restaurants_search`, `crawl`,
`image_generate`. Other names give the error code `unknown_tool`.

A cancelled chat ends with `error` code `cancelled`, then `done`, as on the
real server.

### `/v1/ai/chat/ws` (legacy)

Older app builds use this socket. Each request is one JSON object with a
`token` field. The answer frames are flat: `{"meta":...}`, `{"content":"..."}`,
`{"reasoning":"..."}`, `{"tool_calls":[...]}`, `{"usage":...}`,
`{"error":"..."}` and `{"done":true}`. The same script queue drives it.

## Scripted model

Each chat request uses the next queued turn. When the queue is empty, the
emulator plays the default turn: it streams `Echo: <message>` in word-sized
`content` chunks. The answer is deterministic.

Every turn starts with a `meta` frame. If the turn has no `usage` step and
does not fail, the emulator adds a `usage` frame at the end.

### Steps

| Step | Fields | Frames |
|------|--------|--------|
| `text` | `text` or `chunks` (list) | One `content` frame per chunk. `text` is split into words. |
| `reasoning` | `text` or `chunks` | One `reasoning` frame per chunk |
| `tool_call` | `name`, optional `id`, and `arguments` (object or string) or `arguments_chunks` (list of strings) | One `tool_calls` frame. Consecutive `tool_call` steps go into one frame as parallel calls. |
| `usage` | Any fields, for example `prompt_tokens`, `completion_tokens` | One `usage` frame with these fields |
| `error` | `message`, optional `code` (default `upstream_status`) | One `error` frame. The turn stops. `done` follows. |
| `disconnect` | none | The emulator closes the socket. No `done`. |
| `delay` | `ms` | A pause |

About `arguments_chunks`: the real server collects the argument deltas from
the upstream model. It sends the finished call in one `tool_calls` frame. The
emulator does the same. It joins the chunks and sends one frame. The joined
string must be the full JSON argument string.

### Queue a script

The body of `POST /__emulator/script` can be:

- a list of steps: one turn;
- `{"steps": [...]}`: one turn;
- `{"turns": [[...], [...]]}`: several turns, one for each chat request.

Turns are added to the end of the queue. Add `?replace=1` to clear the queue
first.

Example: a tool call, then the answer after the tool result.

```bash
curl -X POST http://127.0.0.1:8787/__emulator/script -d '{
  "turns": [
    [
      {"type": "reasoning", "text": "I need the weather."},
      {"type": "tool_call", "name": "web_search",
       "arguments_chunks": ["{\"query\":", "\"weather kiel\"}"]}
    ],
    [
      {"type": "text", "text": "It is cloudy in Kiel."}
    ]
  ]
}'
```

## Control endpoints

| Method and path | Effect |
|-----------------|--------|
| `POST /__emulator/reset` | Clears the script queue, request log, artifacts and user status |
| `POST /__emulator/script` | Queues turns (see above). Answers `{"queued": n}`. |
| `GET /__emulator/script` | Shows the queued turns |
| `GET /__emulator/requests` | The request log. `?path=/v2/ws` filters by path. |
| `POST /__emulator/user_status` | Merges the JSON body into the `/v1/user/status` answer |

The request log has one entry for each HTTP request and each WebSocket
request frame. Control requests and pings are not logged. Tokens are never
logged; an HTTP entry has `"auth": true|false` instead. Strings longer than
4096 characters are shortened.

## Use it in Dart tests

```dart
import '../../tool/emulator/emulator.dart';

late ChukEmulator emu;
setUp(() async => emu = await startEmulator(port: 0));
tearDown(() async => emu.close());

test('chat turn', () async {
  emu.script([
    {'type': 'text', 'text': 'Hello'},
  ]);
  final connection = MultiplexConnection(
    accessTokenProvider: () async => 'any-token',
    baseUrl: emu.baseUrl,
  );
  final events = await connection.chat(payload: {...}).toList();
  // ...
  expect(emu.requests.last['type'], 'chat');
  await connection.dispose();
});
```

`ChukEmulator` gives `server` (the `HttpServer`), `port`, `baseUrl`,
`requests`, `queuedTurns`, `script()`, `enqueueTurns()`, `reset()`, a mutable
`models` list and `close()`. `startEmulator()` takes `port`, `address`,
`chunkDelay` (default zero for tests) and `quiet`.

Use plain `test()`, not `testWidgets()`. A widget test binding blocks real
sockets.

Run the tests:

```bash
flutter test test/emulator
```

## Limits

- No Supabase. Sign-in, chat sync and storage still need the real Supabase
  project.
- No billing, rate limits or model routing. Any `model_id` gets an answer.
- The `history`, `tools`, images and cache fields of a chat payload are
  logged but not used. A `cache_ref` never gives a `cache_miss`.
- Not emulated: transcription, Typst, file conversion, Stripe, GitHub, MCP,
  the Agents relay (`/v2/relay/ws`).
