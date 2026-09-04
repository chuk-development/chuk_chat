# Context management for the cowork agent — design notes

Notes to build later. This is the design as described across the 2026-09-03 and
2026-09-04 sessions, written down so it can be implemented in the cowork agent
(the text-only ChukChat `/v2/ws` backend + `ContextLadder`). The working
reference implementation of the image-side pieces lives in the separate repo
`github.com/chuk-development/computer-use-atspi`; this file is about bringing the
same context discipline into cowork.

This doc drives changes in `COWORK_AGENT_PLATFORM_PLAN.md` §2 (glossary), §4
(agent), §7.3 (context ladder), §12 (memory) and §16 (app). Where the two
disagree, this doc wins — it is the newer decision.

## 0. Product frame: one session per bot, no threads

The decision that makes context management the *whole* memory story:

- **One permanent session per bot. Full stop.** There are no threads, no "new
  chat", no session list. A bot is a coworker; you do not "start a new
  conversation" with a coworker. The plan already leaned this way
  (§16.1: "one canonical, permanent thread per agent", Hermes turns `/new` into
  `/compact`). We harden it: threads are **removed from the product entirely**,
  not hidden.
- **Why:** users are not power users. They do not want to file work into chats
  and threads and remember which thread had what. They want to talk to a bot and
  have the bot remember everything, forever — including things weeks old. The
  UI job is to make the bot feel like it never forgets, without ever asking the
  user to organise anything.
- **Consequence:** the single session runs effectively forever and grows past
  any context window. So the memory + compaction system below is not an
  optimisation — it is the load-bearing part that makes the no-threads product
  possible.

## 1. The problem

The naive fix for a full context window is: compact everything into one short
summary. That is lossy — you compress a huge context into a few sentences and
lose the detail (why a fix failed, how a component behaves, exact values). We do
not want that. With one infinite session per bot the naive fix is fatal: after a
week the bot would be running on a paragraph.

## 2. The hero model: a note-writing model that forgets nothing

The centre of the design. A **hero model** — a second, cheaper model running in
the background — is the bot's memory keeper. It reads the running context and
**writes notes**: all the important facts, decisions, values, "why X failed",
how a component behaves. It runs **per round** (each new message the agent
produces), so it only ever compacts the recent tail (~200k tokens), never the
whole million-token history at once.

The point of the hero model is **total recall**: nothing the bot has ever done
is truly gone. What leaves the active window is still on disk and still findable
(§4). The notes are the curated, always-shipped layer; the raw history is the
exact backstop.

### 2.1 Adaptive per-round compaction

- After each tool round the hero model updates the running notes in the
  background.
- Per next question the **main model decides whether to send the full tail or
  the compacted version.** The decision is made every round, not once at a fixed
  threshold.
- **Front stays verbatim, back gets compacted.** The early part (system prompt,
  the original job, recent relevant turns) is very likely still relevant, so it
  goes in full. The oldest turns are most likely irrelevant, so those get
  replaced by their compacted version first. Compacted versions ripple toward the
  back over time.
- This **breaks prompt-cache reuse** on the rewritten tail. Accepted cost — the
  models we run are cheap enough (≈$0.15/M in, $0.50/M out, cache hit ≈$0.03/M)
  that spending a small model on routing + compaction each round is worth it. To
  keep as much cache hit as possible, only rewrite the tail; keep a stable
  verbatim prefix (head).

This extends, not replaces, the §7.3 `ContextLadder`: the ladder's head+tail
token window and deterministic dedup/truncate pre-pass stay as the cheap first
tier; the hero model is the "cheap aux-model summarization" tier, now run every
round and feeding a persistent note store instead of a throwaway middle summary.

## 3. Memory layer: mem0 + exact search + self-written notes

Memory is solved with **three layers**, belt-and-suspenders, not one:

- **mem0 — the semantic recall layer.** mem0 extracts important facts, stores
  them as vectors, and retrieves the top-k by semantic similarity. This is what
  lets the bot answer "what did we decide about X weeks ago" without an exact
  keyword. This is the layer the product leans on for the "remembers everything"
  feel.
- **Exact full-text transcript search — the lossless backstop.** SQLite FTS5
  over the real message store (already specced in §12(B): main / CJK / trigram
  virtual tables, BM25, ±5 anchored messages + bookends). Literal search over the
  real past messages and tool outputs, so **nothing is actually deleted** — it
  just leaves the active window and can be pulled back *exactly* when needed. Used
  actively by the model as a tool, not a buried feature.
- **Hero-model notes — the curated layer** (§2): always shipped in context,
  grep-able, the model's own running summary.

**Why all three, honestly.** mem0 alone lands at ~90–95%, not 100%: what the
extractor missed is gone, and vector recall is fuzzy (near-miss). Plain
compaction is one lossy summary with no way back to the detail. So mem0 gives
reach (semantic), FTS5 gives precision (exact, never-lost), notes give a
cheap always-on summary. mem0 is the semantic index **on top of**, not a
replacement for, the exact transcript. This is the "best" tier from the earlier
draft — self-written notes **plus** exactly-searchable raw history — with mem0
added as the semantic front door. OpenAI described the same "search old chats,
used actively" pattern for their long-run harness (§6).

Note this reconciles the tension with §12(B), which argued raw anchored windows
beat an embeddings pipeline on cost/determinism. It still does — for exact
recall. mem0 sits above it for fuzzy recall, and the exact store remains the
source of truth, so a mem0 miss is recoverable.

## 4. Do not just compact — keep the raw history retrievable

The hard part is not summarizing, it is not losing what you summarized away.
Three levels, worst to best:

- Plain compaction: one lossy summary, no way back to the detail. **Rejected.**
- Embeddings / mem0 alone: top-k by similarity. ~90–95%; misses + near-miss.
  **Necessary but not sufficient** — hence layer 2.
- Best: self-written notes **plus** the raw context kept **exactly searchable**.
  Nothing deleted; it leaves the active window and is pulled back exactly on
  demand. This is the target.

## 5. Coding-specific: a living pseudocode / repo map

For code you cannot put the whole codebase in the model. A cheaper model writes
**pseudocode describing every function** (shorter to write than the function
itself), and the whole architecture is embedded as that compact pseudocode. Then
the agent knows exactly which real files to open, and does not forget that a
variable already exists or that something is duplicated. It reads the real code
only when it actually makes a change.

Partly built already: Aider's **repo map** (tree-sitter parses symbols, PageRank
over the symbol-reference graph ranks them, token-budgeted skeleton) is the
static version. The gap worth building is the **living, LLM-written, grep-able**
pseudocode map that updates itself as the code changes — the same hero-model
note-writing idea (§2) pointed at the codebase instead of the transcript.

## 6. OpenAI's approach (research — to confirm and cite)

Researched 2026-09-04 (OpenAI's own blog 403s to fetch; drawn from search
snippets + docs/third-party pages).

- **Newest model:** GPT-5.6 (2026-07-09). The long-run agent story lives in the
  **Codex** line — GPT-5.2-Codex and GPT-5.1-Codex-Max, billed for "long-running
  agents." GPT-5 family context window is 272k input / 128k output.
- **Native compaction is a trained model behavior, not a wrapper.** The model
  prunes its own history while preserving critical state, so one task spans
  **multiple context windows / millions of tokens**
  [gend.co/blog/gpt-5-1-codex-max-compaction; OpenAI Codex prompting guide].
  Complementary "response compaction" + session memory ship in the Agents SDK /
  Responses API. This validates §2 (a compaction step is the load-bearing part of
  a long single session) — OpenAI put it *inside* the model; we run it as a
  cheaper background hero model.
