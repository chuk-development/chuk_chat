# chuk-agents-memory

The Hindsight memory sidecar of the Agents host
([Hindsight](https://github.com/vectorize-io/hindsight), MIT). It runs
embedded Postgres (pg0 with pgvector) and the Hindsight API as one process tree,
bound to loopback. It lives in its own virtual environment because Hindsight
pulls a large dependency tree (litellm, boto3, google-genai, fastmcp, ...) that
must not share a resolver with the host.

You do not start it yourself. With `memory.backend = hindsight`
(`AGENTS_MEM_BACKEND=hindsight`) the host configures one
`HindsightService` (`agents/runtime/src/chuk_agents_runtime/hindsight_service.py`)
at start. The first memory use starts this sidecar, and the host supervises it
until it stops.

```bash
cd agents/memory && uv sync          # once; the host runs .venv/bin/python -m chuk_agents_memory
uv run pytest -q                     # the launcher's own tests
```

Without a synced `.venv`, the host falls back to
`uv run --project agents/memory --frozen`, which creates the environment on
the first start.

## How it fits together

```
host process                                   sidecar (this project)
HindsightService ──spawn──▶ chuk_agents_memory.launcher
  MemoryGateway 127.0.0.1:<rand>                 ├ pg0: <state_home>/hindsight/pg0
    /v1/embeddings ──▶ api.chuk.chat/v1/embeddings   (live JWT, qwen3-embedding-8b @ 1024)
    /v1/chat/completions ──▶ api.chuk.chat/v1/chat/completions   (live JWT, deepseek-v4-flash, reasoning off, 8192 tokens)
  HindsightAPI (httpx) ─────────────────────────▶└ Hindsight API 127.0.0.1:<rand>
```

- **Data:** everything is under `<state_home>/hindsight/` (default
  `~/.local/share/chuk-agents/hindsight/`): `pg0/` (the database),
  `home/` (the sidecar's `HOME`: pg0's registry and extracted binaries),
  `pg0.secret` (the database password, mode 0600), `embedding.json` (the
  embedding stamp), `imports.json` (the one-time Mem0 import record),
  `sidecar.lock` (one sidecar per state directory), `sidecar.log` (rotated,
  5 MB x 3) and `sidecar.out` (raw stdout/stderr). None of it is inside an
  agent workspace, so no sandbox container mounts it.
- **Secrets:** the gateway and the Hindsight API each have their own random
  bearer, minted per host process. Docker's bridge network cannot reach host
  loopback. The account token only goes to `https://api.chuk.chat`: any other
  `memory.embed_base_url` disables memory, and `memory.embed_api_key_ref` is
  refused with a clear error.
- **Known gap (bead chuk_chat-lybg):** pg0 has no password file or env
  option, so the database password is visible in `ps` for the moment
  `pg0 start` (and its internal `psql` calls) run. Postgres binds loopback
  only.
- **Logs:** no memory content. Only known-safe loggers keep their text; the
  rest (Hindsight's engine logs LLM output on a parse error, litellm, openai,
  httpx) is reduced to logger, level and exception type. Postgres does not log
  failing statements.
- **Egress:** the sidecar talks only to the gateway and its own Postgres.
  litellm's price-map download and Hugging Face are switched off. The gateway
  talks only to `api.chuk.chat`.
- **Limits:** at most 20 memory requests (model and embeddings together) in any
  minute (`AGENTS_MEM_RATE_PER_MINUTE`). The account allows 60 of each, and the
  agent's own turns come first. Four of the 20 are kept for foreground recalls,
  which carry a one-time ticket from the host (consolidation's own searches do
  not). Above 500 pending operations in a bank, automatic turn retains are
  dropped; `memory_add` still goes through.
- **Budgets:** one chat call spends at most 210 s in the gateway (slot wait
  plus upstream), below the sidecar's 240 s LLM timeout, and failed calls are
  retried once — so a slow call is not billed twice by a timeout race.
- **Health:** a ready sidecar is probed every 30 s; two misses in a row mark
  memory degraded and restart the sidecar with backoff.
- **Embedding stamp:** `embedding.json` records the model, the dimension and
  the query prefix. Other settings later make the service refuse to start
  (memory becomes a no-op) instead of mixing two vector spaces. To change the
  embedder, re-embed first (see below).
- **Reranker:** `rrf` (no model). No reflect calls are made.
- **Import:** an agent's old Mem0 facts (`<workspace>/memory/qdrant`) are
  retained once, in the background, and the folder is then renamed to
  `qdrant.migrated-<date>` (the backup). The folder is inside the agent's
  writable workspace, so it is treated as hostile: the host never unpickles
  it. `mem0_legacy_reader.py` runs as `python -I -S -B` with an empty
  environment, resource limits and `O_NOFOLLOW` path walking, resolves only
  Qdrant's `PointStruct`/`SparseVector` to inert stand-ins, and prints JSON;
  any other pickle global refuses the whole store. The attempt is recorded in
  `imports.json` before the folder is read, so each bank gets exactly one
  attempt (a crash counts). To allow one more try, delete the bank's entry.

## Re-embedding (changing model or dimension)

There is no automatic re-embed yet. Until there is: stop the host, move
`<state_home>/hindsight` aside, start the host with the new settings. The
agents start with empty banks. The old `qdrant.migrated-*` folders are not
imported again.

## Step 9: removing Mem0 (after the owner has used Hindsight)

Do this only when the owner says Hindsight is good, and not before. Each box is
one small change with its own green test run.

- [ ] Flip nothing back: confirm `AGENTS_MEM_BACKEND` defaults to `hindsight`
      and that no install overrides it to `mem0`.
- [ ] Delete `agents/runtime/src/chuk_agents_runtime/mem0_provider.py`.
- [ ] In `memory.py`, delete the Mem0 paths: `_build_config`, `_memory`,
      `_add_messages`, `_MEM_LOCK`/`_MEM_BY_ROOT`/`_OP_LOCK`, the extraction
      threads (`wait_for_extractions`, `_EXTRACT_*`), the `MEM0_TELEMETRY`
      default, and the `_EMBED_*`/`_FASTEMBED_*`/`_COLLECTION`/`_QDRANT_DIRNAME`
      constants. Keep the static persona files, `scan`/`neutralize`, the tool
      schemas and `register_memory_tool`. Fold `HindsightMemoryStore` into
      `MemoryStore` (or keep it and let `make_memory_store` return it always).
- [ ] `close_cached_memories()` becomes `drain_retains()`; update the
      executor's teardown call.
- [ ] Remove `mem0ai` and `fastembed` from `agents/runtime/pyproject.toml`,
      then `uv lock` in runtime, executor and host.
- [ ] Delete `tests/test_memory_mem0.py`, `tests/live_memory_recall.py`,
      `tests/live_memory_two_tasks.py`. Drop the `AGENTS_MEM_BACKEND=mem0`
      pins in `tests/test_memory_runtime.py` and
      `tests/test_memory_recall_latency.py` (or delete the Mem0-only cases).
- [ ] In `chuk_agents_config/schema.py` (and its README table), delete
      `memory.collection`, `memory.user_id`, `memory.qdrant_dirname`,
      `memory.llm_model`, `memory.embed_provider`, `memory.embed_api_key_ref`,
      `memory.fastembed_model`, `memory.fastembed_dims`; drop `mem0` from
      `memory.backend` choices (or the setting entirely). Move
      `AGENTS_MEM_EMBED_API_KEY` out of `NOT_CONFIG`.
      `memory.qdrant_dirname` and `memory.collection` are still read by the
      import, so delete them together with the import (last box).
- [ ] Update `docs/PERSONAL_AGENT_SPEC.md` (it still says "mem0").
- [ ] After every agent's `qdrant` folder is `qdrant.migrated-*` and the owner
      agrees: delete the `qdrant.migrated-*` backups and the import code
      (`mem0_legacy_reader.py`, `read_legacy_facts`, `read_mem0_facts`,
      `import_items`, `migrate_mem0`, `start_mem0_import`, `imports.json`,
      `memory.import_mem0`).
- [ ] Removing the Mem0 backend also closes bead chuk_chat-f3z0 (the Mem0
      store unpickles its workspace folder in the host).
