"""Sanity check for a stdio MCP server that a package runner fetches.

A ``mcp.json`` entry like ``{"command": "npx", "args": ["-y", "some-mcp"]}``
downloads a package from a public registry and runs it with the user's
rights, on the user's real PC. One typo in a package name, or one planted
``mcp.json`` in a cloned repository, is enough to run a stranger's code.
goose checks OSV for ``MAL-*`` advisories before such a launch
(``crates/goose/src/agents/extension_malware_check.rs``). This module is the
offline part of that idea. It makes no network call:

- **Deny list.** A package name on :data:`DENIED_PACKAGES` (known malicious
  MCP packages), or on the caller's own deny list, is refused.
- **Typosquats.** A name that is close to a popular MCP server
  (:data:`POPULAR_PACKAGES`) but not equal to it is refused: an edit distance
  of 1-2, the same name under a look-alike scope
  (``@modelcontextprotocoI/server-filesystem``), or a name with non-ASCII
  characters (homoglyphs).
- **Pinning.** A package without an exact version (``pkg``, ``pkg@latest``,
  ``pkg@^1``) gets a warning: the next start can run different code.
  A source that is not the registry (``github:``, ``git+``, a URL) gets a
  warning too.

The caller's allow list wins over the typosquat rule, never over the built-in
deny list. A command that is not a package runner (a local binary, ``node
server.js``, ``python -m x``) is not checked: there is no package name to check.

The result goes into the connection's error (refused) or warnings (allowed),
and from there into the ``mcp_tools`` frame (docs/WIRE_CONTRACT.md).
"""

from __future__ import annotations

import re
import shlex
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field

NPM = "npm"
PYPI = "pypi"

#: Package runners, by the executable's base name, and their ecosystem.
_RUNNERS = {
    "npx": NPM,
    "npx.cmd": NPM,
    "bunx": NPM,
    "pnpx": NPM,
    "uvx": PYPI,
    "uvx.exe": PYPI,
}

#: Runners whose first argument is a subcommand: ``(executable, subcommand)``.
_SUBCOMMAND_RUNNERS = {
    ("pnpm", "dlx"): NPM,
    ("yarn", "dlx"): NPM,
    ("npm", "exec"): NPM,
    ("bun", "x"): NPM,
    ("pipx", "run"): PYPI,
}

#: Options of the runners that take a value. The value is never the package,
#: except for the ``--package`` / ``--from`` options, read separately.
_VALUE_OPTIONS = frozenset(
    {
        "--python", "-p", "--with", "-w", "--index", "--index-url",
        "--extra-index-url", "--default-index", "--cache-dir", "--registry",
        "--userconfig", "--call", "-c", "--spec", "--pip-args", "--node-options",
        "--prefix", "--directory", "--env-file", "--with-requirements",
        "--constraint", "--overrides",
    }
)
_PACKAGE_OPTIONS = {NPM: ("--package", "-p"), PYPI: ("--from", "--spec")}

#: Popular MCP servers, as published. A name that is close to one of these but
#: not equal is a typosquat. Keep the list to real, widely used packages.
POPULAR_PACKAGES: dict[str, frozenset[str]] = {
    NPM: frozenset(
        {
            "@modelcontextprotocol/server-filesystem",
            "@modelcontextprotocol/server-memory",
            "@modelcontextprotocol/server-everything",
            "@modelcontextprotocol/server-sequential-thinking",
            "@modelcontextprotocol/server-github",
            "@modelcontextprotocol/server-gitlab",
            "@modelcontextprotocol/server-puppeteer",
            "@modelcontextprotocol/server-brave-search",
            "@modelcontextprotocol/server-slack",
            "@modelcontextprotocol/server-postgres",
            "@modelcontextprotocol/server-gdrive",
            "@modelcontextprotocol/server-google-maps",
            "@modelcontextprotocol/server-redis",
            "@modelcontextprotocol/inspector",
            "@playwright/mcp",
            "@upstash/context7-mcp",
            "@notionhq/notion-mcp-server",
            "@sentry/mcp-server",
            "@supabase/mcp-server-supabase",
            "@stripe/mcp",
            "@cloudflare/mcp-server-cloudflare",
            "@browsermcp/mcp",
            "@executeautomation/playwright-mcp-server",
            "@heroku/mcp-server",
            "@azure/mcp",
            "chrome-devtools-mcp",
            "firecrawl-mcp",
            "mcp-remote",
            "exa-mcp-server",
            "tavily-mcp",
            "figma-developer-mcp",
        }
    ),
    PYPI: frozenset(
        {
            "mcp-server-fetch",
            "mcp-server-git",
            "mcp-server-time",
            "mcp-server-sqlite",
            "mcp-server-qdrant",
            "awslabs.aws-documentation-mcp-server",
            "awslabs.core-mcp-server",
            "mcp-proxy",
            "markitdown-mcp",
            "serena-agent",
            "blender-mcp",
            "mcp",
        }
    ),
}

