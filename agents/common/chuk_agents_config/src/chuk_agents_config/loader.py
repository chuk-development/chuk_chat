"""Read, validate, write and export one Agents configuration.

The rule this module exists to make true, for every setting, with no
exceptions:

    explicit argument  >  environment variable  >  config.toml  >  default

It is applied by walking :data:`chuk_agents_config.schema.ALL_FIELDS`, not by a
chain of ``or`` expressions, so a new setting obeys it the moment it is
declared. The environment sits **above** the file on purpose: a deployment that
exports ``AGENTS_SANDBOX_IMAGE`` today keeps winning after a ``config.toml``
appears, so docker-compose, the systemd unit and the test suite are unaffected
by this package landing.

Four more decisions worth stating, because each one is the opposite of the easy
version:

*A missing file is not an error.* A fresh install has no ``config.toml`` and
must start with the defaults. Only a file that exists and is wrong is a
failure.

*A wrong file is a loud error, and it names everything.* An unknown key, a
wrong type or a value outside an enum raises one :class:`ConfigError` listing
every problem with its ``section.key`` path and, for the file, the line. The
loader never falls back to the default for a value it could not read. A typo
that silently becomes the default is how an agent runs all night on the wrong
model.

*The writer is atomic and private.* ``config.toml`` sits next to the account
store and the vault in the state directory, so it is written the same way:
``os.open`` with mode ``0600``, into a temporary file, then ``os.replace``. A
reader never sees a half-written file, and no other account on the machine ever
sees the file at all.

*The environment can be rebuilt from the configuration.* Several parts of
Agents are shell scripts inside a container image — ``vnc-up.sh``,
``browser-mcp.sh``, ``entrypoint.sh`` — and a shell script cannot read TOML.
:func:`export_environ` turns the configuration back into the ``AGENTS_*``
variables those scripts already read, so the file is the source of truth even
where the consumer is ``${AGENTS_VNC_PORT:-5900}``.
"""

from __future__ import annotations

import dataclasses
import json
import math
import os
import re
import tomllib
import warnings
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from .errors import (
    SOURCE_ARGUMENT,
    SOURCE_ENV,
    SOURCE_FILE,
    ConfigError,
    ConfigProblem,
)
from .fields import CoercionError, FieldSpec, coerce_env, coerce_value, format_env_value
from .schema import (
    ALL_FIELDS,
    CONFIG_VERSION,
    FIELDS_BY_PATH,
    SECTIONS,
    AgentsConfig,
)

__all__ = [
    "CONFIG_FILENAME",
    "DEFAULT_HOME",
    "config_home",
    "default_config_path",
    "migrate_state_home",
    "export_environ",
    "get_value",
    "load_config",
    "save_config",
    "set_value",
    "to_toml",
]

#: The state directory when nothing says otherwise.
DEFAULT_HOME = "~/.agents"
#: The file inside it.
CONFIG_FILENAME = "config.toml"

#: ``version n -> a function that returns the raw table at version n + 1``.
#: Empty at version 1. See :data:`chuk_agents_config.schema.CONFIG_VERSION` for when
#: and how to add one.
_MIGRATIONS: dict[int, Callable[[dict[str, Any]], dict[str, Any]]] = {}

_TOML_LINE_RE = re.compile(r"at line (\d+)")


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


# -- where the file is -------------------------------------------------------


def config_home(environ: Mapping[str, str] | None = None) -> Path:
    """The state directory: ``$AGENTS_HOME``, else ``~/.agents``."""
    env = os.environ if environ is None else environ
    raw = (env.get(HOME_ENV) or "").strip()
    if not raw:
        legacy = (env.get(LEGACY_HOME_ENV) or "").strip()
        if legacy:
            warn_legacy_env(HOME_ENV, LEGACY_HOME_ENV)
            raw = legacy
    return migrate_state_home(Path(raw or DEFAULT_HOME).expanduser())


def default_config_path(environ: Mapping[str, str] | None = None) -> Path:
    """``$AGENTS_HOME/config.toml``.

    The location is settled before the file is read, so a ``paths.home`` inside
    the file moves the state directory for everything else but not the file
    that said so. Move the file itself with ``$AGENTS_HOME`` or an explicit
    path.
    """
    return config_home(environ) / CONFIG_FILENAME


# -- reading -----------------------------------------------------------------


