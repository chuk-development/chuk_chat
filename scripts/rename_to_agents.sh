#!/usr/bin/env bash
# Rename the product from CoWork to Agents, in one deterministic pass.
#
# The specification is docs/NAMING.md. This script is the executable copy of
# that table, plus the two migrations the table asks for (the environment
# prefix and the state directory), plus one thing the table does not say:
# the list of spellings that must NOT move.
#
# What must not move, and why:
#
#   * Beads issue ids (``cowork-4z14``, ``cowork-sha``, ...). They are
#     identifiers, quoted in commit messages, code comments and the Dolt
#     history. Renaming them breaks every cross-reference and buys nothing.
#     ``.beads/`` is never opened at all.
#   * The English word "coworker". It is the product's own word for an agent
#     and appears in user-facing copy 600+ times.
#   * Wire constants, key-derivation labels, database identifiers, client
#     storage keys, the URL scheme and the application id. Each of those is a
#     value that already exists on a user's disk or on a paired device.
#     Changing one is a silent data migration, not a rename.
#
# So the rules below are an allowlist, not a sweep: a ``cowork`` spelling is
# renamed when a rule names it, and kept when no rule does. Anything kept is
# printed at the end, with the reason, so the list can be reviewed.
#
# Usage:
#   scripts/rename_to_agents.sh [--dry-run] [--force] [--repo DIR] [--quiet]
#
#   --dry-run   print every file and every path that would change, with
#               counts, and write nothing
#   --force     run even though the working tree is dirty
#   --repo DIR  operate on DIR instead of the repository this script is in
#   --quiet     totals and leftovers only, no per-file lines
#
# The script is idempotent: a second run reports zero changes. It never
# rewrites git history — the result is a normal working-tree change that the
# caller commits as one commit.

set -euo pipefail

DRY_RUN=0
FORCE=0
QUIET=0
REPO=""

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --repo) REPO="${2:?--repo needs a directory}"; shift 2 ;;
        --repo=*) REPO="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'rename_to_agents: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$REPO" ]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    REPO="$(cd -- "$script_dir/.." >/dev/null 2>&1 && pwd)"
fi

if [ ! -d "$REPO/.git" ]; then
    printf 'rename_to_agents: %s is not a git working tree\n' "$REPO" >&2
    exit 2
fi

REPO="$(cd -- "$REPO" >/dev/null 2>&1 && pwd)"

if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
        cat >&2 <<'DIRTY'
rename_to_agents: the working tree is dirty.

This pass touches most files in the repository, so it must start from a clean
tree or the result cannot be reviewed as one diff. Commit or stash first, or
pass --force if you know what the other changes are.
DIRTY
        exit 1
    fi
fi

command -v python3 >/dev/null 2>&1 || {
    printf 'rename_to_agents: python3 is required\n' >&2
    exit 2
}

