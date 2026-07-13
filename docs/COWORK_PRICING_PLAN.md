# CoWork — Pricing & Model Plan

**Status:** Planning spec (for implementation by others). No code here.
**Owner:** product/pricing. **Last updated:** 2026-07-08.

CoWork = a general knowledge-work assistant tool (NOT a coding agent like Claude Code).
It resells OpenRouter usage under a subscription with a hard credit cap. The **user
picks the model themselves** — we only recommend and show a live cost calculation.

---

## 1. Scope & principles

- User chooses the model. We do not force one. We **recommend** a default and **show a
  live calculation** ("at model X your €80 lasts ~N months / ~M million tokens").
- Only **frontier open-weight** models are offered (large, current, top intelligence).
  No legacy models (no GLM 4.x, no DeepSeek v3.x) in the frontier tier.
- Billing is credit-based with a **hard cap** per plan. OpenRouter cost is deducted
  **1:1 USD→EUR** against the OpenRouter list price (existing behaviour in
  `payment_service.py`).

---

## 2. Calibration anchor (REAL data — not estimates)

From a real active month in chuk_chat (May 2026, single power user):

| Metric | Value |
|---|---|
| Requests | 1,254 |
| Text tokens | 15,278,941 (~15.3M) |
| Cached tokens | 2,045,136 (~13%) |
| Credits spent | €12.96 |
| Tokens / request | ~12,200 |
| Input : Output split | ~87% / 13% |
| Models used | mostly Kimi K2.5 + K2.6 (expensive) |

**Validation:** Kimi K2.6 real blended rate = €1.03/M. Model formula
(0.87·in + 0.13·out) predicts $1.017/M → matches. All estimates below use this
87/13 split derived from real data.

**Key correction to earlier assumptions:** active CoWork is NOT light. It behaves
close to an agentic loop (re-sent context, tool calls, docs). Realistic active usage
is **15M–50M tokens/month**, not the 1.5M "typical chat" figure. One active month on
premium models already nearly maxes the €16 cap.

---

## 3. Usage profiles (tokens / month)

| Profile | Tokens/mo | Notes |
|---|---|---|
| Casual | ~2M | Q&A, few docs |
| Active (daily) | ~10–15M | multi-turn, docs (= the real anchor above) |
| Power (all-day) | ~20–50M | long history, RAG, tool loops |

~87% of all tokens are input. Input is the cost driver (~90%+ of the bill).

---

## 4. Pricing model

Base tier confirmed in `payment_service.py` (`PLAN_CREDITS_EUR = 16.0`). Full ladder:

| Plan price | Credits (price × 0.8) | Nominal margin | Target user |
|---|---|---|---|
| €20 / mo | €16 | 20% | casual / light, or cheap models |
| **€50 / mo** | **€40** | 20% | active daily user, mid models |
| **€100 / mo** | **€80** | 20% | power user, premium models OK |
| **€200 / mo** | **€160** | 20% | heavy power / all-premium, headroom |

- Margin rule: **credits = price × 0.8** (same 20% across every tier).
- Real margin is higher than nominal because deduction is USD→EUR 1:1 while EUR/USD ≈ 1.10,
  and most users never burn the full cap. Nominal 20% is the floor for cap-maxing whales.

**Runway per tier** (tokens the credits buy = credits ÷ blended $/M; EUR≈USD):

| Credits | v4-flash (0.10) | v4-pro (0.49) | glm-5.2 (1.20) |
|---|---|---|---|
| €16 | ~160M | ~33M | ~13M (< 1 active month) |
| €40 | ~400M | ~82M | ~33M (~2 active months) |
| €80 | ~800M | ~163M | ~67M (1 power month + headroom) |
| €160 | ~1.6B | ~327M | ~133M (heavy power, comfortable) |

Reference: active month ≈ 15M tokens, power month ≈ 50M. So GLM 5.2 (smartest) needs the
€100+ tier for a power user; V4-Flash is effectively unlimited on any tier.

---

## 5. Frontier open-weight catalog (live OpenRouter prices + Artificial Analysis Intelligence Index)

