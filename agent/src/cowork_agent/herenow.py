"""here.now publishing — an approval-gated, first-class publish tool.

here.now (https://here.now) turns a file or a folder into a live public URL in
seconds. This module is the agent-side half of a Cowork *connector*: a single
tool, ``herenow_publish``, that lifts a path out of the sandbox onto the public
web and hands the user back a URL.

Two properties make this different from every other tool in the registry, and
both are deliberate:

1. **It is off unless the user turned it on.** The tool is registered only when
   :class:`HereNowConfig` says ``enabled`` — the executor sets that from a
   setting the user flipped in the app. A disabled connector is not a hidden
   tool; it does not exist, so the model has no way to reach here.now at all
   (§11 / the MCP-connector precedent).

2. **A public publish needs the user's yes.** Publishing puts content on the
   open internet under a URL anyone can open — an outward-facing, effectively
   irreversible act. So in the default ``ask`` mode the tool does not publish
   until an :data:`ApprovalGate` returns approval: the executor turns that call
   into an ``approval_request`` event the app shows, and blocks the run until
   the user taps Approve or Deny. ``auto`` mode is the escape hatch the user
   opts into in settings when they do not want to be asked each time.

**Free tier only (v1).** Without an API key here.now creates an *anonymous*
site that anyone with the link can view and that **expires 24 hours** after it
is made. That expiry is not a detail to hide — the tool states it in its own
schema and in every result, so the model tells the user their link is
temporary.

**Honest boundary.** The gate governs *this tool*. A sandbox has a shell and a
network, so a determined model could in principle POST to here.now itself and
skip the gate — the same is true of any connector in any agent product. The
guarantee here is product-level: the sanctioned, always-present here.now
capability is gated, and when the connector is off nothing about here.now is in
the prompt at all. The skill text tells the model to publish only through this
tool.

The publish mechanics are a small, dependency-free Python program
(:data:`PUBLISHER`) run *inside the sandbox*, where the files and the network
egress are. It speaks the public three-step flow directly — ``POST
/api/v1/publish`` for presigned upload targets, ``PUT`` each file's bytes,
``POST`` the returned finalize URL — using only the standard library, so it
needs no ``curl``/``jq`` and no here.now helper scripts baked into the image.
"""

from __future__ import annotations

import json
import shlex
from collections.abc import Callable
from dataclasses import dataclass

from .environment import Environment
from .registry import ToolRegistry

DEFAULT_BASE_URL = "https://here.now"
DEFAULT_CLIENT = "cowork/herenow-tool"

#: Safety ceilings for one publish, checked in the sandbox scan before anything
#: leaves it. Anonymous sites are for artifacts and small static pages, not for
#: shipping a media library; past these the model should send a file instead.
MAX_TOTAL_BYTES = 40 * 1024 * 1024
MAX_FILE_COUNT = 2000


@dataclass(frozen=True)
class HereNowConfig:
    """Whether and how this run may publish to here.now.

    ``enabled`` gates registration entirely (a False config never reaches the
    prompt). ``approval`` is the policy the tool applies before a public
    publish: ``"ask"`` routes through the :data:`ApprovalGate`; ``"auto"``
    publishes without asking. ``client`` is the attribution string sent as
    ``X-HereNow-Client``; ``base_url`` is the API root (overridable for tests).
    """

    enabled: bool = False
    approval: str = "ask"
    client: str = DEFAULT_CLIENT
    base_url: str = DEFAULT_BASE_URL

    @property
    def asks(self) -> bool:
        """True when a public publish must clear the approval gate first."""
        return self.approval != "auto"

    @classmethod
    def from_entry(cls, entry: object) -> "HereNowConfig":
        """Build from the loosely-typed dict the app forwards on the task frame.

        Anything malformed collapses to a disabled config — a broken setting
        must never accidentally *enable* publishing.
        """
        if not isinstance(entry, dict):
            return cls(enabled=False)
        enabled = bool(entry.get("enabled", False))
        approval = str(entry.get("approval", "ask") or "ask").lower()
        if approval not in ("ask", "auto"):
            approval = "ask"
        client = str(entry.get("client") or DEFAULT_CLIENT)
        base_url = str(entry.get("base_url") or DEFAULT_BASE_URL).rstrip("/")
        return cls(
            enabled=enabled,
            approval=approval,
            client=client,
            base_url=base_url or DEFAULT_BASE_URL,
        )


