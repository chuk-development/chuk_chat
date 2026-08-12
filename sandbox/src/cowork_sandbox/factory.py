"""Factory keyed off a ``kind`` string (mirrors Hermes's env-var selection)."""

from __future__ import annotations

from .base import BaseEnvironment
from .docker import DockerEnvironment
from .local import LocalEnvironment

_KINDS = {"local", "docker"}


def make_environment(kind: str, **opts: object) -> BaseEnvironment:
    """Build an environment for ``kind`` in ``{'local', 'docker'}``.

    Extra keyword options pass straight to the backend constructor
    (e.g. ``image=...`` / ``session_id=...`` for docker, ``workdir=...`` for
    local).
    """
    if kind == "local":
        return LocalEnvironment(**opts)  # type: ignore[arg-type]
    if kind == "docker":
        return DockerEnvironment(**opts)  # type: ignore[arg-type]
    raise ValueError(f"unknown environment kind {kind!r}; expected one of {sorted(_KINDS)}")
