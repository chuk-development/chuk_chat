"""CoWork execution sandbox.

A ``BaseEnvironment`` ABC with snapshot-file session persistence (borrowed from
Hermes Agent, MIT, and reimplemented), plus local and docker backends, the
per-agent container lifecycle (label-keyed reuse + orphan reaper) and a factory.
See ``docs/COWORK_AGENT_PLATFORM_PLAN.md`` section 6.
"""

from __future__ import annotations

from .base import DEFAULT_MAX_OUTPUT_CHARS, BaseEnvironment
from .docker import (
    BASE_IMAGE,
    CONTAINER_WORKSPACE,
    DEFAULT_IMAGE,
    DEFAULT_USER,
    IMAGE_ENV_VAR,
    DockerEnvironment,
    resolve_image,
)
from .factory import DEFAULT_KIND, KIND_ENV_VAR, make_environment, resolve_kind
from .lifecycle import (
    DEFAULT_TASK_ID,
    LABEL_AGENT,
    LABEL_IMAGE,
    LABEL_MANAGED,
    LABEL_SESSION,
    LABEL_TASK,
    LABEL_WORKSPACE,
    SESSION_LABEL,
    CliResult,
    ContainerInfo,
    DockerCli,
    DockerUnavailableError,
    build_labels,
    docker_available,
    find_agent_container,
    label_args,
    list_containers,
    parse_labels,
    reap_orphans,
    remove_container,
)
from .local import LocalEnvironment
from .result import Environment, ProcessResult

__all__ = [
    "BaseEnvironment",
    "DEFAULT_MAX_OUTPUT_CHARS",
    "LocalEnvironment",
    "DockerEnvironment",
    "DockerUnavailableError",
    "docker_available",
    "BASE_IMAGE",
    "DEFAULT_IMAGE",
    "DEFAULT_USER",
    "IMAGE_ENV_VAR",
    "CONTAINER_WORKSPACE",
    "resolve_image",
    "make_environment",
    "resolve_kind",
    "KIND_ENV_VAR",
    "DEFAULT_KIND",
    "CliResult",
    "ContainerInfo",
    "DockerCli",
    "DEFAULT_TASK_ID",
    "LABEL_AGENT",
    "LABEL_IMAGE",
    "LABEL_MANAGED",
    "LABEL_SESSION",
    "LABEL_TASK",
    "LABEL_WORKSPACE",
    "SESSION_LABEL",
    "build_labels",
    "find_agent_container",
    "label_args",
    "list_containers",
    "parse_labels",
    "reap_orphans",
    "remove_container",
    "ProcessResult",
    "Environment",
]