#: Known malicious packages (name only, every version). ``postmark-mcp`` is
#: the npm package that impersonated Postmark and, from 1.0.16 (2025-09),
#: copied every sent mail to its author.
DENIED_PACKAGES: dict[str, frozenset[str]] = {
    NPM: frozenset({"postmark-mcp"}),
    PYPI: frozenset(),
}

#: Scopes worth protecting from a look-alike scope.
_POPULAR_SCOPES = frozenset(
    name.split("/", 1)[0] for name in POPULAR_PACKAGES[NPM] if name.startswith("@")
)

_EXACT_NPM_VERSION = re.compile(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?$")
_PYPI_SPEC = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._\-]*)(\[[^\]]*\])?\s*(.*)$")
_EXACT_PYPI_VERSION = re.compile(r"^===?\s*[0-9][0-9A-Za-z.+!\-]*$")
_REMOTE_PREFIXES = ("github:", "gitlab:", "bitbucket:", "git+", "git:", "http://", "https://", "file:")


@dataclass(frozen=True)
class PackageCheck:
    """What the check found for one stdio launch."""

    #: ``False`` means: do not start the server; :attr:`reason` says why.
    ok: bool = True
    ecosystem: str | None = None
    package: str | None = None
    version: str | None = None
    reason: str | None = None
    warnings: tuple[str, ...] = field(default_factory=tuple)

    @property
    def checked(self) -> bool:
        """A package runner was found and a package name was read."""
        return self.package is not None


def check_stdio_launch(
    command: str | None,
    args: Sequence[str] | None = None,
    *,
    allow: Iterable[str] = (),
    deny: Iterable[str] = (),
) -> PackageCheck:
    """Check one ``command`` + ``args`` launch. Never raises."""
    try:
        return _check(command, list(args or []), allow, deny)
    except Exception as exc:  # noqa: BLE001 — a checker bug must not crash the start
        return PackageCheck(warnings=(f"package check failed: {type(exc).__name__}",))


def _check(command, args, allow, deny) -> PackageCheck:
    argv = _argv(command, args)
    if not argv:
        return PackageCheck()
    found = _find_package(argv)
    if found is None:
        return PackageCheck()
    ecosystem, spec = found
    if spec.startswith(_REMOTE_PREFIXES) or "://" in spec:
        return PackageCheck(
            ecosystem=ecosystem,
            package=spec,
            warnings=(
                f"{spec} is not from the package registry; its code is not "
                "checked and can change at any time",
            ),
        )
    name, version, pinned = (
        _split_npm(spec) if ecosystem == NPM else _split_pypi(spec)
    )
    key = _norm(name, ecosystem)
    allowed = {_norm(n, ecosystem) for n in allow if isinstance(n, str) and n.strip()}
    denied = {_norm(n, ecosystem) for n in deny if isinstance(n, str) and n.strip()}
    base = dict(ecosystem=ecosystem, package=name, version=version)

    if key in {_norm(n, ecosystem) for n in DENIED_PACKAGES[ecosystem]}:
        return PackageCheck(ok=False, reason=f"{name} is a known malicious package", **base)
    if key in denied:
        return PackageCheck(ok=False, reason=f"{name} is on your deny list", **base)

    warnings: list[str] = []
    if not pinned:
        warnings.append(
            f"{name} has no exact version; pin it (for example "
            + (f"{name}@1.2.3" if ecosystem == NPM else f"{name}==1.2.3")
            + ") so a new release cannot change the code that runs"
        )
    popular = {_norm(n, ecosystem): n for n in POPULAR_PACKAGES[ecosystem]}
    if key in allowed or key in popular:
        return PackageCheck(warnings=tuple(warnings), **base)

    squat = _typosquat_of(name, ecosystem, popular)
    if squat is not None:
        return PackageCheck(
            ok=False,
            reason=(
                f"{name} looks like a copy of the popular package {squat}; "
                "check the name, or add it to the allow list"
            ),
            warnings=tuple(warnings),
            **base,
        )
    return PackageCheck(warnings=tuple(warnings), **base)


def _argv(command: str | None, args: list[str]) -> list[str]:
    text = (command or "").strip()
    if not text:
        return []
    head = shlex.split(text) if any(c.isspace() for c in text) else [text]
    return head + [str(a) for a in args]


def _base(executable: str) -> str:
    return executable.replace("\\", "/").rsplit("/", 1)[-1].lower()


