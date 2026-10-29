# chuk-agents-sandbox

The Agents execution sandbox. A `BaseEnvironment` ABC with snapshot-file session
persistence (design borrowed from Hermes Agent, MIT, reimplemented here), plus
`LocalEnvironment` and `DockerEnvironment` backends and a `make_environment`
factory. See `docs/AGENTS_AGENT_PLATFORM_PLAN.md` section 6.

```python
from chuk_agents_sandbox import make_environment

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

## The box browser: look like a normal Chrome

Sites such as PayPal answer an automated browser with endless captchas. The
box browser (`docker/browser-mcp.sh`, image `agents-browser:latest`) is set up
to look like a normal desktop Chrome on Linux. The details, the measurements
and the traps are in the comment blocks of `docker/browser-mcp.sh` and
`docker/webgl-mesa.js`. Measure after every change:

```bash
docker run --rm --entrypoint sh -e TZ=Europe/Berlin -e AGENTS_BROWSER_LOCALE=de-DE \
    -v "$PWD/docker/fingerprint-probe.py:/probe.py:ro" agents-browser:latest -c "python3 /probe.py"
```

Add `--gpus all,capabilities=graphics` to measure the GPU path.

What the host sets when it creates a box (`docker.py`):

| Setting | Default | Why |
|---|---|---|
| `AGENTS_BROWSER_TIMEZONE` | the host's zone | The browser's zone must fit the user's IP. **Set it on a server that runs in UTC** (a VPS), for example `Europe/Berlin`. |
| `AGENTS_BROWSER_LOCALE` | the host's `LANG` | Chrome builds Accept-Language and navigator.languages from it. Set it on a server with `LANG=C.UTF-8` (otherwise `en-US`). |
| `AGENTS_SANDBOX_GPU` | `auto` | With an NVIDIA GPU and the NVIDIA runtime, the box gets the GPU and WebGL names the real card. `0` = never. |

A box is made again on its next new session when its browser revision
(image label `dev.chuk.agents.browser-revision`) or its GPU decision changed,
and only when no `docker exec` runs in it.

### A host with no GPU (a VPS, a headless server)

The usual host has no GPU. Chrome then draws WebGL with SwiftShader, and
`docker/webgl-mesa.js` (an init script) makes the page report an Intel UHD 620
on Mesa instead. That hides the renderer string from simple checks, but not
everything: the rendered pixels are still SwiftShader's, a worker still sees
SwiftShader, and creepjs reports "40% stealth" (it finds the patched
`toString` and the main/worker mismatch). Measured with a GPU: 0% stealth.

`hardwareConcurrency` and `deviceMemory` are the real values of the machine.
A small VPS reports 2 cores and 2 GB. They are not changed: an init script
does not reach workers, so a changed value disagrees with the worker's value,
and that mismatch is a stronger tell than a small machine.

### The main risk left: the IP

A VPS has a datacenter IP. Sites check the IP against ASN lists, and a
datacenter IP gets captchas whatever the browser does. The browser cannot fix
that. Today there is no proxy setting in the configuration
(`chuk_agents_config`). The way out is a host at home (a residential IP), or
a residential proxy for the box browser. That needs a new setting, for
example a `--proxy-server` for `browser-mcp.sh`.
