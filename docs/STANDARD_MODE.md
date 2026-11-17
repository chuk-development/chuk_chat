# Standard mode (server-picked model and providers)

Since 2026-11-17 the composer has two modes (`ChatMode`,
`lib/services/chat_mode_service.dart`):

- **Standard** (default for every new install and account): we pick the
  model and an ordered provider chain for the best value (fast first token,
  at least about 100 tok/s, low price). The reader picks only the reasoning
  level.
- **Custom model**: any model and provider the reader picks, as before.

The old modes `fast` and `thinking` no longer exist. A stored `fast` or
`thinking` is read as Standard.

## Where the choice lives

The file `profiles.json` in the GitHub repo
`chuk-development/chuk_chat_model_list` (next to `models_to_include.txt`).
The API server reloads it every 5 minutes (`api_server/model_info/profiles.py`)
and serves it at `GET /v1/profiles`. Push a change there and every app on
Standard follows, without an app update or a server deploy. The `id` of the
Standard profile must stay `standard`.

To choose providers: `api_server/scripts/provider_pick.py`, see
`api_server/docs/PROVIDER_PICK.md`.

## How a send carries it

The app never pins a provider in Standard. `ModeConfig.providerSlug` is the
marker `profile:standard` (`ChatProfileService.standardMarker`), which
travels through the whole send pipeline like any slug. Only
`WebSocketChatService._sendViaMultiplex` turns it into `profile: "standard"`
(and drops `provider_slug`). The server then sets model and provider chain;
OpenRouter tries the chain in order and never leaves it. An Agents host that
forwards the marker to `/v1/chat/completions` gets the same.

`ChatProfileService` (`lib/services/chat_profile_service.dart`) only keeps
what the UI shows (model name, provider chain) and the model id the frame
carries as a fallback. It reads its copy from SharedPreferences at once and
refreshes from `/v1/profiles` together with the model catalogue
(`ModelPrefetchService`).

## What gets logged (no content)

Per chat, `usage_logs` stores tokens, cache tokens, costs, plus `profile`,
`served_provider`, `ttft_ms`, `tokens_per_second`, `latency_ms`,
`reasoning_tokens`, `finish_reason` and `upstream_cost_usd`. PostHog
`chat_completed` carries the same route fields. A query per provider is in
`api_server/docs/PROVIDER_PICK.md`.

## New accounts

The Supabase trigger `set_default_model_for_new_user` sets only
`user_preferences.selected_model_id` to Standard's model and pins no
provider (`supabase/migrations/20261117130000_default_model_standard.sql`).
