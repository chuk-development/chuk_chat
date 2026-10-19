# Voice stack decision (research, 2026-10-19)

Bead: `chuk_chat-4p87`. Research only. No code is changed yet.

Goal: voice mode on LiveKit, in normal chat and in Agents.
STT = Groq Whisper, LLM = Cerebras Qwen ~27B, TTS with Zero Data Retention (ZDR)
without an enterprise contract, EU if possible, streamed output, first TTS audio < 500 ms.

Current worker (api_server: `voice/`, not `new-voicemode`):
Silero VAD + local turn detector `v1-mini` -> Inworld STT (streaming) ->
RunAnywhere `glm-5.3-flash` -> Inworld TTS 2 Flash, on a self-hosted
`livekit-server` v1.13.10 in a Dokploy Compose stack. `docs/PERSONAL_AGENT_SPEC.md`
§3.1 still names the old prototype stack (Groq, gpt-oss, Cartesia). It is stale.

## Short answer

| Part | Choice | Why |
|---|---|---|
| STT | Groq `whisper-large-v3-turbo`, `language="de"` | $0.04/h, fast, ZDR is a self-serve switch. Not streaming. |
| LLM | Cerebras `qwen-3.8-27b`, `reasoning_effort="none"` | Only ~27B dense Qwen on Cerebras. ZDR by default. |
| TTS primary | **Cartesia Sonic 3.6 via LiveKit Inference** (`cartesia/sonic-3.6`, region restriction EU) | ZDR by default on all plans, EU endpoint, top quality, p95 TTFA 348 ms. |
| TTS fallback | **Gradium** direct (`eu.api.gradium.ai`) or via LiveKit Inference | Only vendor with self-serve ZDR and EU direct. p95 99 ms. Lower quality. |
| SFU | Keep self-hosted LiveKit, add TURN/TLS on 443 | Already runs. $0 per minute. Cloud gives little for EU users. |

## 1. TTS shortlist

