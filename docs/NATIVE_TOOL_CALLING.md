# Native Tool Calling (OpenAI / OpenRouter format)

Status: **implemented** — native `tools[]` function calling, end to end (client +
api_server), for all OpenAI-compatible providers (OpenRouter + Fireworks direct).
Gated to the `/v2/ws` transport (`nativeToolCalling: !kIsWeb`); web keeps the
prompt-based scheme. The prompt-based `<tool_call>` path stays as a fallback.

Tracking bead: `chuk_chat-7q6` (+ children).

## Implementation (what changed)

Backend (`api_server`, `/v2/ws` in `routers/multiplex.py`):
- `_sanitize_tools()` / `_flush_tool_acc()` helpers; `tools`/`tool_choice`/
  `parallel_tool_calls` read from the request frame and forwarded into `api_json`
  for both the direct-Fireworks and OpenRouter paths (with
  `provider.require_parameters` on OpenRouter).
- Index-keyed `delta.tool_calls` accumulator in the stream loop; flush on
  `finish_reason=="tool_calls"` / `[DONE]` → a `tool_calls` frame to the client.
- History passthrough for `assistant`+`tool_calls` and `role:"tool"`+
  `tool_call_id` entries; empty `message` allowed on a tool-result continuation
  (no trailing user turn appended).

Client (`chuk_chat`):
- `NativeToolCall` + `ChatStreamEvent.toolCalls` (`lib/models/chat_stream_event.dart`);
  `multiplex_connection.dart` parses the `tool_calls` frame; `streaming_manager_io`
  collects them, exposed via `getNativeToolCalls()`.
- `websocket_chat_service` sends the `tools[]` payload; `streaming_message_handler`
  builds it from `ToolCallHandler.nativeToolDefinitions()` and reads the native
  calls in `onComplete`.
- `ToolCallHandler.processAssistantResponse(nativeToolCalls:)` consumes native
  calls, executes them through the existing enforcer/executor, and builds the
  native `assistant(tool_calls)` + `tool` round-trip (empty continuation message).
  A turn with no native calls falls through to the unchanged text path.
- `ToolLoopSession.nativeToolCalling` threads a native-prompt flag into
  `tool_prompt_builder` (omits the `<tool_call>` protocol / tool-def prose; keeps
  identity, skills, MCP, visual-output tags).
- 47 built-in tools rewritten to real JSON Schema + `ClientTool.toOpenAiFunction()`.

## Why

The old scheme injected tool definitions as **text** into the system prompt and
expected the model to emit `<tool_call>{json}</tool_call>` in the content stream,
which the client regex-parsed back. Native tool-calling models (GLM 5.3, Kimi,
DeepSeek) route their calls into the native `tool_calls` slot instead. Our backend
stream proxy only read `delta.content` + `delta.reasoning`/`reasoning_content` and
**never read `delta.tool_calls`**, so those calls vanished → empty response.

Both open-source references (OpenAI **Codex**, **OpenCode**) use native tool calling
exclusively; neither parses `<tool_call>` text. All our models run through OpenRouter
or Fireworks, both OpenAI-compatible `/chat/completions`. So we go native/official —
one wire format covers every provider.

## Wire spec (OpenRouter / OpenAI Chat Completions, streaming)

Endpoint: OpenRouter `https://openrouter.ai/api/v1/chat/completions` and Fireworks
`/chat/completions`. Identical OpenAI wire format.

### Request

Send `tools[]` on **every** request in the loop (including the tool-result
follow-up — the router re-validates the schema each call):

```jsonc
{
  "model": "z-ai/glm-5.3-flash",
  "messages": [ ... ],
  "tools": [
    { "type": "function",
      "function": {
        "name": "search_places",                 // ^[a-zA-Z0-9_-]{1,64}$  (no dots/spaces)
        "description": "...",
        "parameters": { "type": "object", "properties": { ... }, "required": [ ... ] }
      } }
  ],
  "tool_choice": "auto",          // "auto"(default) | "none" | "required" | {"type":"function","function":{"name":"..."}}
  "parallel_tool_calls": true,    // default true for most models
  "stream": true,
  "stream_options": { "include_usage": true }
}
```

- A no-arg tool still needs `"parameters": {"type":"object","properties":{}}` — never omit.
- `tool_choice:"required"` / forced-function are **best-effort**: some open-weight
  reasoning models reject or ignore them → fall back to `"auto"` on a 400.
- To hard-guarantee a provider actually supports tools, set
  `"provider": {"require_parameters": true}` — otherwise a fallback provider that
  ignores `tools` silently returns a plain text answer with `finish_reason:"stop"`.

### Streaming response — `choices[0].delta.tool_calls[]`