@dataclass(frozen=True)
class PublishRequest:
    """What the user is being asked to approve: a public publish of ``path``.

    Carries just enough for a human to decide — what is going out, how big,
    where. ``public`` is always True in v1 (anonymous sites are open links);
    the field is explicit so a later private/authenticated mode reads naturally.
    """

    path: str
    name: str
    file_count: int
    total_bytes: int
    base_url: str
    public: bool = True


#: The executor binds this to an ``approval_request`` round-trip: it blocks the
#: run and returns True (approve) or False (deny). A gate that returns False, or
#: is absent when the policy needs one, means "do not publish".
ApprovalGate = Callable[[PublishRequest], bool]


class HereNowError(RuntimeError):
    """A publish could not be carried out (scan or publish step failed)."""


# --------------------------------------------------------------------------
# The in-sandbox publisher. stdlib only; MODE=scan prints a summary, MODE=publish
# runs the three-step flow and prints the resulting URL as one JSON line.
# --------------------------------------------------------------------------
PUBLISHER = r'''
import json, mimetypes, os, sys, urllib.request, urllib.error
from pathlib import Path

MODE = os.environ["HN_MODE"]
TARGET = Path(os.environ["HN_PATH"]).expanduser()
BASE = os.environ.get("HN_BASE", "https://here.now").rstrip("/")
CLIENT = os.environ.get("HN_CLIENT", "cowork/herenow-tool")
MAX_TOTAL = int(os.environ.get("HN_MAX_TOTAL", "0") or "0")
MAX_FILES = int(os.environ.get("HN_MAX_FILES", "0") or "0")


def emit(obj):
    sys.stdout.write("HN_RESULT " + json.dumps(obj) + "\n")
    sys.stdout.flush()


def fail(msg):
    emit({"ok": False, "error": str(msg)})
    raise SystemExit(0)


if not TARGET.exists():
    fail("path does not exist: %s" % TARGET)

# Collect the files to publish and their site-relative paths. A single file
# becomes one site path (its own name); a directory contributes every file
# under it, keyed by its path relative to the directory root.
entries = []  # (site_path, absolute_file)
if TARGET.is_file():
    entries.append((TARGET.name, TARGET))
else:
    for fp in sorted(TARGET.rglob("*")):
        if fp.is_file() and not fp.is_symlink():
            rel = fp.relative_to(TARGET).as_posix()
            entries.append((rel, fp))

if not entries:
    fail("nothing to publish under %s" % TARGET)

total = 0
files = []
for site_path, fp in entries:
    try:
        size = fp.stat().st_size
    except OSError as exc:
        fail("cannot read %s: %s" % (site_path, exc))
    total += size
    ctype = mimetypes.guess_type(site_path)[0] or "application/octet-stream"
    files.append({"path": site_path, "size": size, "contentType": ctype})

if MAX_FILES and len(files) > MAX_FILES:
    fail("too many files: %d (limit %d)" % (len(files), MAX_FILES))
if MAX_TOTAL and total > MAX_TOTAL:
    fail("too large: %d bytes (limit %d)" % (total, MAX_TOTAL))

has_index = any(f["path"] == "index.html" for f in files)

if MODE == "scan":
    emit({
        "ok": True,
        "file_count": len(files),
        "total_bytes": total,
        "has_index": has_index,
        "paths": [f["path"] for f in files[:20]],
    })
    raise SystemExit(0)


def request(method, url, *, body=None, headers=None):
    data = None
    hdrs = dict(headers or {})
    if body is not None and not isinstance(body, (bytes, bytearray)):
        data = json.dumps(body).encode("utf-8")
        hdrs.setdefault("content-type", "application/json")
    else:
        data = body
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:400]
        except Exception:
            pass
        fail("%s %s -> HTTP %s %s" % (method, url, exc.code, detail))
    except urllib.error.URLError as exc:
        fail("%s %s -> %s" % (method, url, exc.reason))
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        return {}


SPA = os.environ.get("HN_SPA", "") == "1"
NAME = os.environ.get("HN_NAME", "").strip()
DESC = os.environ.get("HN_DESC", "").strip()

create_body = {"files": files, "spaMode": SPA}
if NAME:
    create_body["displayName"] = NAME
    create_body["viewer"] = {"title": NAME}
if DESC:
    create_body["displayDescription"] = DESC
    create_body.setdefault("viewer", {})["description"] = DESC

client_hdr = {"X-HereNow-Client": CLIENT + "/publisher"}
created = request("POST", BASE + "/api/v1/publish", body=create_body, headers=client_hdr)

upload = created.get("upload") or {}
version_id = upload.get("versionId")
targets = upload.get("uploads") or []
finalize_url = upload.get("finalizeUrl")
by_path = {f["path"]: fp for (f, (_, fp)) in zip(files, entries)}

for t in targets:
    site_path = t.get("path")
    fp = by_path.get(site_path)
    if fp is None:
        continue
    with open(fp, "rb") as fh:
        payload = fh.read()
    request(t.get("method", "PUT"), t["url"], body=payload, headers=t.get("headers") or {})

if finalize_url:
    if finalize_url.startswith("/"):
        finalize_url = BASE + finalize_url
    finalized = request("POST", finalize_url, body={"versionId": version_id}, headers=client_hdr)
else:
    finalized = {}

site_url = finalized.get("siteUrl") or created.get("siteUrl") or ""
emit({
    "ok": True,
    "url": site_url,
    "slug": created.get("slug"),
    "anonymous": bool(created.get("anonymous", True)),
    "expires_at": created.get("expiresAt"),
    "claim_url": created.get("claimUrl"),
    "file_count": len(files),
    "total_bytes": total,
})
'''