python3 - "$REPO" "$DRY_RUN" "$QUIET" <<'PYCODE'
"""The rename itself. Ordered rules, one pass, allowlist semantics."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

REPO = sys.argv[1]
DRY_RUN = sys.argv[2] == "1"
QUIET = sys.argv[3] == "1"

KEEP = None  # a rule whose replacement is KEEP pins the match


# ---------------------------------------------------------------------------
# Rules
#
# (name, pattern, replacement, scope)
#
#   replacement is KEEP to pin the match, or a literal string.
#   scope selects the files a rule applies to:
#       "all"     every file
#       "pkg"     pyproject.toml and uv.lock only
#       "nonpkg"  every other file
#       "app"     paths under app/
#       "nonapp"  paths outside app/
#       "pubspec" app/pubspec.yaml only
#
# Order matters: the first rule that matches at a position wins, so the long
# and the pinned spellings come before the short and the generic ones.
# ---------------------------------------------------------------------------

RULES: list[tuple[str, str, str | None, str]] = [
    # -- 0. an explicit escape hatch ----------------------------------------
    # A line that ends in "# rename: keep" keeps every spelling on it. The
    # migration code below writes such lines, because the fallback it
    # implements has to name the pre-rename spelling to read it.
    ("line marked rename: keep",
     r"(?:CoWork|Cowork|COWORK|cowork)(?=[^\n]*# rename: keep)", KEEP, "all"),

    # -- 1. names that belong to something outside this repository ----------
    ("github repo slug", r"chukfinley/cowork", KEEP, "all"),
    ("local checkout path", r"git/cowork(?![A-Za-z0-9_-])", KEEP, "all"),

    # -- 2. the English word ------------------------------------------------
    # "coworker" is the product's word for an agent, not the product name.
    ("english word coworker", r"(?:CoWorker|Coworker|COWORKER|coworker)", KEEP, "all"),

    # -- 3. the application id ----------------------------------------------
    # dev.chuk.cowork is the Android applicationId, the Linux APPLICATION_ID
    # (so ~/.local/share/dev.chuk.cowork is the app's own data directory) and
    # the native-messaging host name the browser extension connects to.
    # Changing it ends update continuity and orphans the local data.
    ("application id", r"dev\.chuk\.cowork", KEEP, "all"),
    ("application id path", r"dev/chuk/cowork", KEEP, "all"),

    # -- 4. URL scheme and media type ---------------------------------------
    # cowork://blob/<id> and cowork://document/<id> are stored inside chat
    # rows, locally and in Supabase. The scheme is data, not branding.
    ("url scheme", r"cowork://", KEEP, "all"),
    # The same scheme, spelled as the bare value of the constant that builds
    # and parses it. Renaming it here and not in the stored URLs above would
    # make the parser reject every blob and document the app has on disk.
    ("url scheme", r"PairingUriScheme = 'cowork'", KEEP, "all"),
    ("media type", r"application/vnd\.cowork\.document\+json", KEEP, "all"),

    # -- 5. key derivation labels and wire topics ---------------------------
    # Both ends of the pairing handshake feed these strings into HKDF and into
    # the confirmation transcript. A one-sided change breaks pairing; a
    # two-sided change breaks every device already paired.
    ("hkdf label", r"chuk\.cowork\.(?:channel-key\.v1|frame)", KEEP, "all"),
    ("hkdf label", r"cowork/(?:pairing|reconnect|host)/[A-Za-z0-9._-]+", KEEP, "all"),
    ("relay topic", r"cowork/controller/[a-z]+/", KEEP, "all"),
    ("external client id", r"cowork/herenow-tool", KEEP, "all"),

    # -- 6. docker labels and the webview bridge ----------------------------
    # The lifecycle reaper finds and stops containers by these labels. Rename
    # them and every container started by an older build becomes unreapable.
    ("docker label", r"cowork\.(?:agent|image|managed|session|task|workspace)(?![A-Za-z0-9_])", KEEP, "all"),
    # The name of the JS object injected into the VNC page; Dart calls it by
    # string and the page defines it. Renaming needs both sides and a rebuilt
    # image, so it is a separate change.
    ("webview bridge", r"cowork\.(?:copySelection|pasteText|screenshot|reconnect|recenterPointer)", KEEP, "all"),

    # -- 7. database identifiers --------------------------------------------
    # Supabase tables, their policies and triggers, and the SQLite index and
    # tokenizer names. These live in a database that is already migrated;
    # renaming them here would only make the code miss the real tables.
    ("database identifier",
     r"cowork_(?:chats|secrets|skill_settings|device_tokens|run_notifications|push|fts_probe|dup_of_index|cjk_segment)(?![A-Za-z0-9_])",
     KEEP, "all"),

    # -- 8. client storage keys and wire message types ----------------------
    # SharedPreferences and secure-storage keys on the phone, and the frame
    # "type" values on the wire. Both are values a shipped build already
    # wrote or already sends.
    ("client storage key",
     r"cowork\.(?:auth_trace_v1|chat_model\.v1|cloud_outbox\.|last_agent_id|last_thread_key|last_user_id"
     r"|reactions\.v1|replay_cursor\.|replay_repeat_repair\.v1|replay_timestamp_cursor\.)",
     KEEP, "all"),
    ("client storage key",
     r"cowork_(?:agent_profiles_v1|agent_roster_v1|thread_read_marks_v1|media_index_v1|mcp_connectors"
     r"|device_id|device_seed|pairings|pairing|presence|relay|full_chat_debug"
     r"|mobile_messenger_typography|mobile_show_activity|mobile_show_thinking)(?![A-Za-z0-9_])(?!\.dart)",
     KEEP, "all"),
    ("wire message type",
     r"cowork_(?:answer_ready|pair_claim|pair_claimed|pair_error|pair_bound|pair_expired|error|truncated|memory)(?![A-Za-z0-9_])",
     KEEP, "all"),

    # -- 9. fixed test and environment values -------------------------------
    ("cross-language test vector", r"cowork00deadbeef", KEEP, "all"),
    ("android avd name", r"cowork_x64", KEEP, "all"),
    ("sandbox git identity", r"agent@cowork\.local", KEEP, "all"),

    # -- 10. the host device id, and the CLI command that shares its spelling
    # HOST_DEVICE_ID = "cowork-host" is stored as peerDeviceId in every paired
    # app and rides in the cw_device parameter of a pairing URI. The console
    # script is spelled the same way and is what install.sh, the service unit
    # and the docs call. Both stay; only the distribution name moves.
    ("thread name", r"cowork-host-party", "agents-host-party", "all"),
    ("console script name", r"cowork-host(?=\s*=\s*\")", KEEP, "pkg"),
    ("python distribution", r"cowork-host(?![A-Za-z0-9_-])", "chuk-agents-host", "pkg"),
    ("host device id / CLI command", r"cowork-host(?![A-Za-z0-9_-])", KEEP, "nonpkg"),

    # -- 11. the systemd unit -----------------------------------------------
    ("systemd unit", r"cowork-manager\.service", "agents-manager.service", "all"),
    ("systemd unit", r"status cowork-manager(?![A-Za-z0-9_.-])", "status agents-manager", "all"),

    # -- 12. operational names: images, containers, scripts, keys, log tags --
    # Everything here is a name this repository owns end to end: it is built,
    # started or printed by our own code, so renaming it is complete the
    # moment the text changes.
    ("image / in-image path", r"cowork-browser-bridge", "agents-browser-bridge", "all"),
    ("image / in-image path", r"cowork-browser-mcp", "agents-browser-mcp", "all"),
    ("image / in-image path", r"cowork-extension-mcp", "agents-extension-mcp", "all"),
    ("image / in-image path", r"cowork-entrypoint", "agents-entrypoint", "all"),
    ("image / in-image path", r"cowork-vnc-up", "agents-vnc-up", "all"),
    ("image / in-image path", r"cowork-vnc\.(pass|lock)", r"agents-vnc.\1", "all"),
    ("image tag", r"cowork-base", "agents-base", "all"),
    ("image tag", r"cowork-browser", "agents-browser", "all"),
    ("container name", r"cowork-agent-1-", "agents-agent-1-", "all"),
    ("container name", r"cowork-a1-old", "agents-a1-old", "all"),
    # The container-name literals the sandbox and manager tests assert on.
    # Named one by one, because "cowork-<two characters>" is also the shape of
    # a beads id and the catch-all below must keep protecting those.
    ("container name", r"cowork-a1(?![0-9A-Za-z-])", "agents-a1", "all"),
    ("container name", r"cowork-a2(?![0-9A-Za-z-])", "agents-a2", "all"),
    ("container name", r"cowork-old(?![0-9A-Za-z-])", "agents-old", "all"),
    ("container name", r"cowork-amber-", "agents-amber-", "all"),
    ("container label", r"cowork-session", "agents-session", "all"),
    ("extension dom id", r"cowork-agent-indicator", "agents-agent-indicator", "all"),
    ("thread name", r"cowork-desktop-notify", "agents-desktop-notify", "all"),
    ("thread name", r"cowork-memory-extract", "agents-memory-extract", "all"),
    ("thread name", r"cowork-ticker", "agents-ticker", "all"),
    ("thread name", r"cowork-notify", "agents-notify", "all"),
    ("thread name", r"cowork-unattended", "agents-unattended", "all"),
    ("model alias", r"cowork-memory-writer", "agents-memory-writer", "all"),
    ("model alias", r"cowork-backend", "agents-backend", "all"),
    ("mcp client name", r"cowork-doctor", "agents-doctor", "all"),
    ("temp path prefix", r"cowork-local-", "agents-local-", "all"),
    ("temp path prefix", r"cowork-migration-", "agents-migration-", "all"),
    ("temp path prefix", r"cowork-reasoning-probe-", "agents-reasoning-probe-", "all"),
    ("temp path", r"cowork-cancel-marker", "agents-cancel-marker", "all"),
    ("temp path", r"cowork-emulator", "agents-emulator", "all"),
    ("temp path", r"cowork-window", "agents-window", "all"),
    ("lock file", r"cowork-launcher", "agents-launcher", "all"),
    ("git internals", r"cowork-no-hooks", "agents-no-hooks", "all"),
    ("git internals", r"cowork-worktrees", "agents-worktrees", "all"),
    ("automation name", r"cowork-automations-", "agents-automations-", "all"),
    ("widget key", r"cowork-add-computer", "agents-add-computer", "all"),
    ("widget key", r"cowork-pairing-(code-field|connect|message|use-camera|use-code)", r"agents-pairing-\1", "all"),
    ("widget key", r"cowork-chat-busy", "agents-chat-busy", "all"),
    ("debug log tag", r"cowork-chat-(migration|storage|store)", r"agents-chat-\1", "all"),
    ("debug log tag", r"cowork-(adapter|cloud|export|ledger|link|outbox|relay|replay|restore|retry)(?![A-Za-z0-9_-])",
     r"agents-\1", "all"),

    # -- 13. python distributions -------------------------------------------
    ("python distribution", r"cowork-agent(?![A-Za-z0-9_-])", "chuk-agents-runtime", "all"),
    ("python distribution", r"cowork-executor(?![A-Za-z0-9_-])", "chuk-agents-executor", "all"),
    ("python distribution", r"cowork-manager(?![A-Za-z0-9_-])", "chuk-agents-manager", "all"),
    ("python distribution", r"cowork-sandbox(?![A-Za-z0-9_-])", "chuk-agents-sandbox", "all"),
    ("python distribution", r"cowork-crypto(?![A-Za-z0-9_-])", "chuk-agents-crypto", "all"),
    ("python distribution", r"cowork-config(?![A-Za-z0-9_-])", "chuk-agents-config", "all"),

    # -- 13b. a name that is finished by an interpolation -------------------
    # ``f"cowork-{agent_id}"`` and ``'cowork-chat-${threadKey}-...'`` are the
    # container prefix and a widget key. They have to move with the literals
    # the tests compare them against, and the beads catch-all below would
    # otherwise mistake the fixed part for an issue id.
    ("interpolated name prefix", r"cowork-(?=[0-9A-Za-z-]*[${%])", "agents-", "all"),

    # -- 14. everything else spelled cowork-<suffix> is a beads issue id ----
    # This is the catch-all that protects the tracker. It sits after every
    # rule that names a real thing, so only unclaimed spellings reach it.
    ("beads issue id", r"cowork-[0-9A-Za-z][0-9A-Za-z-]*(?:\.[0-9]+)?", KEEP, "all"),

    # -- 15. python import packages -----------------------------------------
    # Scoped away from app/, where cowork_agent means the Dart model file and
    # not the Python package, and away from any *.dart spelling.
    ("python package", r"cowork_agent(?![A-Za-z0-9_])(?!\.dart)", "chuk_agents_runtime", "nonapp"),
    ("python package", r"cowork_executor(?![A-Za-z0-9_])(?!\.dart)", "chuk_agents_executor", "nonapp"),
    ("python package", r"cowork_host(?![A-Za-z0-9_])(?!\.dart)", "chuk_agents_host", "nonapp"),
    ("python package", r"cowork_manager(?![A-Za-z0-9_])(?!\.dart)", "chuk_agents_manager", "nonapp"),
    ("python package", r"cowork_sandbox(?![A-Za-z0-9_])(?!\.dart)", "chuk_agents_sandbox", "nonapp"),
    ("python package", r"cowork_crypto(?![A-Za-z0-9_])(?!\.dart)", "chuk_agents_crypto", "nonapp"),
    ("python package", r"cowork_config(?![A-Za-z0-9_])(?!\.dart)", "chuk_agents_config", "nonapp"),

    # -- 16. the Dart package ------------------------------------------------
    ("dart package", r"package:cowork/", "package:chuk_chat/", "all"),
    ("dart package", r"^name: cowork$", "name: chuk_chat", "pubspec"),

    # -- 17. the generic case-mapped fallback -------------------------------
    ("feature flag", r"FEATURE_COWORK", "FEATURE_AGENTS", "all"),
    ("environment prefix", r"COWORK_", "AGENTS_", "all"),
    ("product name (upper)", r"COWORK", "AGENTS", "all"),
    ("product name (camel)", r"CoWork", "Agents", "all"),
    ("product name (title)", r"Cowork", "Agents", "all"),
    ("product name (lower)", r"cowork", "agents", "all"),
]


# ---------------------------------------------------------------------------
# Paths the pass never opens
# ---------------------------------------------------------------------------

#: The issue tracker. Its ids are the thing we are protecting; its database is
#: not text we may rewrite.
#: Applied Supabase migrations are immutable by definition — the tables they
#: create are renamed with a new migration, never by editing an old one.
EXCLUDED_PREFIXES = (
    ".beads/",
    "supabase/migrations/",
    # The tool, its test and its runbook all quote the old spellings on
    # purpose. Renaming them would rewrite the rule table into nonsense and
    # break the second run.
    "scripts/rename_to_agents.sh",
    "scripts/tests/",
    "docs/RENAME_RUNBOOK.md",
)

BINARY_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".pdf",
    ".woff", ".woff2", ".ttf", ".otf", ".zip", ".jar", ".so", ".dylib",
    ".dll", ".class", ".keystore", ".jks", ".mp4", ".webm", ".wasm",
}

PACKAGING_BASENAMES = {"pyproject.toml", "uv.lock"}


def file_scopes(path: str) -> set[str]:
    """The scope tags that select rules for one file."""
    tags = {"all"}
    base = os.path.basename(path)
    tags.add("pkg" if base in PACKAGING_BASENAMES else "nonpkg")
    tags.add("app" if path.startswith("app/") else "nonapp")
    if path == "app/pubspec.yaml":
        tags.add("pubspec")
    return tags


_COMPILED: dict[frozenset[str], tuple[re.Pattern[str], list[tuple]]] = {}


def compiled_for(tags: set[str]):
    """One combined regex per scope combination, built once.

    Every rule keeps a second, standalone copy of its own pattern. A rule
    whose replacement uses a backreference has to expand it against that copy:
    inside the combined regex the group numbers are global, so ``\\1`` would
    point at some earlier rule's group and silently expand to nothing.
    """
    key = frozenset(tags)
    found = _COMPILED.get(key)
    if found is not None:
        return found
    parts: list[str] = []
    meta: list[tuple] = []
    for name, pattern, replacement, scope in RULES:
        if scope not in tags:
            continue
        parts.append(f"(?P<r{len(meta)}>{pattern})")
        local = re.compile(pattern, re.MULTILINE) if (
            replacement is not None and "\\" in replacement
        ) else None
        meta.append((name, replacement, local))
    regex = re.compile("|".join(parts), re.MULTILINE)
    found = (regex, meta)
    _COMPILED[key] = found
    return found


def rewrite(text: str, tags: set[str], hits: Counter, kept: Counter):
    """Apply the rules once. Returns (new text, number of replacements)."""
    regex, meta = compiled_for(tags)
    changes = 0

    def swap(match: re.Match[str]) -> str:
        nonlocal changes
        index = int(match.lastgroup[1:])  # type: ignore[union-attr]
        name, replacement, local = meta[index]
        whole = match.group(0)
        if replacement is None:
            kept[name] += 1
            return whole
        if local is None:
            out = replacement
        else:
            inner = local.fullmatch(whole)
            if inner is None:  # pragma: no cover - the two patterns are one
                raise AssertionError(f"rule {name!r} cannot re-match {whole!r}")
            out = inner.expand(replacement)
        if out != whole:
            changes += 1
            hits[f"{whole} -> {out}"] += 1
        return out

    return regex.sub(swap, text), changes


def rewrite_path(path: str) -> str:
    """A path goes through the same rules as the text inside it.

    The whole path at once, not segment by segment: several rules span a
    separator (``dev/chuk/cowork`` is the application id, ``git/cowork`` is a
    checkout), and splitting first would hide them.
    """
    new, _ = rewrite(path, file_scopes(path), Counter(), Counter())
    return new


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", REPO, *args],
        check=True, capture_output=True, text=True,
    ).stdout


def tracked_files() -> list[str]:
    return [p for p in git("ls-files", "-z").split("\0") if p]


def is_binary(abspath: str) -> bool:
    if os.path.splitext(abspath)[1].lower() in BINARY_SUFFIXES:
        return True
    try:
        with open(abspath, "rb") as handle:
            return b"\0" in handle.read(8192)
    except OSError:
        return True


# ---------------------------------------------------------------------------
# The two migrations docs/NAMING.md asks for, written into the renamed code
# ---------------------------------------------------------------------------

STATE_HOME_MIGRATION = '''

# -- the state directory, moved once ----------------------------------------

#: The environment variable that moves the state directory.
HOME_ENV = "AGENTS_HOME"
#: Its pre-rename spelling, read after it for one release.
LEGACY_HOME_ENV = "COWORK_HOME"  # rename: keep

#: The pre-rename name of the state directory. It holds the device seed, the
#: account token and the secret vault, so it is moved, never re-created: a
#: host that loses it makes every paired device pair again.
LEGACY_HOME_NAME = ".cowork"  # rename: keep
#: The name it is moved to.
STATE_HOME_NAME = ".agents"

_MIGRATED: set[str] = set()


def migrate_state_home(target: Path) -> Path:
    """The pre-rename state directory becomes :data:`STATE_HOME_NAME`, once.

    Called with the path the renamed code wants. If that path already exists
    there is nothing to do. If it does not, and the same directory under
    :data:`LEGACY_HOME_NAME` does, the old one is moved to the new one and a
    symlink from the old name to the new one is left behind, so a shell alias,
    a systemd unit or a script that still uses the old name keeps working.

    Anything that goes wrong is reported and ignored: a failed migration must
    not stop the host from starting, and the caller still gets a usable path.

    Returns ``target``, so the call can wrap the expression that produced it.
    """
    if target.name != STATE_HOME_NAME:
        return target
    key = str(target)
    if key in _MIGRATED:
        return target
    _MIGRATED.add(key)
    legacy = target.with_name(LEGACY_HOME_NAME)
    try:
        if target.exists() or target.is_symlink():
            return target
        if not legacy.is_dir() or legacy.is_symlink():
            return target
        os.replace(legacy, target)
        try:
            legacy.symlink_to(target, target_is_directory=True)
        except OSError as error:  # pragma: no cover - platform dependent
            warnings.warn(
                f"moved {legacy} to {target} but could not leave a symlink"
                f" behind: {error}",
                RuntimeWarning,
                stacklevel=2,
            )
        else:
            warnings.warn(
                f"the state directory moved from {legacy} to {target};"
                f" {legacy} is now a symlink and will be removed in a later"
                " release",
                DeprecationWarning,
                stacklevel=2,
            )
    except OSError as error:  # pragma: no cover - filesystem dependent
        warnings.warn(
            f"could not move {legacy} to {target}: {error}",
            RuntimeWarning,
            stacklevel=2,
        )
    return target
'''

LEGACY_ENV_READER = '''

def _read_env(spec: FieldSpec, env: Mapping[str, str]) -> tuple[str | None, str]:
    """One setting's raw environment value, and the variable it came from.

    :attr:`FieldSpec.env` is read first. :attr:`FieldSpec.legacy_env`, the
    pre-rename spelling, is still read after it, with a deprecation warning,
    because the systemd unit, the compose files and any shell the user wrote
    still say the old name. One release.
    """
    raw = env.get(spec.env)
    if raw is not None and raw.strip():
        return raw, spec.env
    legacy = spec.legacy_env
    if legacy is not None:
        raw_legacy = env.get(legacy)
        if raw_legacy is not None and raw_legacy.strip():
            warn_legacy_env(spec.env, legacy)
            return raw_legacy, legacy
    return raw, spec.env


_WARNED_LEGACY: set[str] = set()


def warn_legacy_env(current: str, legacy: str) -> None:
    """Say once, per variable, that the old spelling was used."""
    if legacy in _WARNED_LEGACY:
        return
    _WARNED_LEGACY.add(legacy)
    warnings.warn(
        f"${legacy} is the pre-rename name of ${current} and will stop being"
        " read in a later release; export ${current} instead.".replace(
            "${current}", f"${current}"
        ),
        DeprecationWarning,
        stacklevel=3,
    )
'''

ENV_PREFIX_CONSTANTS = '''
#: The prefix every setting's environment variable carries.
ENV_PREFIX = "AGENTS_"
#: The prefix it carried before the product was renamed. Spelled once, here,
#: so the rename pass has exactly one line to leave alone.
LEGACY_ENV_PREFIX = "COWORK_"  # rename: keep
'''

LEGACY_ENV_PROPERTY = '''
    @property
    def legacy_env(self) -> str | None:
        """The pre-rename spelling of :attr:`env`, or ``None``.

        Every variable carried the old product prefix. The loader reads this
        name after :attr:`env` and warns when it hits, so an install whose
        systemd unit or shell still exports the old name keeps working for
        one release.
        """
        if self.env.startswith(ENV_PREFIX):
            return LEGACY_ENV_PREFIX + self.env[len(ENV_PREFIX) :]
        return None
'''


def patch_file(relpath_candidates, edits, report):
    """Apply anchored edits to whichever candidate path exists.

    Every edit is (anchor, replacement, marker). The edit is skipped when its
    marker is already in the file, which is what makes a second run a no-op.
    Returns the number of edits applied.
    """
    for relpath in relpath_candidates:
        abspath = os.path.join(REPO, relpath)
        if os.path.exists(abspath):
            break
    else:
        report.append(("missing", relpath_candidates[0], 0))
        return 0

    with open(abspath, encoding="utf-8") as handle:
        text = handle.read()
    if DRY_RUN:
        # Nothing was written, so the file still carries the old spellings.
        # Rename it in memory first, or every anchor below would miss and the
        # dry run would under-report.
        text, _ = rewrite(text, file_scopes(relpath), Counter(), Counter())
    original = text
    applied = 0
    for anchor, replacement, marker in edits:
        if marker in text:
            continue
        if anchor not in text:
            report.append(("anchor not found", f"{relpath}: {anchor.strip()[:60]}", 0))
            continue
        text = text.replace(anchor, replacement, 1)
        applied += 1
    if text != original and not DRY_RUN:
        with open(abspath, "w", encoding="utf-8") as handle:
            handle.write(text)
    report.append(("patched", relpath, applied))
    return applied


def apply_migrations(report):
    """Write the environment fallback and the state-directory migration.

    Both are asked for by docs/NAMING.md and neither can be expressed as a
    string substitution, so they are anchored edits against the already
    renamed files.
    """
    total = 0

    # -- the FieldSpec learns its own pre-rename variable name --------------
    total += patch_file(
        ["common/chuk_agents_config/src/chuk_agents_config/fields.py",
         "common/cowork_config/src/cowork_config/fields.py"],
        [(
            "_ALLOWED_TYPES: tuple[type, ...] = (str, int, float, bool)\n",
            "_ALLOWED_TYPES: tuple[type, ...] = (str, int, float, bool)\n"
            + ENV_PREFIX_CONSTANTS,
            "LEGACY_ENV_PREFIX =",
        ), (
            '    @property\n'
            '    def path(self) -> str:\n',
            LEGACY_ENV_PROPERTY.lstrip("\n") + '\n'
            '    @property\n'
            '    def path(self) -> str:\n',
            "def legacy_env(self)",
        )],
        report,
    )

    # -- the loader reads it, and migrates the state directory --------------
    loader = [
        "common/chuk_agents_config/src/chuk_agents_config/loader.py",
        "common/cowork_config/src/cowork_config/loader.py",
    ]
    total += patch_file(
        loader,
        [
            (
                "import tomllib\n",
                "import tomllib\nimport warnings\n",
                "\nimport warnings\n",
            ),
            (
                '    "config_home",\n    "default_config_path",\n',
                '    "config_home",\n    "default_config_path",\n'
                '    "migrate_state_home",\n',
                '"migrate_state_home",',
            ),
            (
                '    raw = (env.get("AGENTS_HOME") or "").strip() or DEFAULT_HOME\n'
                '    return Path(raw).expanduser()\n',
                '    raw = (env.get(HOME_ENV) or "").strip()\n'
                '    if not raw:\n'
                '        legacy = (env.get(LEGACY_HOME_ENV) or "").strip()\n'
                '        if legacy:\n'
                '            warn_legacy_env(HOME_ENV, LEGACY_HOME_ENV)\n'
                '            raw = legacy\n'
                '    return migrate_state_home(Path(raw or DEFAULT_HOME).expanduser())\n',
                'warn_legacy_env(HOME_ENV, LEGACY_HOME_ENV)',
            ),
            (
                "    raw_env = env.get(spec.env)\n"
                "    if raw_env is not None and raw_env.strip():\n",
                "    raw_env, env_name = _read_env(spec, env)\n"
                "    if raw_env is not None and raw_env.strip():\n",
                "raw_env, env_name = _read_env(spec, env)",
            ),
            (
                'message=f"{error} (from ${spec.env})",',
                'message=f"{error} (from ${env_name})",',
                "(from ${env_name})",
            ),
            (
                "# -- where the file is ---",
                LEGACY_ENV_READER.strip("\n") + "\n\n\n"
                + STATE_HOME_MIGRATION.strip("\n") + "\n\n\n"
                + "# -- where the file is ---",
                "def migrate_state_home(",
            ),
        ],
        report,
    )

    # -- the package exports it ---------------------------------------------
    total += patch_file(
        ["common/chuk_agents_config/src/chuk_agents_config/__init__.py",
         "common/cowork_config/src/cowork_config/__init__.py"],
        [
            (
                "    config_home,\n",
                "    config_home,\n    migrate_state_home,\n",
                "    migrate_state_home,\n",
            ),
            (
                '    "config_home",\n',
                '    "config_home",\n    "migrate_state_home",\n',
                '    "migrate_state_home",\n',
            ),
        ],
        report,
    )

    # -- the host runs the migration when it opens its workspace ------------
    total += patch_file(
        ["host/src/chuk_agents_host/host.py", "host/src/cowork_host/host.py"],
        [
            (
                "from .room_service import RoomService, dispatch_room_frame\n",
                "from chuk_agents_config import migrate_state_home\n\n"
                "from .room_service import RoomService, dispatch_room_frame\n",
                "from chuk_agents_config import migrate_state_home",
            ),
            (
                "        self._workspace = Path(workspace_dir).expanduser()\n",
                "        # The pre-rename state directory is moved here, once, before\n"
                "        # anything reads the device seed, the account token or the\n"
                "        # secret vault.\n"
                "        self._workspace = migrate_state_home(\n"
                "            Path(workspace_dir).expanduser()\n"
                "        )\n",
                "migrate_state_home(",
            ),
        ],
        report,
    )

    # -- the host declares the dependency that import needs -----------------
    total += patch_file(
        ["host/pyproject.toml"],
        [
            (
                '    "chuk-agents-crypto",\n',
                '    "chuk-agents-crypto",\n    "chuk-agents-config",\n',
                '    "chuk-agents-config",\n',
            ),
            (
                'chuk-agents-crypto = { path = "../common/chuk_agents_crypto", editable = true }\n',
                'chuk-agents-crypto = { path = "../common/chuk_agents_crypto", editable = true }\n'
                'chuk-agents-config = { path = "../common/chuk_agents_config", editable = true }\n',
                "chuk-agents-config = { path =",
            ),
        ],
        report,
    )

    # -- the host device id keeps its spelling, and says why ----------------
    total += patch_file(
        ["host/src/chuk_agents_host/identity.py", "host/src/cowork_host/identity.py"],
        [(
            'HOST_DEVICE_ID = "cowork-host"\n',
            '# Wire state, not a name: this id is stored as ``peerDeviceId`` in every\n'
            '# paired app and rides in the ``cw_device`` parameter of a pairing URI.\n'
            '# The product rename deliberately leaves it alone — changing it would\n'
            '# make every paired device pair again.\n'
            'HOST_DEVICE_ID = "cowork-host"\n',
            "Wire state, not a name",
        )],
        report,
    )

    return total


# ---------------------------------------------------------------------------
# The pass
# ---------------------------------------------------------------------------

def main() -> int:
    files = tracked_files()
    content_changes: list[tuple[str, int]] = []
    path_changes: list[tuple[str, str]] = []
    token_hits: Counter = Counter()
    kept_hits: Counter = Counter()
    kept_examples: dict[str, set[str]] = defaultdict(set)
    skipped_binary = 0
    excluded = 0

    for relpath in files:
        if relpath.startswith(EXCLUDED_PREFIXES):
            excluded += 1
            continue
        abspath = os.path.join(REPO, relpath)
        if not os.path.isfile(abspath) or os.path.islink(abspath):
            continue

        if is_binary(abspath):
            skipped_binary += 1
        else:
            with open(abspath, encoding="utf-8", errors="strict") as handle:
                text = handle.read()
            if "cowork" in text.lower():
                per_file_kept: Counter = Counter()
                new_text, count = rewrite(
                    text, file_scopes(relpath), token_hits, per_file_kept
                )
                for name, number in per_file_kept.items():
                    kept_hits[name] += number
                    if len(kept_examples[name]) < 4:
                        kept_examples[name].add(relpath)
                if count:
                    content_changes.append((relpath, count))
                    if not DRY_RUN:
                        with open(abspath, "w", encoding="utf-8") as handle:
                            handle.write(new_text)

        new_path = rewrite_path(relpath)
        if new_path != relpath:
            path_changes.append((relpath, new_path))

    # -- the moves ----------------------------------------------------------
    for old, new in path_changes:
        if DRY_RUN:
            continue
        target = os.path.join(REPO, new)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        git("mv", "--", old, new)

    if not DRY_RUN:
        # git mv leaves the emptied directories behind in the working tree.
        for old, _ in sorted(path_changes, key=lambda pair: -pair[0].count("/")):
            directory = os.path.join(REPO, os.path.dirname(old))
            while directory.startswith(REPO + os.sep):
                try:
                    os.rmdir(directory)
                except OSError:
                    break
                directory = os.path.dirname(directory)

    migration_report: list[tuple[str, str, int]] = []
    migration_edits = apply_migrations(migration_report)

    # -- the report ---------------------------------------------------------
    head = "would change" if DRY_RUN else "changed"
    if not QUIET and content_changes:
        print(f"# files {head} ({len(content_changes)})")
        for relpath, count in sorted(content_changes):
            print(f"  {count:5d}  {relpath}")
        print()
    if not QUIET and path_changes:
        print(f"# paths {head} ({len(path_changes)}), each with git mv")
        for old, new in sorted(path_changes):
            print(f"         {old}\n      -> {new}")
        print()
    if not QUIET and token_hits:
        print(f"# spellings {head} (top 40 of {len(token_hits)})")
        for token, count in token_hits.most_common(40):
            print(f"  {count:5d}  {token}")
        print()

    print("# migrations written into the renamed code")
    for kind, where, count in migration_report:
        print(f"  {kind:16s} {where}" + (f"  ({count} edit(s))" if count else ""))
    print()

    print("# kept on purpose — every match below was left exactly as it is")
    for name, count in sorted(kept_hits.items(), key=lambda pair: -pair[1]):
        sample = ", ".join(sorted(kept_examples[name])[:3])
        print(f"  {count:5d}  {name}")
        print(f"         e.g. {sample}")
    print()

    lines_changed = sum(count for _, count in content_changes)
    print("# totals")
    print(f"  files scanned            {len(files) - excluded}")
    print(f"  files in excluded paths  {excluded}  (.beads/, supabase/migrations/)")
    print(f"  binary files skipped     {skipped_binary}")
    print(f"  files {head:<19s}{len(content_changes)}")
    print(f"  spellings {head:<15s}{lines_changed}")
    print(f"  paths {head:<19s}{len(path_changes)}")
    print(f"  migration edits applied  {migration_edits}")
    if DRY_RUN:
        print("\n(dry run: nothing was written)")
    return 0


sys.exit(main())
PYCODE
