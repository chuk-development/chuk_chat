# chuk-agents-executor

The executor vertical. It joins three foundation packages into one runnable,
fully local, encrypted end-to-end:

- **`chuk_agents_runtime`** — the agent loop, tools, state, model client.
- **`chuk_agents_sandbox`** — the `BaseEnvironment` sandbox that actually runs shell.
- **`chuk_agents_crypto`** — the sealed Agents frame (AES-256-GCM + Ed25519 + X25519).
- **`chuk_agents_manager`** — the relay frame contract and the supervisor ABC.

See the module docstrings for the wiring. There is **no network** here — the
production relay is out of scope. A loopback transport links a controller
endpoint and an executor endpoint in one process.