- **Verbatim searchable history, used actively.** GPT-5.5 Instant "can use its
  search tool to refer back to past conversations, files, and Gmail"
  [openai.com/index/introducing-gpt-5-5]. So their mix is: native compaction
  (lossy prune) + a search tool over prior transcripts (exact retrieval) +
  AGENTS.md notes. Exactly our three layers (§3): compaction/notes + exact
  search, plus mem0 as the semantic front door.
- **Prompt cache and tail rewrite are in tension — confirmed.** Cache reuse needs
  the whole rendered prefix to match (append-only); any compaction/truncation
  changes the prefix and resets reuse from that point (causal attention
  reprocesses everything downstream) [developers.openai.com/api/docs/guides/
  prompt-caching]. This is exactly the cost §2.1 accepts. Mitigation is the same:
  stable head first, dynamic/compacted content last.
- **mem0 numbers:** fact extraction → vector store → multi-signal retrieval
  (semantic + keyword + entity, fused), ADD-only, temporal rerank. Scores 92.5
  LoCoMo, 94.4 LongMemEval, **but ~72.7 on open-domain retrieval** — the weak
  spot, and the reason we keep the exact FTS5 store as the backstop (§3). ~3–4×
  lower token cost than full-context [mem0.ai/research].
- **Aider repo map:** tree-sitter parses defs/refs across 130+ langs → symbol
  graph (files = nodes, references = edges) → **personalized PageRank** (restart
  vector biased to chat/edited files) ranks symbols → top-N skeleton packed into a
  token budget (`--map-tokens`, default 1k) [aider.chat/2023/10/22/repomap.html].
  Confirms §5's static version.

## 7. Large content (images, big blobs): on disk, pulled on demand

From the computer-use side, generalizes to cowork:

- Keep large content (screenshots, big tool outputs) **on disk**, not permanently
  in the prompt. Keep only the last N in context as a sliding window.
- Even better, let the model **pull** specific items on demand by id, instead of
  us pushing a fixed window. It reads them for one turn, extracts what it needs as
  text, and they drop out again. Each turn it decides fresh what it needs.
- Do NOT merge two images into one to save room — it halves resolution and only
  postpones the cap. Drop old ones entirely.

## 8. Debug: a copy-the-raw-chat button

Because the real context is rewritten every round (notes swapped in, tail
compacted, blobs pulled), what the model actually sees diverges from the pretty
chat transcript. We need to inspect that.

- **A debug "copy chat" button in the UI** that copies the **exact raw context
  as sent to the model this round** — full system prompt, the verbatim head, the
  compacted tail, the injected notes, the pulled blobs' ids — to the clipboard.
- This is the debugging surface for the whole compaction system: when the bot
  forgets something it should not have, you copy the raw context and see whether
  the fact was in the notes, recoverable via search, or genuinely dropped.
- Cheap to build (the context assembler already produces this payload); ship it
  early.

## 9. Self-description: "what skills and MCPs do you have?"

A bot must answer "what can you do / what tools do you have" by listing its
**loadable markdown skills (name + description)** and its **connected MCP
servers** — not by narrating "I can write Python." The bot ships with the same
skills and the same MCP servers as ChukChat (we already bundle them). So:

- The always-on prompt already carries every skill's `name` + `description`
  (progressive disclosure, §11) and the connected MCP server list. The
  self-description answer reads straight from those, so "what can you do" returns
  the real, current skill + MCP inventory, not a generic capability boast.
- Fix the current wrong behavior where the bot answers that kind of question with
  its language/runtime abilities instead of its actual skill and MCP surface.

## 10. UI: a ChukChat clone with bots instead of chat links

The cowork chat UI **looks exactly like ChukChat**. The one structural change:

- **The sidebar lists bots, not chat links.** Where ChukChat shows a list of
  conversations, cowork shows the **roster of bots** (§16.1: sidebar tab strip,
  avatar + latest-message preview + status). No thread list under a bot, because
  there are no threads (§0).