Fetched via `openrouter.ai/api/v1/models`. Intelligence = Artificial Analysis Index (mid-2026).
T=Tools, R=Reasoning, V=Vision. Prices $/1M tokens.

| Model | Intel | in | out | ctx | TRV |
|---|---|---|---|---|---|
| z-ai/glm-5.2 | **51** 🥇 | 0.93 | 3.00 | 1M | TR- |
| deepseek/deepseek-v4-pro | 44 | 0.43 | 0.87 | 1M | TR- |
| minimax/minimax-m3 | 44 | 0.30 | 1.20 | 1M | TRV |
| moonshotai/kimi-k2.6 | 44 | 0.66 | 3.41 | 262K | TRV |
| deepseek/deepseek-v4-flash | 40 | 0.09 | 0.18 | 1M | TR- |
| nvidia/nemotron-3-ultra-550b-a55b | 38 | 0.50 | 2.20 | 1M | TR- |
| qwen/qwen3.7-plus | new (unranked) | 0.32 | 1.28 | 1M | TRV |
| qwen/qwen3.7-max | new (unranked) | 1.25 | 3.75 | 1M | TR- |
| moonshotai/kimi-k2.7-code | new (code-tuned) | 0.74 | 3.50 | 262K | TRV |
| tencent/hy3 | new (unranked) | 0.20 | 0.80 | 262K | TR- |

Prices move; re-fetch at implementation time. Qwen 3.7 / Kimi K2.7 are too new for
leaderboards — treat as A/B candidates.

---

## 6. Cost per profile × model (blended, 87/13, EUR≈USD)

| Model | $/M blended | 15M (active) | 50M (power) |
|---|---|---|---|
| deepseek-v4-flash | 0.10 | €1.5 | €5 |
| minimax-m3 | 0.42 | €6.3 | €21 |
| qwen3.7-plus | 0.45 | €6.7 | €22 |
| deepseek-v4-pro | 0.49 | €7.3 | €24 |
| kimi-k2.6 | 1.02 | €15.3 | €51 |
| glm-5.2 | 1.20 | €18.0 | €60 |

---

## 7. Cap analysis — which plan for whom

| Month | Fits €16 (€20 plan)? | Fits €80 (€100 plan)? |
|---|---|---|
| 15M active on Flash/MiniMax/V4-Pro | yes | yes |
| 15M active on Kimi K2.6 | just barely (€15.3) | yes |
| 15M active on GLM 5.2 | **NO** (€18) | yes |
| 50M power on Flash | yes (€5) | yes |
| 50M power on V4-Pro | **NO** (€24) | yes |
| 50M power on GLM 5.2 | **NO** (€60) | yes (€60) |

Takeaways:
- **€20 / €16** = fine for cheap models or light use. Premium + active use maxes it —
  intentional; pushes heavy users to the €100 plan or cheaper models.
- **€100 / €80** = handles 50M power months even on the smartest model (GLM 5.2, €60).

---

## 8. Margin reality

- Cap-maxing power users → you get the **20% floor** by design.
- Casual/median users (€1–7 spend) → you keep **€13–19 of €20** (fat margin).
- Standard subscription economics: light users subsidize whales. Healthy as long as the
  mix holds. Monitor the ratio of cap-maxers to casuals.

---

## 9. Recommended defaults (guidance shown to user, not enforced)

**Verdict: `deepseek/deepseek-v4-pro` is the best all-round CoWork model.** Frontier
intelligence (AA Index 44; tops BenchLM at 87), output $0.87 = 3.4× cheaper than GLM 5.2,
1M context, input-heavy-friendly. Business-safe via DeepInfra (currently routes SiliconFlow
by default → must repin for business).

Tier ladder:

- **Standard default:** `deepseek/deepseek-v4-pro` — best intelligence-per-euro.
- **Premium (smartest), upsell on €100/€200:** `z-ai/glm-5.2` — only Index-51 open model,
  1M context. For users who want "the best".