def load_config(
    path: str | Path | None = None,
    environ: Mapping[str, str] | None = None,
    overrides: Mapping[str, Any] | None = None,
) -> AgentsConfig:
    """Build the configuration for this process.

    ``path`` is the file to read; ``None`` means :func:`default_config_path`.
    ``environ`` is the environment to read; ``None`` means the real one.
    ``overrides`` is the explicit-argument layer: a mapping of dotted paths to
    values, e.g. ``{"model.default": "claude-opus-5"}``, which beats everything
    else. This is what a command-line flag becomes.

    A missing file gives the defaults. Anything else that is wrong raises
    :class:`ConfigError` listing every problem at once.
    """
    env = dict(os.environ if environ is None else environ)
    target = Path(path).expanduser() if path is not None else default_config_path(env)
    problems: list[ConfigProblem] = []

    text, table = _read_file(target, problems)
    if problems:
        raise ConfigError(problems)

    table = _check_version(table, text, target, problems)
    _check_shape(table, text, target, problems)
    override_values = _check_overrides(overrides, problems)

    values: dict[str, dict[str, Any]] = {name: {} for name in SECTIONS}
    for spec in ALL_FIELDS:
        values[spec.section][spec.name] = _resolve_field(
            spec, table, text, target, env, override_values, problems
        )

    if problems:
        raise ConfigError(problems)

    sections = {name: cls(**values[name]) for name, cls in SECTIONS.items()}
    return AgentsConfig(version=CONFIG_VERSION, **sections)


def _read_file(
    target: Path, problems: list[ConfigProblem]
) -> tuple[str, dict[str, Any]]:
    try:
        text = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "", {}
    except OSError as error:
        problems.append(
            ConfigProblem(
                path=CONFIG_FILENAME,
                message=f"cannot be read: {error.strerror or error}",
                source=SOURCE_FILE,
                file=str(target),
            )
        )
        return "", {}
    try:
        return text, tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        found = _TOML_LINE_RE.search(str(error))
        problems.append(
            ConfigProblem(
                path=CONFIG_FILENAME,
                message=f"is not valid TOML: {error}",
                source=SOURCE_FILE,
                file=str(target),
                line=int(found.group(1)) if found else None,
            )
        )
        return text, {}


def _check_version(
    table: dict[str, Any],
    text: str,
    target: Path,
    problems: list[ConfigProblem],
) -> dict[str, Any]:
    """Refuse a file from the future; migrate a file from the past."""
    if "version" not in table:
        return table
    raw = table["version"]
    if isinstance(raw, bool) or not isinstance(raw, int):
        problems.append(
            ConfigProblem(
                path="version",
                message="must be an integer",
                source=SOURCE_FILE,
                file=str(target),
                line=_locate(text, None, "version"),
            )
        )
        return table
    if raw > CONFIG_VERSION:
        problems.append(
            ConfigProblem(
                path="version",
                message=(
                    f"is {raw}, but this Agents reads at most {CONFIG_VERSION};"
                    " a newer Agents wrote this file. Upgrade, or move the file"
                    " aside."
                ),
                source=SOURCE_FILE,
                file=str(target),
                line=_locate(text, None, "version"),
            )
        )
        return table
    while raw < CONFIG_VERSION:
        migrate = _MIGRATIONS.get(raw)
        if migrate is None:  # pragma: no cover - impossible while _MIGRATIONS is full
            problems.append(
                ConfigProblem(
                    path="version",
                    message=f"is {raw} and there is no migration from it",
                    source=SOURCE_FILE,
                    file=str(target),
                    line=_locate(text, None, "version"),
                )
            )
            return table
        table = migrate(table)
        raw += 1
    return table


def _check_shape(
    table: Mapping[str, Any],
    text: str,
    target: Path,
    problems: list[ConfigProblem],
) -> None:
    """Name every unknown section and every unknown key. Never guess."""
    for key, value in table.items():
        if key == "version":
            continue
        if key not in SECTIONS:
            problems.append(
                ConfigProblem(
                    path=key,
                    message=(
                        "is not a known section; expected one of "
                        + ", ".join(sorted(SECTIONS))
                    ),
                    source=SOURCE_FILE,
                    file=str(target),
                    line=_locate(text, key, None),
                )
            )
            continue
        if not isinstance(value, dict):
            problems.append(
                ConfigProblem(
                    path=key,
                    message="must be a table, written as [" + key + "]",
                    source=SOURCE_FILE,
                    file=str(target),
                    line=_locate(text, None, key),
                )
            )
            continue
        known = {spec.name for spec in ALL_FIELDS if spec.section == key}
        for inner in value:
            if inner in known:
                continue
            problems.append(
                ConfigProblem(
                    path=f"{key}.{inner}",
                    message=(
                        "is not a known setting; the keys of ["
                        + key
                        + "] are "
                        + ", ".join(sorted(known))
                    ),
                    source=SOURCE_FILE,
                    file=str(target),
                    line=_locate(text, key, inner),
                )
            )