PUBLISH_SCHEMA = {
    "type": "object",
    "description": (
        "Publish a file or a folder from the workspace to here.now and get back "
        "a live public URL the user can open in a browser. Use it when the user "
        "asks to publish, host, deploy, or share something on the web — an HTML "
        "page, a report, a chart, a bundle of static files.\n\n"
        "IMPORTANT, tell the user both:\n"
        "- The site is PUBLIC: anyone with the link can view it.\n"
        "- It is anonymous and EXPIRES 24 HOURS after publishing (free tier). "
        "The result includes a claim URL that keeps it permanently.\n\n"
        "For an HTML site, put index.html at the ROOT of the folder you pass "
        "(publish the folder that directly contains index.html, not its parent). "
        "A single non-HTML file is served with an auto-viewer. This is the only "
        "sanctioned way to publish; do not POST to here.now by hand. Publishing "
        "may require the user to approve it first."
    ),
    "properties": {
        "path": {
            "type": "string",
            "description": (
                "Workspace path to publish: a folder (its contents become the "
                "site root) or a single file. Relative to the workspace or "
                "absolute. Write the files first; they must already exist."
            ),
        },
        "name": {
            "type": "string",
            "description": "Optional title shown to visitors and in the viewer.",
        },
        "description": {
            "type": "string",
            "description": "Optional short description shown in the viewer.",
        },
        "spa": {
            "type": "boolean",
            "description": (
                "Optional. Enable single-page-app routing (serve index.html for "
                "unknown paths). Only for client-routed apps."
            ),
        },
    },
    "required": ["path"],
}


def _run_publisher(env: Environment, mode: str, config: HereNowConfig, args: dict) -> dict:
    """Run the embedded publisher in the sandbox and return its parsed result.

    Parameters are passed as environment variables, never interpolated into the
    script, so a path with a quote or a newline cannot break out. The publisher
    prints exactly one ``HN_RESULT <json>`` line; anything else is diagnostic.
    """
    envvars = {
        "HN_MODE": mode,
        "HN_PATH": str(args.get("path", "")),
        "HN_BASE": config.base_url,
        "HN_CLIENT": config.client,
        "HN_MAX_TOTAL": str(MAX_TOTAL_BYTES),
        "HN_MAX_FILES": str(MAX_FILE_COUNT),
        "HN_SPA": "1" if args.get("spa") else "0",
        "HN_NAME": str(args.get("name") or ""),
        "HN_DESC": str(args.get("description") or ""),
    }
    exports = " ".join(f"{k}={shlex.quote(v)}" for k, v in envvars.items())
    # Prefer python3; fall back to python. The script is fed on stdin so the
    # source never touches the argv or a temp file.
    cmd = (
        f"{exports} "
        "sh -c 'command -v python3 >/dev/null 2>&1 && exec python3 - || exec python -' "
        "<<'HN_EOF'\n" + PUBLISHER + "\nHN_EOF"
    )
    result = env.run_bash(cmd, timeout=180)
    for line in reversed(result.stdout.splitlines()):
        if line.startswith("HN_RESULT "):
            try:
                return json.loads(line[len("HN_RESULT "):])
            except ValueError:
                break
    tail = (result.stderr or result.stdout or "").strip()[-400:]
    raise HereNowError(
        f"here.now {mode} failed (exit {result.exit_code}): {tail or 'no output'}"
    )