```jsonc
{ "index": 0, "id": "call_abc", "type": "function",
  "function": { "name": "search_places", "arguments": "" } }
```

- **`index`** — present on every fragment; the key that ties fragments together.
  **Accumulate keyed by `index`, never `.first()`** (Codex's public impl drops
  parallel calls — do not copy that).
- **`id`**, **`type`**, **`function.name`** — arrive **once** (first fragment for
  that index); null/absent afterward.
- **`function.arguments`** — streams as **string fragments**; concatenate in order.
  Only valid JSON once fully assembled. Parse defensively — providers occasionally
  emit malformed/truncated JSON.
- **Terminal:** the chunk with `choices[0].finish_reason == "tool_calls"` (its
  `delta` is usually `{}`) → **flush** all accumulated calls. `finish_reason` is on
  the **choice**, not the delta (the OpenRouter doc snippet has this wrong). Also
  flush any still-pending calls at `data: [DONE]` as a safety net.
- Empty content + `finish_reason:"tool_calls"` is **normal**, not an error.

### Reasoning channel

- **Via OpenRouter:** `delta.reasoning` (may be a string OR an object `{text|content}`).
- **Via Fireworks/DeepSeek/GLM direct:** `delta.reasoning_content`.
- Accumulate **both** field names into one reasoning buffer to be provider-agnostic.
- Close the reasoning channel the moment the first `content` token or first
  `tool_calls` fragment arrives. Some reasoning models emit no reasoning tokens at
  all — never block tool handling on ever seeing one.

### SSE hygiene

- Stream ends at literal `data: [DONE]` — hard stop.
- OpenRouter injects keep-alive **comment** lines starting with `:` (e.g.
  `: OPENROUTER PROCESSING`) that are **not JSON** — skip any line starting with `:`
  before `json.loads`.

### Tool-result round-trip

Append in this exact order, then re-POST with `tools[]` still present:

```jsonc
{ "role": "assistant", "content": null, "tool_calls": [ { "id": "call_abc",
  "type": "function", "function": { "name": "...", "arguments": "{...json string...}" } } ] }
{ "role": "tool", "tool_call_id": "call_abc", "content": "<result serialized as string>" }
```

- `arguments` goes back as the **JSON string**, not a parsed object.
- One `role:"tool"` message per call, `tool_call_id` = the call's `id`. `name` is
  **not** required on the tool message. Every `tool_call_id` must be answered before
  the next request or the upstream 400s.
- Loop until a turn returns no tool_calls (`finish_reason:"stop"`); cap iterations.

## Reference accumulator

The canonical index-keyed Python accumulator (skip `:` lines, both reasoning field
names, flush on `finish_reason=="tool_calls"`/`[DONE]`) lives in the implementation
under the api_server stream proxy. Mirror OpenCode's `appendOrStart`+`finishAll`,
not Codex's `.first()`.

## Architecture (chuk_chat client)

Prompt-based today; layers and the migration touch-points:

| Layer | File(s) | Change |
|-------|---------|--------|
| Tool model | `lib/models/client_tool.dart` | add `toOpenAiFunction()` |
| Builtin defs | `lib/services/tool_registry.dart` | prose params → JSON Schema (47 tools) |
| MCP defs | `lib/services/mcp/mcp_tool_bridge.dart` | already native `inputSchema` — no change |
| Executor | `lib/services/tool_executor.dart`, `lib/tool_handlers/*` | unchanged (args arrive as Map either way) |
| Enforcer | `lib/services/tool_enforcer.dart` | already schema-aware (`properties`) — minimal |
| Prompt builder | `lib/services/tool_prompt_builder.dart` | strip `<tool_call>` protocol/"How to call" text; keep identity, skills, visual-output tags |
| Request | `lib/services/streaming_chat_service.dart`, `websocket_chat_service.dart` | add structured `tools[]` field |
| Stream event | `lib/models/chat_stream_event.dart` | add `toolCalls` variant |
| Parse | `lib/utils/tool_parser.dart`, `tool_call_handler.dart:564` | consume native calls; keep text parser as fallback |
| Backend | `api_server` `routers/multiplex.py`, `routers/chat_ws.py`, `/v1/ai/chat` in `main.py` | accept + forward `tools[]`; accumulate `delta.tool_calls`; stream tool-call events |

**Note on builtins:** built-in tool `parameters` were prose maps
(`{'query': 'string (required...)'}`) — rewritten to real JSON Schema with the
original prose preserved as each property's `description`. MCP tools already carried
native JSON Schema. Skills are a separate prompt-injection mechanism (the single
`skill` tool) — unaffected beyond the `skill` tool getting a schema like any
built-in tool.