TTFB = Coval p95 time to first audio, last 24 h, measured from us-east-1 with English text
([benchmarks.coval.ai/tts](https://benchmarks.coval.ai/tts)). Artificial Analysis measures
quality, not TTFB ([leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard)).
Measure again from the EU with German text before the final decision.

| Provider / model | ZDR default (self-serve)? | EU | WS stream | TTFB p95 | German | $ / 1M chars | LiveKit plugin |
|---|---|---|---|---|---|---|---|
| Cartesia Sonic 3.6 direct | No: "You must be on an enterprise plan to enable ZDR" ([doc](https://docs.cartesia.ai/enterprise/zero-data-retention)) | Enterprise only ([doc](https://docs.cartesia.ai/enterprise/regional-endpoints)) | yes | 348 ms | yes, AA Elo 1287 | 38-65 | plugin |
| **Cartesia via LiveKit Inference** | **Yes**, all plans ([doc](https://docs.livekit.io/agents/models/inference/), [blog](https://livekit.com/blog/how-we-handle-zero-data-retention-in-livekit)) | yes, region restriction ([doc](https://docs.livekit.io/deploy/admin/regions/data-residency)) | yes | 348 ms | yes | 50 (Scale 37.50) ([pricing](https://livekit.com/pricing/inference)) | `inference.TTS` |
| Inworld TTS-2 / Flash (current) | No: Enterprise or $1,500/mo add-on ([doc](https://docs.inworld.ai/portal/zero-data-retention)). Yes via LK Inference | No (LK Inference: no EU) | yes | 179 / 120 ms | not listed alone | 25 / 15 ([pricing](https://inworld.ai/pricing)) | plugin + Inference |
| Deepgram Aura-2 | No true ZDR; `mip_opt_out=true` = "retained only for the duration necessary" ([doc](https://developers.deepgram.com/docs/the-deepgram-model-improvement-partnership-program)) | yes, self-serve `api.eu.deepgram.com` ([doc](https://developers.deepgram.com/reference/regional-endpoints)) | yes | 499 ms | yes, 7 voices | 30 | plugin + Inference |
| ElevenLabs Flash v2.5 / v4 Turbo | No: Enterprise only ([doc](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode)) | Enterprise only ([doc](https://elevenlabs.io/docs/overview/administration/data-residency)) | yes | 257 / 224 ms | strong, Elo 1333 (#1) | 40 | plugin |
| **Gradium (Kyutai)** | **Yes**, self-serve on paid plans ([FAQ](https://gradium.ai/legal-faq)) | **yes** `eu.api.gradium.ai` ([doc](https://docs.gradium.ai/guides/eu-data-residency.md)) | yes | **99 ms** | yes (EN/FR/DE/ES/PT), Elo 1176 | ~38-69 (LK 48) ([pricing](https://gradium.ai/pricing)) | plugin + Inference |
| Mistral Voxtral TTS | On request only ([help](https://help.mistral.ai/en/articles/347612-can-i-activate-zero-data-retention-zdr)) | EU company, TTS hosting not stated | stream, protocol unclear | ~0.8 s (doc) | yes | 16 | plugin |
| DeepInfra Qwen3-TTS | Yes: "only hold it in memory" ([doc](https://docs.deepinfra.com/account/data-privacy)) | no | stream PCM, WS unclear | ~97 ms (claim) | yes | 20 | no |
| DeepInfra Kokoro | yes | no | yes | - | **no German** | 0.99 | plugin |
| Groq Orpheus (PlayAI gone) | - | - | not documented | - | **no German** (EN, AR) | - | plugin |
| Fish Audio S2.1 / Drama 3 | Enterprise direct; yes via LK Inference | no | yes | 481 / 235 ms | likely, not checked | 15 per 1M UTF-8 bytes | plugin + Inference |
| Soniox tts-rt-v2 | Yes: "Never stored, never saved" (claim) | EU on request ([doc](https://soniox.com/docs/data-residency)) | yes | 334 ms | yes | ~14 | plugin |
| Azure Neural / HD | Yes: real-time text not stored ([doc](https://learn.microsoft.com/en-us/azure/ai-foundry/responsible-ai/speech-service/text-to-speech/data-privacy-security)) | yes, self-serve (germanywestcentral) | SDK stream | not measured | very good, many voices | 15 / 22 | plugin |
| Google Chirp 3 HD | Yes: not logged ([doc](https://docs.cloud.google.com/text-to-speech/docs/data-logging)) | yes (doc contradicts for Chirp 3) | bidi gRPC | 838 ms | yes | 30 | plugin |

Not usable: Groq TTS, Kokoro, Speechmatics (no German); Voxtral (too slow); ElevenLabs,
direct Cartesia, direct Inworld (ZDR only with enterprise). Not verified: Rime, Hume Octave 2,
Async, Neuphonic, LMNT, Resemble, KugelAudio, Murf.

**Recommendation:** Cartesia Sonic 3.6 through LiveKit Inference, EU region restriction on.
Fallback: Gradium EU direct (also a good low-latency primary if German quality passes an A/B test).
Caveats: (a) the ZDR promise comes from LiveKit, not from a contract with Cartesia;
(b) LiveKit Cloud agent observability is not ZDR, turn it off; (c) LiveKit Inference needs a
LiveKit Cloud project key. The inference classes take `api_key`/`api_secret`, so a worker on
the self-hosted SFU can use a separate Cloud key. Test this before you rely on it.
Cheapest ZDR + EU without LiveKit Inference: Azure Neural (self-serve, EU, $15/1M).

## 2. Groq Whisper and Cerebras: retention

| | Groq STT | Cerebras LLM |
|---|---|---|
| Models | `whisper-large-v3-turbo` $0.04/h, `whisper-large-v3` $0.111/h, min 10 s billed per request ([doc](https://console.groq.com/docs/speech-to-text)) | `qwen-3.8-27b` (27B dense, live since 2026-09-03) $0.99 in / $1.49 out per 1M, ~1850 tok/s (vendor); `gpt-oss-120b` $0.35 / $0.75, AA TTFT 0.42 s ([models](https://inference-docs.cerebras.ai/models/overview), [qwen](https://inference-docs.cerebras.ai/models/qwen-3.8-27b.md)) |
| Streaming | **No.** REST file upload only. LiveKit cuts audio with VAD. | yes (SSE) |
| Default retention | Inputs/outputs not kept, **but** may be logged up to 30 days for troubleshooting/abuse ([doc](https://console.groq.com/docs/your-data)) | **ZDR by default**: "We do not retain inputs and outputs associated with our ... inference ... Services" ([privacy §6](https://www.cerebras.ai/privacy-policy)); no training ([terms](https://www.cerebras.ai/terms-of-service)) |
| ZDR | **Opt-in**, self-serve: console Settings -> Data controls ([link](https://console.groq.com/settings/data-controls)). Turns off batch and fine-tuning. | default, no setting |
| EU | Helsinki DC exists, but no public EU region; stored data in US GCP ([news](https://insidehpc.com/2025/07/groq-launches-european-data-center-in-helsinki/)) | none live; EU capacity planned end of 2026 ([news](https://cerebras.gcs-web.com/news-releases/news-release-details/cerebras-systems-accelerates-european-expansion-200mw-ai-compute)) |

Notes: there is no Qwen 32B on Cerebras any more (`qwen-3-32b` deprecated 2026-02-16,
[list](https://inference-docs.cerebras.ai/support/deprecation)). `qwen-3.8-27b` has reasoning
`high` by default: set `reasoning_effort="none"` for voice. Cerebras TTFT for it is not measured
by AA yet. Plugins: `livekit-agents[groq,cerebras]~=1.8` (1.8.8);
`groq.STT(model="whisper-large-v3-turbo", language="de")` (default language is `en`),
`cerebras.LLM(model="qwen-3.8-27b", reasoning_effort="none")`
([groq](https://docs.livekit.io/agents/models/stt/groq.md), [cerebras](https://docs.livekit.io/agents/models/llm/cerebras.md)).
**Action: switch on Groq ZDR in the console before launch.**

## 3. LiveKit Cloud vs self-hosted (Dokploy)

| Monthly volume | Cloud, agent on Cloud | Hybrid: agent on own box, SFU on Cloud | Self-host (current) |
|---|---|---|---|
| ~150 min | $0 (Build, but 10-20 s cold start) | $0 | $0 extra |
| ~7,500 min | Ship $50 + overage = ~$75 | Ship $50 | $0 extra |
| ~22,500 min | ~$225 | $50 | $0 extra |

Source: [livekit.com/pricing](https://livekit.com/pricing). Build plan: hard caps, 1,000 agent
min, 5,000 WebRTC participant min. EU data region Frankfurt is chosen at project creation.

- **Latency:** for EU users on an EU node, network RTT is ~10-40 ms; agent and SFU on one box
  is ~0 ms. Cloud's edge only helps for far-away users. STT+LLM+TTS dominate.
- **Self-host effort:** already done (`docker-compose.yml`, UDP mux 7882, TCP 7881,
  `use_external_ip`, Traefik for signaling on 7880). **Missing: TURN.** Without TURN/TLS on 443,
  users on UDP-blocked networks (corporate, hotel, some VPN) cannot connect (README line 265).
  Fix: embedded TURN (`turn.enabled`, `tls_port` 5349 advertised as 443, own domain) behind a
  Traefik TCP router `HostSNI(turn.<domain>)` with `turn.external_tls: true`. Redis not needed
  for one node. ([ports](https://docs.livekit.io/transport/self-hosting/ports-firewall.md),
  [deployment](https://docs.livekit.io/transport/self-hosting/deployment.md))
- **What self-host loses:** Krisp/BVC noise cancellation (Cloud only), the hosted turn detector
  `v1` and adaptive interruption (worker already uses local `v1-mini` and VAD interruption).
  Dispatch works the same.
- **Recommendation:** keep self-hosting, add TURN/TLS. Use a Cloud project only as the key for
  LiveKit Inference TTS. Move to hybrid (Ship $50) only if users report bad audio/noise or
  connection failures that TURN does not fix.

## 4. Latency budget (user stops talking -> first audio)

Groq Whisper is batch. The worker sends the audio segment only after Silero VAD sees the end
of speech. So the turn cannot get the streaming-STT head start that Inworld STT gives now.

| Step | Estimate | Note |
|---|---|---|
| VAD end of speech (silence) | 300-550 ms | Silero `min_silence_duration` default 0.55 s; tune to ~0.3 s |
| Groq STT (upload 2-5 s audio EU->US + infer) | 200-400 ms | WAV, `language="de"` lowers latency |
| Endpointing wait (turn detector) | runs in parallel | with `preemptive_generation`, LLM starts on the final transcript |
| Cerebras `qwen-3.8-27b` first token (US) | 200-400 ms | `reasoning_effort="none"` is mandatory; not measured yet |
| TTS first audio | 100-350 ms | Gradium ~100, Cartesia ~350 p95 (US-measured) |
| WebRTC + jitter buffer | 50-100 ms | |
| **Total** | **~0.9-1.6 s, p50 ~1.1 s** | Spec target is <= 800 ms p50 (§6.2). |

Result: TTS first audio < 500 ms is reachable. End-to-end < 800 ms p50 is **not** likely with
batch Groq Whisper plus US-only Groq/Cerebras. Options: keep a streaming STT (Inworld STT now,
or Deepgram Nova-3 EU, Soniox) and use Groq Whisper only as fallback; or accept ~1.1 s.

### What must change in the current worker (no edits made)

api_server: `voice/`:

- `agent.py:52` imports: add `groq`, `cerebras` (or `inference`) plugins.
- `agent.py:98-117` RunAnywhere LLM pin and client -> Cerebras `qwen-3.8-27b`, `reasoning_effort="none"`.
- `agent.py:120-136` STT pin `inworld/inworld-stt-1` and locale map -> Groq model pin, ISO-639-1 codes.
- `agent.py:138-143`, `:155` TTS model pin and default voice `Bastian` -> Cartesia/Gradium model + voice IDs.
- `agent.py:254-262` `_build_llm`; `:272-283` `_build_stt` (no "auto": use Groq `detect_language`); `:295-304` `_build_tts` (Inworld `text_normalization`, `timestamp_type="WORD"` -> Cartesia word timestamps for `use_tts_aligned_transcript` at `:738`).
- `agent.py:728-734` `expressive.tts_instructions_append` is Inworld-specific; check support.
- `agent.py:745-751` endpointing `min_delay=0.8` exists because Inworld's final transcript came late; re-tune for batch STT (`0.3-0.5`).
- `agent.py:356` `silero.VAD.load()`: set `min_silence_duration` (~0.3 s), because with batch STT it decides when STT starts.
- `agent.py:592` and the `llm_node` retry text name Inworld; make provider-neutral.
- `agent.py:145-152`, `:650-690` and `inworld_s2s.py`, `call_config.py:31-34,160`: Inworld S2S engine is not ZDR; drop it or hide it.
- `agent.py:179-192`, `:706-708` vision narration pinned to Inworld; move to Cerebras `qwen-3.8-27b` (takes images) or turn off.
- `inworld_provider.py` (whole file) becomes unused.
- `ui_bridge.py:36-42` `AVAILABLE_VOICES` (Inworld names) -> map display names to new voice IDs; `tools.py:1392` lists them.
- `usage_reporter.py:89-107` model ids for metering.
- `pyproject.toml:8` extras `inworld,openai,silero` -> `groq,cerebras,silero` (+ `cartesia` or use `inference`).
- `docker-compose.yml:37-53` env: `INWORLD_API_KEY`, `RUNANYWHERE_API_KEY`, model defaults -> `GROQ_API_KEY`, `CEREBRAS_API_KEY`, TTS key or Cloud inference key; `:1-27` and `livekit.yaml` add TURN.
- `README.md` sections "Environment" and "Self-host" describe the old stack.

api_server: `routers/ai/voice_usage.py:26-40` and `:146-165`: price allowlist is
Inworld STT/TTS and GLM only; add Groq STT ($0.04/h, 10 s minimum), Cerebras tokens, TTS per char.

chuk_chat:

- `lib/voice/voice_call_controller.dart:82-83`, `:180-186`, `:971`, `:994`: hardcoded Inworld voice names (`Bastian` ... `Sabine`).
- `lib/voice/voice_protocol.dart:305-312`: engine docs and `inworldS2S` engine.
- `docs/PERSONAL_AGENT_SPEC.md` §3.1: stack table is stale.
- `agents/voice/` holds only `session.txt` and an empty `tests/`; nothing to change.
