# tool/emulator/src · Signaturen

## tool/emulator/src/canned_tools.dart  (193 Z.)
- L8 `class ToolInputError implements Exception`  — Thrown by a canned tool for a bad request. Maps to HTTP 400 or to an
  - L9 `ToolInputError(this.detail)`
  - L10 `final String detail`
- L13 `String _query(Map<String, Object?> payload)`
- L19 `int _count(Map<String, Object?> payload, {int fallback = 5, int max = 20})`
- L25 `String _slug(String query)`
- L29 `Map<String, Object?> braveSearch(Map<String, Object?> payload)`  — POST /v1/tools/brave/search, mux tool `brave_search`.
- L49 `Map<String, Object?> braveImages( Map<String, Object?> payload, { required String baseUrl, })`  — POST /v1/tools/brave/images, mux tool `brave_images`.
- L73 `Map<String, Object?> braveNews(Map<String, Object?> payload)`  — POST /v1/tools/brave/news, mux tool `brave_news`.
- L96 `Map<String, Object?> braveRich(Map<String, Object?> payload)`  — POST /v1/tools/brave/rich, mux tool `brave_rich`.
- L112 `Map<String, Object?> bravePlaces(Map<String, Object?> payload)`  — POST /v1/tools/brave/places, mux tools `brave_places`, `places_search`,
- L140 `Map<String, Object?> crawl(Map<String, Object?> payload)`  — POST /v1/tools/crawl, mux tool `crawl`. Single `url` or batch `urls`.
- L176 `Map<String, Object?> imageGenerate( Map<String, Object?> fields, { required String baseUrl, required int sequence, })`  — POST /v1/ai/image/generate, mux tool `image_generate`.

## tool/emulator/src/fixtures.dart  (261 Z.)
- L6 `modelsInfoJson = r''' [ { "id": "deepseek/deepseek-v4-flash-0731", "name": "DeepSeek: DeepSeek V4 Flash 0731", "descript`  — Body of GET /v1/models_info and GET /v1/ai/models.
- L259 `fixedPngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGPQqv9PEmIY1TCqYfhqAACUCKgQCZL4/wAAAABJRU5Erk`  — A 16x16 solid PNG. `GET /v1/ai/image/file/<token>` serves it.

## tool/emulator/src/script.dart  (147 Z.)
- L11 `knownStepTypes = { 'text', 'reasoning', 'tool_call', 'usage', 'error', 'disconnect', 'delay', }`  — The step types that a script can use.
- L22 `class ScriptStep`  — One step of a scripted turn. See docs/API_EMULATOR.md for the format.
  - L23 `ScriptStep(this.type, this.data)`
  - L26 `factory ScriptStep.fromJson(Object? raw)`  — Parses one step. Throws [FormatException] for a step that is not valid.
  - L63 `final String type`
  - L64 `final Map<String, Object?> data`
  - L67 `List<String> get textChunks`  — The text pieces of a "text" or "reasoning" step, one frame each.
  - L83 `String get toolArguments`  — The complete argument string of a "tool_call" step.
  - L92 `Map<String, Object?> toJson()`
- L96 `typedef ScriptTurn = List<ScriptStep>`  — A scripted turn: the steps that answer one chat request.
- L104 `List<ScriptTurn> parseScript(Object? body)`  — Parses the body of POST /__emulator/script.
- L129 `ScriptTurn defaultTurn(String message)`  — The answer when no script is queued: a deterministic echo.
- L139 `List<String> splitIntoChunks(String text)`  — Splits text into word-sized pieces. Joining the pieces gives the input.
