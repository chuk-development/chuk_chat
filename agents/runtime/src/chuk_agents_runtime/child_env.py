"""The environment of a command the agent runs on the host (bead B9).

The local backend used to hand every ``run_command`` / ``python`` / terminal /
job the full environment of the host process: the account token, every API key
the user exported, the host's own ``AGENTS_*`` settings. A model that ran
``env`` saw all of it.

:func:`child_env` builds the child's environment from an allowlist instead:

1. Only harmless names pass (:data:`ALLOWED_NAMES`, ``LC_*``, ``XDG_*``).
2. A name that looks like a credential (:data:`_DENY_RE`) is dropped even when
   it is on the allowlist, and so is every internal ``AGENTS_*`` / ``CHUK_*`` /
   ``COWORK_*`` name.
3. The secrets the user granted (``secrets_env``, docs/WIRE_CONTRACT.md
   "Secrets") are added on top: they are the one way a credential reaches a
   command, and they pass by explicit grant, not by inheritance.
4. :data:`FIXED` makes tool output plain text (no colour, no pager).

This is a copy of ``chuk_agents_sandbox.child_env`` for the runtime's own
stand-in environment (the runtime does not depend on the sandbox). Keep the
two in step.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping

#: Names a command may inherit from the host. Nothing here carries a secret.
ALLOWED_NAMES = frozenset(
    {
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LANGUAGE",
        "TZ",
        "TMPDIR",
        "PWD",
        "HOSTNAME",
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "COLUMNS",
        "LINES",
        "EDITOR",
        "VISUAL",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "REQUESTS_CA_BUNDLE",
        "NODE_EXTRA_CA_CERTS",
        "JAVA_HOME",
        "GOPATH",
        "GOROOT",
        "CARGO_HOME",
        "RUSTUP_HOME",
        "PYENV_ROOT",
        "NVM_DIR",
        "VIRTUAL_ENV",
        "CONDA_PREFIX",
        "PKG_CONFIG_PATH",
        "LD_LIBRARY_PATH",
        "MANPATH",
        "http_proxy",
        "https_proxy",
        "no_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
    }
)

#: Prefixes that pass as a group (locale, XDG base directories).
ALLOWED_PREFIXES = ("LC_", "XDG_")

#: A name that looks like a credential. Checked case-insensitively, after the
#: allowlist, so an allowed prefix (``XDG_*``) can never smuggle one through.
_DENY_RE = re.compile(r"KEY|TOKEN|SECRET|PASSW|CREDENTIAL|AUTH|COOKIE|SESSION", re.IGNORECASE)

#: The host's own settings and state, never the agent's business.
INTERNAL_PREFIXES = ("AGENTS_", "CHUK_", "COWORK_", "CLAUDE")

#: Set on every child: tool output is read by a model, not a terminal.
FIXED: Mapping[str, str] = {
    "NO_COLOR": "1",
    "TERM": "dumb",
    "PAGER": "cat",
    "GIT_PAGER": "cat",
}


def is_denied(name: str) -> bool:
    """True for a name a command must never inherit from the host."""
    return bool(_DENY_RE.search(name)) or name.upper().startswith(INTERNAL_PREFIXES)


def is_allowed(name: str) -> bool:
    """True for a host name a command may inherit."""
    if is_denied(name):
        return False
    return name in ALLOWED_NAMES or name.startswith(ALLOWED_PREFIXES)


def child_env(
    granted: Mapping[str, str] | None = None,
    *,
    base: Mapping[str, str] | None = None,
    extra: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """The environment of one child process.

    ``base`` is the host environment (default ``os.environ``); only allowed
    names pass. ``extra`` is set by the backend itself (``TMUX_TMPDIR``, ...).
    ``granted`` is the user's secrets for this command; they win over
    everything, because the user asked for exactly these values."""
    source = os.environ if base is None else base
    env = {k: v for k, v in source.items() if is_allowed(k)}
    env.setdefault("PATH", os.defpath)
    env.update(FIXED)
    if extra:
        env.update(extra)
    if granted:
        env.update(granted)
    return env


#: Bash that unsets every exported credential-looking or internal name. Runs
#: inside the login shell that seeds the session snapshot (``init_session``),
#: so a profile that exports an API key does not put it into every command.
#:
#: Bash 3.2 compatible (the macOS ``/bin/bash``): no ``${var^^}``, which is
#: bash 4 and fails there with "bad substitution". ``nocasematch`` (bash 3.1)
#: makes the ``case`` match without case, with no fork per name; the shell's
#: own setting is put back afterwards.
SCRUB_SNIPPET = (
    "__cw_nc=0; shopt -q nocasematch && __cw_nc=1; shopt -s nocasematch; "
    "for __cw_n in $(compgen -e); do "
    "case \"$__cw_n\" in "
    "*KEY*|*TOKEN*|*SECRET*|*PASSW*|*CREDENTIAL*|*AUTH*|*COOKIE*|*SESSION*|"
    "AGENTS_*|CHUK_*|COWORK_*|CLAUDE*) unset -v \"$__cw_n\" 2>/dev/null;; "
    "esac; done; "
    "[ \"$__cw_nc\" = 1 ] || shopt -u nocasematch; unset -v __cw_n __cw_nc"
)
