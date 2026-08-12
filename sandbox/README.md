# cowork-sandbox

The CoWork execution sandbox. A `BaseEnvironment` ABC with snapshot-file session
persistence (design borrowed from Hermes Agent, MIT, reimplemented here), plus
`LocalEnvironment` and `DockerEnvironment` backends and a `make_environment`
factory. See `docs/COWORK_AGENT_PLATFORM_PLAN.md` section 6.

```python
from cowork_sandbox import make_environment

with make_environment("local") as env:          # or "docker"
    env.run("export FOO=bar && cd /tmp")
    print(env.run("echo $FOO @ $(pwd)").stdout)  # bar @ /tmp
```

Env vars, aliases, functions and the working directory survive across calls
without a long-lived shell: each `run` sources a snapshot, runs the command in a
fresh `bash`, re-dumps the session, and swaps the snapshot atomically.

`BaseEnvironment.run_bash(cmd, *, timeout=120) -> ProcessResult` satisfies the
`Environment` protocol the sibling `../agent` runtime consumes.

```bash
uv run pytest        # docker tests self-skip when the daemon is absent
```