def _check_overrides(
    overrides: Mapping[str, Any] | None, problems: list[ConfigProblem]
) -> dict[str, Any]:
    if not overrides:
        return {}
    checked: dict[str, Any] = {}
    for path, value in overrides.items():
        if path not in FIELDS_BY_PATH:
            problems.append(
                ConfigProblem(
                    path=path,
                    message="is not a known setting",
                    source=SOURCE_ARGUMENT,
                )
            )
            continue
        checked[path] = value
    return checked


def _resolve_field(
    spec: FieldSpec,
    table: Mapping[str, Any],
    text: str,
    target: Path,
    env: Mapping[str, str],
    overrides: Mapping[str, Any],
    problems: list[ConfigProblem],
) -> Any:
    """One field, one precedence rule. The first layer that has it wins.

    A layer that has the field but cannot be read is a problem, and the field
    keeps its default so the rest of the load can continue and report the rest
    of the problems. The caller never sees that default: the problems make the
    load raise.
    """
    if spec.path in overrides:
        try:
            return coerce_value(spec, overrides[spec.path])
        except CoercionError as error:
            problems.append(
                ConfigProblem(path=spec.path, message=str(error), source=SOURCE_ARGUMENT)
            )
            return spec.default

    raw_env, env_name = _read_env(spec, env)
    if raw_env is not None and raw_env.strip():
        try:
            return coerce_env(spec, raw_env)
        except CoercionError as error:
            problems.append(
                ConfigProblem(
                    path=spec.path,
                    message=f"{error} (from ${env_name})",
                    source=SOURCE_ENV,
                )
            )
            return spec.default

    section = table.get(spec.section)
    if isinstance(section, dict) and spec.name in section:
        try:
            return coerce_value(spec, section[spec.name])
        except CoercionError as error:
            problems.append(
                ConfigProblem(
                    path=spec.path,
                    message=str(error),
                    source=SOURCE_FILE,
                    file=str(target),
                    line=_locate(text, spec.section, spec.name),
                )
            )
            return spec.default

    return spec.default


def _locate(text: str, section: str | None, key: str | None) -> int | None:
    """The 1-based line of ``key`` inside ``[section]``, when it can be found.

    TOML parsers keep no line for a value, so the line comes from the raw text.
    A key that cannot be found gives ``None``: no line is better than a wrong
    one.
    """
    if not text:
        return None
    lines = text.splitlines()
    start = 0
    if section is not None:
        header = re.compile(r"^\s*\[\s*" + re.escape(section) + r"\s*\]")
        for index, line in enumerate(lines):
            if header.match(line):
                if key is None:
                    return index + 1
                start = index + 1
                break
        else:
            return None
    if key is None:
        return None
    pattern = re.compile(r"^\s*(" + re.escape(key) + r"|\"" + re.escape(key) + r"\")\s*=")
    for index in range(start, len(lines)):
        line = lines[index]
        if section is not None and re.match(r"^\s*\[", line):
            break
        if pattern.match(line):
            return index + 1
    return None


# -- reading and writing one value ------------------------------------------


def get_value(config: AgentsConfig, path: str) -> Any:
    """One setting by its dotted path: ``get_value(config, "model.default")``.

    Raises :class:`ConfigError` for an unknown path, with the same named-path
    wording the loader uses, so a CLI can print it unchanged.
    """
    spec = FIELDS_BY_PATH.get(path)
    if spec is None:
        raise ConfigError(
            [ConfigProblem(path=path, message="is not a known setting", source=SOURCE_ARGUMENT)]
        )
    return getattr(getattr(config, spec.section), spec.name)