def _find_package(argv: list[str]) -> tuple[str, str] | None:
    exe = _base(argv[0])
    rest = argv[1:]
    ecosystem = _RUNNERS.get(exe)
    if ecosystem is None and rest:
        ecosystem = _SUBCOMMAND_RUNNERS.get((exe, rest[0].lower()))
        if ecosystem is not None:
            rest = rest[1:]
    if ecosystem is None and exe == "uv" and rest[:2] == ["tool", "run"]:
        ecosystem, rest = PYPI, rest[2:]
    if ecosystem is None:
        return None
    package_options = _PACKAGE_OPTIONS[ecosystem]
    i = 0
    while i < len(rest):
        token = rest[i]
        if token == "--":
            return (ecosystem, rest[i + 1]) if i + 1 < len(rest) else None
        if token.startswith("-"):
            option, eq, value = token.partition("=")
            if option in package_options:
                if eq:
                    return ecosystem, value
                if i + 1 < len(rest):
                    return ecosystem, rest[i + 1]
                return None
            if option in _VALUE_OPTIONS and not eq:
                i += 2
                continue
            i += 1
            continue
        return ecosystem, token
    return None


def _split_npm(spec: str) -> tuple[str, str | None, bool]:
    if spec.startswith("@"):
        scope_end = spec.find("/")
        at = spec.find("@", scope_end + 1 if scope_end > 0 else 1)
    else:
        at = spec.find("@")
    if at <= 0:
        return spec, None, False
    name, version = spec[:at], spec[at + 1 :]
    return name, version or None, bool(_EXACT_NPM_VERSION.match(version))


def _split_pypi(spec: str) -> tuple[str, str | None, bool]:
    if "@" in spec and "==" not in spec:
        # uvx accepts ``pkg@1.2.3``.
        name, _, version = spec.partition("@")
        version = version.strip()
        return name.strip(), version or None, bool(re.match(r"^[0-9][0-9A-Za-z.+!\-]*$", version))
    match = _PYPI_SPEC.match(spec.strip())
    if not match:
        return spec, None, False
    name, _extras, constraint = match.groups()
    constraint = (constraint or "").strip()
    if not constraint:
        return name, None, False
    return name, constraint, bool(_EXACT_PYPI_VERSION.match(constraint))


def _norm(name: str, ecosystem: str) -> str:
    text = name.strip().lower()
    if ecosystem == PYPI:
        # PEP 503: runs of -, _ and . are the same.
        text = re.sub(r"[-_.]+", "-", text)
    return text


def _typosquat_of(name: str, ecosystem: str, popular: dict[str, str]) -> str | None:
    if not name.isascii():
        # A homoglyph (Cyrillic "о" for "o") reads like the real name.
        target = _closest(_ascii_fold(name).lower(), popular, ecosystem)
        return target or "a popular package (non-ASCII characters in the name)"
    key = _norm(name, ecosystem)
    if ecosystem == NPM and key.startswith("@") and "/" in key:
        # Same package name under a look-alike scope.
        scope, tail = key.split("/", 1)
        for real in popular.values():
            if not real.startswith("@"):
                continue
            real_scope, real_tail = real.split("/", 1)
            if real_scope != scope and real_tail == tail and _distance(scope, real_scope) <= 2:
                return real
    return _closest(key, popular, ecosystem)


def _closest(key: str, popular: dict[str, str], ecosystem: str) -> str | None:
    """The popular name within a small edit distance of ``key``.

    Short names get no slack at all (``mcp`` vs ``mcpx`` are different
    things), mid-length names one edit, long names two.
    """
    squashed = _squash(key)
    for norm, real in popular.items():
        if norm == key:
            continue
        limit = 0 if len(norm) < 6 else 1 if len(norm) < 20 else 2
        if _distance(key, norm) <= limit:
            return real
        # "server_filesystem" vs "server-filesystem": separators do not count.
        if squashed == _squash(norm):
            return real
    return None


def _squash(text: str) -> str:
    return re.sub(r"[-_.]+", "", text)


def _ascii_fold(text: str) -> str:
    table = {
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y",
        "і": "i", "ӏ": "l", "ԁ": "d", "ѕ": "s", "һ": "h", "ј": "j", "ɡ": "g",
        "Ⅰ": "l", "ı": "i",
    }
    return "".join(table.get(ch, ch) for ch in text)


def _distance(a: str, b: str) -> int:
    """Optimal string alignment distance (Levenshtein plus adjacent swaps)."""
    if a == b:
        return 0
    if abs(len(a) - len(b)) > 2:
        return 3
    prev2: list[int] | None = None
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if (
                prev2 is not None
                and i > 1
                and j > 1
                and ca == b[j - 2]
                and a[i - 2] == cb
            ):
                cur[j] = min(cur[j], prev2[j - 2] + 1)
        prev2, prev = prev, cur
    return prev[-1]


__all__ = [
    "DENIED_PACKAGES",
    "NPM",
    "POPULAR_PACKAGES",
    "PYPI",
    "PackageCheck",
    "check_stdio_launch",
]
