"""CoWork execution sandbox.

A ``BaseEnvironment`` ABC with snapshot-file session persistence (borrowed from
Hermes Agent, MIT, and reimplemented), plus local and docker backends and a
factory. See ``docs/COWORK_AGENT_PLATFORM_PLAN.md`` section 6.
"""

from __future__ import annotations

from .base import DEFAULT_MAX_OUTPUT_CHARS, BaseEnvironment
from .docker import (
    DEFAULT_IMAGE,
    DockerEnvironment,
    DockerUnavailableError,
    docker_available,
)
from .factory import make_environment
from .local import LocalEnvironment
from .result import Environment, ProcessResult

__all__ = [
    "BaseEnvironment",
    "DEFAULT_MAX_OUTPUT_CHARS",
    "LocalEnvironment",
    "DockerEnvironment",
    "DockerUnavailableError",
    "docker_available",
    "DEFAULT_IMAGE",
    "make_environment",
    "ProcessResult",
    "Environment",
]