def set_value(config: AgentsConfig, path: str, value: Any) -> AgentsConfig:
    """A copy of ``config`` with one setting changed.

    The configuration is frozen, so this returns a new one. Text is accepted
    for any type — ``set_value(config, "vnc.port", "5901")`` works — because
    the caller is usually a command line, where every value is text.
    """
    spec = FIELDS_BY_PATH.get(path)
    if spec is None:
        raise ConfigError(
            [ConfigProblem(path=path, message="is not a known setting", source=SOURCE_ARGUMENT)]
        )
    try:
        checked = coerce_env(spec, value) if isinstance(value, str) else coerce_value(spec, value)
    except CoercionError as error:
        raise ConfigError(
            [ConfigProblem(path=path, message=str(error), source=SOURCE_ARGUMENT)]
        ) from None
    section = dataclasses.replace(getattr(config, spec.section), **{spec.name: checked})
    return dataclasses.replace(config, **{spec.section: section})


# -- writing -----------------------------------------------------------------


def to_toml(config: AgentsConfig, *, include_defaults: bool = True) -> str:
    """Render the configuration as the text of a ``config.toml``.

    With ``include_defaults`` the file holds every setting, so reading it back
    gives exactly this configuration — that is the round trip
    :func:`save_config` promises. Without it the file holds only what differs
    from the built-in defaults, so a later Agents whose defaults moved still
    reaches this install; the trade is that the file no longer shows the full
    list.
    """
    out: list[str] = [
        "# Agents configuration. Written by chuk_agents_config; safe to edit by hand.",
        "#",
        "# An environment variable beats this file, and an explicit argument",
        "# beats both. Every key's variable and meaning are in the README.",
        "# No secret belongs here: a field ending in _ref names a vault entry.",
        "",
        f"version = {config.version}",
    ]
    for name in SECTIONS:
        section = getattr(config, name)
        specs = [spec for spec in ALL_FIELDS if spec.section == name]
        rows = [
            (spec, getattr(section, spec.name))
            for spec in specs
            if include_defaults or getattr(section, spec.name) != spec.default
        ]
        if not rows:
            continue
        out.append("")
        out.append(f"[{name}]")
        for spec, value in rows:
            out.append(f"{spec.name} = {_toml_value(spec, value)}")
    return "\n".join(out) + "\n"


def save_config(
    config: AgentsConfig,
    path: str | Path | None = None,
    *,
    include_defaults: bool = True,
) -> Path:
    """Write the configuration, atomically, readable only by this account.

    The temporary file is created with :func:`os.open` and mode ``0600``, then
    renamed over the target, which is the same pattern the account store uses:
    a reader never sees a partial file, and the mode is set at creation rather
    than after, so there is no window in which the file is world readable.

    Returns the path written.
    """
    target = Path(path).expanduser() if path is not None else default_config_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    text = to_toml(config, include_defaults=include_defaults)
    tmp = target.with_suffix(target.suffix + ".tmp")
    handle_fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(handle_fd, "w", encoding="utf-8") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)
    # os.open only applies the mode when it creates the file; an existing
    # temporary file from a crashed write would keep its old mode.
    os.chmod(target, 0o600)
    return target


def _toml_value(spec: FieldSpec, value: Any) -> str:
    if spec.type is bool:
        return "true" if value else "false"
    if spec.type is int:
        return str(int(value))
    if spec.type is float:
        return _toml_float(float(value))
    # TOML basic strings take the same escapes as JSON, and json.dumps emits
    # only escapes TOML accepts.
    return json.dumps(str(value))


def _toml_float(value: float) -> str:
    if math.isnan(value):
        return "nan"
    if math.isinf(value):
        return "inf" if value > 0 else "-inf"
    text = repr(value)
    if "." not in text and "e" not in text and "E" not in text:
        text += ".0"
    return text


# -- back to the environment -------------------------------------------------


def export_environ(
    config: AgentsConfig, *, include_defaults: bool = False
) -> dict[str, str]:
    """The ``AGENTS_*`` variables that mean this configuration.

    For the parts of Agents that are shell scripts in a container image and
    cannot read a TOML file. By default only the settings that differ from
    their built-in default are exported, so the environment a container is
    started with stays short and a reader can see what was actually chosen.
    """
    out: dict[str, str] = {}
    for spec in ALL_FIELDS:
        value = getattr(getattr(config, spec.section), spec.name)
        if not include_defaults and value == spec.default:
            continue
        out[spec.env] = format_env_value(spec, value)
    return out