def make_publish_handler(
    env: Environment, config: HereNowConfig, gate: ApprovalGate | None
):
    """Build the ``herenow_publish`` handler.

    The order is scan -> approve -> publish: the scan measures what would go out
    so the approval prompt is honest about it, the gate decides, and only an
    approval (or ``auto`` mode) reaches the publish step.
    """

    def herenow_publish(
        path: str,
        name: str | None = None,
        description: str | None = None,
        spa: bool = False,
    ) -> dict:
        text_path = (path or "").strip()
        if not text_path:
            return {"ok": False, "error": "path is empty"}
        args = {"path": text_path, "name": name, "description": description, "spa": spa}

        try:
            scan = _run_publisher(env, "scan", config, args)
        except HereNowError as exc:
            return {"ok": False, "path": text_path, "error": str(exc)}
        if not scan.get("ok"):
            return {"ok": False, "path": text_path, "error": scan.get("error", "scan failed")}

        # Approval policy. ``auto`` publishes straight through; ``ask`` must
        # clear the gate, and with no gate bound (an unattended run, no user to
        # ask) the safe answer is no.
        if config.asks:
            if gate is None:
                return {
                    "ok": False,
                    "path": text_path,
                    "error": (
                        "publishing needs your approval, but no one is available "
                        "to approve it in this run. Ask the user to publish it "
                        "interactively, or enable auto-approve in settings."
                    ),
                }
            request = PublishRequest(
                path=text_path,
                name=(name or "").strip() or text_path,
                file_count=int(scan.get("file_count", 0)),
                total_bytes=int(scan.get("total_bytes", 0)),
                base_url=config.base_url,
            )
            try:
                approved = bool(gate(request))
            except Exception as exc:  # noqa: BLE001 — a gate failure is a denial
                return {
                    "ok": False,
                    "path": text_path,
                    "error": f"approval failed: {type(exc).__name__}: {exc}",
                }
            if not approved:
                return {
                    "ok": False,
                    "path": text_path,
                    "declined": True,
                    "error": "the user declined to publish this.",
                }

        try:
            published = _run_publisher(env, "publish", config, args)
        except HereNowError as exc:
            return {"ok": False, "path": text_path, "error": str(exc)}
        if not published.get("ok"):
            return {"ok": False, "path": text_path, "error": published.get("error", "publish failed")}

        url = published.get("url") or ""
        anonymous = bool(published.get("anonymous", True))
        result = {
            "ok": True,
            "path": text_path,
            "url": url,
            "public": True,
            "anonymous": anonymous,
            "file_count": published.get("file_count"),
        }
        if anonymous:
            result["expires_at"] = published.get("expires_at")
            result["claim_url"] = published.get("claim_url")
            result["note"] = (
                "This site is public and anonymous: it expires 24 hours after "
                "publishing. Share the claim URL with the user to keep it "
                "permanently. Tell the user the URL and that it is temporary."
            )
        else:
            result["note"] = "This site is public. Tell the user the URL."
        return result

    return herenow_publish


def register_herenow_tools(
    registry: ToolRegistry,
    env: Environment,
    config: HereNowConfig | None,
    gate: ApprovalGate | None = None,
) -> None:
    """Register ``herenow_publish`` — but only when the connector is enabled.

    A disabled or missing config registers nothing, so a run the user did not
    opt into has no here.now tool in the prompt and no way to publish.
    """
    if config is None or not config.enabled:
        return
    registry.register(
        "herenow_publish",
        PUBLISH_SCHEMA,
        make_publish_handler(env, config, gate),
    )


__all__ = [
    "DEFAULT_BASE_URL",
    "DEFAULT_CLIENT",
    "MAX_FILE_COUNT",
    "MAX_TOTAL_BYTES",
    "ApprovalGate",
    "HereNowConfig",
    "HereNowError",
    "PublishRequest",
    "make_publish_handler",
    "register_herenow_tools",
]