- **Same MCP servers, same skills** as ChukChat, bundled and shipped.
- The cowork app stays **minimal for now but built at real scale** — these
  pieces (chat UI, skills, MCP servers, model routing) are **copied first** from
  ChukChat, then trimmed, rather than reinvented.

## 10a. Status — built and validated (2026-09-04)

Built this session and proven on the real backend (`deepseek-v4-flash`):

- **Hero compaction on by default.** The executor builds a cheap same-model aux
  via `BackendModelClient.cheap_clone()` (`reasoning_effort="none"`, small
  `max_tokens`) and passes it as `aux_model`, so the context ladder's tier-2/3
  summary and mem0 extraction run every round on the cheap clone. Live long-run
  proof (`agent/tests/live_long_context.py`): over a shrunk budget, tier-2 fired
  round 5 (4378→3748 tokens) and tier-3 round 6 (4506→3876), and the early fact
  was recalled across compaction — final answer "BLUEFALCON, 2026-11-15".
- **Reasoning OFF is the right hero setting — measured.** With `reasoning="none"`
  the summarizer captured the fact into the template; with `reasoning="low"` it
  over-applied the redaction rule and `[REDACTED]`-ed the (non-secret) codename.
  So the cheap, reasoning-off clone is not just cheaper, it summarizes better.
- **mem0 works end to end.** It failed silently before: mem0 2.0.x validates
  `llm.provider` against a hardcoded allowlist *before* the factory, so the custom
  `chukbackend` name was rejected. Fixed by registering the provider under an
  allowlisted, unused alias (`lmstudio`). The embedder falls back to local
  fastembed when no proxy embed key is set, so memory works out of the box. Live
  add/search recalled "codename BLUEFALCON ... launch date of November 15, 2026".
- **Tool calls are native-only (52d429d).** The `<tool_call>` text protocol is
  removed from the Python runtime; tools ride as OpenAI `tools[]` and come back
  as the server's `tool_calls` frame (contract: chuk_chat
  `docs/NATIVE_TOOL_CALLING.md`, `docs/WIRE_CONTRACT.md`). The earlier gap —
  `deepseek-v4-flash` emitting `<｜DSML｜tool_call>` that the text parser missed,
  so a `memory.search` went unexecuted — is structurally gone: model text is never
  parsed for calls. The hero `cheap_clone` carries no tools (housekeeping turns
  must not call tools). Per-task `model`/`provider`/`reasoning_effort` reach the
  `BackendModelClient`, so Fast Mode (light model + low/none reasoning) works.

- **mem0 survives the second task (50f114c, bb5239a).** Found by a two-task
  proof: the executor builds a fresh `MemoryStore` per task on the same
  workspace, and the embedded local-path Qdrant refused the second open
  ("already accessed by another instance") — memory silently became a no-op from
  task 2 on. Fix: one `Memory` handle per workspace root, process-wide, with the
  writer client re-pointed per task and `close_cached_memories()` called from
  `Executor.stop()`. `agent/tests/live_memory_two_tasks.py` is the proof; it
  passes.
- **Review discipline.** An Opus full review found 8 defects (one blocker: an
  exception while building a task's model killed the executor's worker thread
  for good); all fixed and re-verified read-only by a second Opus pass. Keep
  doing this: build → review → fix → re-verify, with real-model probes on the
  load-bearing paths.

## 11. How this maps onto cowork today

- Backend is text-only ChukChat `/v2/ws`; the only current trimming is the
  `ContextLadder` (token-budget head+tail window). This design extends it: add
  the hero-model note-writer (§2), the mem0 semantic layer + searchable
  transcript index (§3), and make the ladder decide per-round full-vs-compacted
  for the tail.
- The image/large-blob part matters wherever a tool returns big output; the
  on-disk + pull-on-demand pattern (§7) keeps the text budget small.
- Product-level: remove threads (§0), sidebar shows bots (§10), add the debug
  copy button (§8), and fix self-description (§9).
