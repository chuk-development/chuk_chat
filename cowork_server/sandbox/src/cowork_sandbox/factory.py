"""Factory keyed off a ``kind`` string (mirrors Hermes's env-var selection)."""

from __future__ import annotations

import os

from .base import BaseEnvironment
from .docker import DockerEnvironment
from .local import LocalEnvironment

_KINDS = {"local", "docker"}

#: Env var a host can set to pick the backend without touching call sites.
KIND_ENV_VAR = "COWORK_SANDBOX_KIND"
DEFAULT_KIND = "local"


def resolve_kind(kind: str | None = None) -> str:
    """Explicit kind > ``COWORK_SANDBOX_KIND`` > ``local``."""
    return kind or os.environ.get(KIND_ENV_VAR) or DEFAULT_KIND


def make_environment(kind: str | None = None, **opts: object) -> BaseEnvironment:
    """Build an environment for ``kind`` in ``{'local', 'docker'}``.

    Extra keyword options pass straight to the backend constructor. ``workdir``
    means the same thing for both backends — the host directory the agent works
    in — which is why a caller can switch backends without rewriting the call:
    ``local`` uses it directly, ``docker`` bind-mounts it into the container.
    """
    resolved = resolve_kind(kind)
    if resolved == "local":
        return LocalEnvironment(**opts)  # type: ignore[arg-type]
    if resolved == "docker":
        return DockerEnvironment(**opts)  # type: ignore[arg-type]
    raise ValueError(
        f"unknown environment kind {resolved!r}; expected one of {sorted(_KINDS)}"
    )