- **Cheap / free tier:** `deepseek/deepseek-v4-flash` — Index 40 at $0.09/$0.18,
  effectively "unlimited". Beats Gemma at the same price on intelligence.
- **Vision work:** `minimax/minimax-m3` (frontier + vision + cheap) or `qwen3.7-plus`.
- **Avoid for CoWork:** Kimi K2.6/K2.7 (smart but expensive output eats margin on
  input-heavy multi-turn); Nemotron 550B (mid intel, high price); anything without tools.

### Google Gemma / Cerebras — evaluated, not recommended

- **Gemma on Cerebras:** NOT available via OpenRouter (0 Cerebras endpoints for any Gemma).
  Cerebras Cloud serves Gemma 4 31B directly, but only as a **free Preview model**
  (rate-limited, "eval only, may be discontinued on short notice") → unusable as a paid
  product backend. Cerebras hosts only 3 models total (gpt-oss-120b, gemma-4-31b, glm-4.7),
  all preview/free; its value is speed (~1850 tok/s), not price or stability.
- **Production Gemma (business-safe):** cheapest via DeepInfra — gemma-4-31b $0.12/$0.37,
  gemma-4-26b $0.07/$0.34.
- **Why skip Gemma for CoWork:** Gemma 4 26/31B are small dense models, below the frontier
  intelligence tier. `deepseek-v4-flash` ($0.09/$0.18) is smarter at the same price. Only
  pick Cerebras-Gemma if Google brand + extreme speed is a hard requirement — and the
  free-preview status rules it out for the backend anyway.

---

## 10. Live calculator spec (the "vorrechnen" feature)

Inputs: selected model (in/out price from live catalog), plan credits (€16 or €80),
user's estimated monthly tokens (default from their own history; fallback = profile presets).

Formula:
```
blended_usd_per_M = 0.87 * input_price_per_M + 0.13 * output_price_per_M
monthly_cost      = est_tokens_M * blended_usd_per_M
months_of_runway  = plan_credits / monthly_cost
tokens_for_credits = plan_credits / blended_usd_per_M      # "€80 ≈ N million tokens"
```

UI copy examples:
- Flash: "≈ 800M tokens — practically unlimited"
- GLM 5.2: "smartest model — €80 lasts ~1.3 months at your usage"

Use the user's **own** past blended rate when available (like the real €1.03/M for Kimi)
instead of the 87/13 estimate — it's more accurate and it's already tracked per model.

---

## 11. Business-safe routing (required for business users)

- OpenRouter account-level: enable **no prompt training** filter.
- Pin providers to US/EU business-grade: **DeepInfra, Together, Fireworks, Groq, Google,
  Cerebras**. DeepInfra usually carries the frontier models at the cheapest AND
  business-safe rate simultaneously.
- Avoid for business: Z.AI-direct, Alibaba, Baidu, Novita, SiliconFlow, GMICloud
  (Chinese origin → data residency / training risk; potential GDPR/legal cost).
- Note from real data: the anchor month routed Kimi via `fireworks/serverless` (fine) and
  V4-Pro via `siliconflow/fp8` (NOT business-safe — must be repinned for business tier).

---

## 12. Margin lever: prompt caching

Real month had only 13% cached. Cache reads cost a fraction of input price, and input is
90%+ of the bill. Raising cache hit rate (cache system prompt + tool defs + re-sent docs)
directly lowers real cost per token → higher margin at the same cap. Backend
`calculate_cost` is already cache-aware. This is the single biggest lever.

Also cap context, not messages: truncate/summarize history, limit doc re-injection.

---

## 13. Open decisions

- [ ] Create Stripe products for the €50 / €100 / €200 tiers (credits €40 / €80 / €160, 20% margin). €20/€16 already exists.
- [ ] Repin `deepseek-v4-pro` off SiliconFlow to a business-safe provider for the business tier.
- [ ] Decide model allow-list per plan tier (e.g. Flash on all; GLM 5.2 only on €100?).
- [ ] Define profile presets (Casual/Active/Power token defaults) for the calculator fallback.
- [ ] Set a fair-use throttle threshold above the cap (soft limit vs hard stop).
