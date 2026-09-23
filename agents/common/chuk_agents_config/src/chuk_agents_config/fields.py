"""A setting carries its own env var name, so precedence is data, not code.

Before this package, precedence lived in expressions like
``image or os.environ.get("AGENTS_SANDBOX_IMAGE") or BASE_IMAGE``, repeated
once per setting in the module that happened to need it. Forty-one of those
chains cannot be kept consistent by hand, and none of them could be listed,
printed, validated or written back to a file.

So each setting is declared once, with its default, its environment variable
and its meaning attached:

```python
image: str = setting("", env="AGENTS_SANDBOX_IMAGE", doc="The container image ...")
```

The loader then walks the declarations and applies the same four-step rule to
every one of them: explicit argument, environment variable, ``config.toml``,
built-in default. Nothing is special-cased, so nothing can drift.

The type of a setting is its annotation, and only four are allowed: ``str``,
``int``, ``float`` and ``bool``. A configuration file that a person edits by
hand is not the place for a nested structure, and a flat scalar is the only
shape an environment variable can carry anyway.

An empty environment variable counts as unset. That is what the shell scripts
already do (``${AGENTS_VNC_PORT:-5900}``), and it is the only rule that keeps
an exported-but-empty variable from silently blanking a setting.
"""

from __future__ import annotations

import dataclasses
import math
import typing
from dataclasses import dataclass
from typing import Any

__all__ = [
    "FALSE_WORDS",
    "TRUE_WORDS",
    "FieldSpec",
    "Setting",
    "coerce_env",
    "coerce_value",
    "format_env_value",
    "section_specs",
    "setting",
]

#: The metadata key the declarations hang on. Namespaced, because a dataclass
#: field's metadata is a shared mapping.
METADATA_KEY = "chuk_agents_config"

#: Words an environment variable may use for ``True``. Case is ignored.
TRUE_WORDS = frozenset({"1", "true", "yes", "on"})
#: Words an environment variable may use for ``False``. Case is ignored.
FALSE_WORDS = frozenset({"0", "false", "no", "off"})

_ALLOWED_TYPES: tuple[type, ...] = (str, int, float, bool)

#: The prefix every setting's environment variable carries.
ENV_PREFIX = "AGENTS_"
#: The prefix it carried before the product was renamed. Spelled once, here,
#: so the rename pass has exactly one line to leave alone.
LEGACY_ENV_PREFIX = "COWORK_"  # rename: keep


@dataclass(frozen=True)
class Setting:
    """What a field knows about itself, beyond its type and its default."""

    #: The environment variable that overrides this setting. Every setting has
    #: one, including the settings no code reads from the environment yet: the
    #: name is then the reserved, canonical spelling, so the consumer that
    #: wires it up later cannot invent a second one.
    env: str
    #: What the setting means, in prose. This is the documentation; there is no
    #: second copy in a doc file that can go stale.
    doc: str
    #: The complete set of accepted values, for a setting that is an enum. A
    #: value outside it is an error, never a fall back to the default.
    choices: tuple[str, ...] | None = None


def setting(
    default: Any,
    *,
    env: str,
    doc: str,
    choices: tuple[str, ...] | None = None,
) -> Any:
    """Declare one setting. Use it as the default of a dataclass field."""
    return dataclasses.field(
        default=default,
        metadata={METADATA_KEY: Setting(env=env, doc=doc, choices=choices)},
    )


@dataclass(frozen=True)
class FieldSpec:
    """One setting, resolved: where it lives, what it accepts, what it means."""

    section: str
    name: str
    type: type
    default: Any
    env: str
    doc: str
    choices: tuple[str, ...] | None

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

    @property
    def path(self) -> str:
        """The dotted path a person types: ``model.default``."""
        return f"{self.section}.{self.name}"

    @property
    def type_name(self) -> str:
        """The type as a person says it: ``string``, ``integer``, ``number``,
        ``boolean``, or the list of choices for an enum."""
        if self.choices:
            return "one of " + ", ".join(repr(choice) for choice in self.choices)
        return {
            str: "a string",
            int: "an integer",
            float: "a number",
            bool: "a boolean",
        }[self.type]


def section_specs(section: str, cls: type) -> tuple[FieldSpec, ...]:
    """Read the declarations off one section dataclass."""
    hints = typing.get_type_hints(cls)
    specs: list[FieldSpec] = []
    for field in dataclasses.fields(cls):
        declared = field.metadata.get(METADATA_KEY)
        if not isinstance(declared, Setting):
            raise TypeError(
                f"{cls.__name__}.{field.name} is not declared with setting();"
                " every setting must carry its env var and its meaning"
            )
        field_type = hints[field.name]
        if field_type not in _ALLOWED_TYPES:
            raise TypeError(
                f"{cls.__name__}.{field.name} is {field_type!r};"
                " a setting must be str, int, float or bool"
            )
        specs.append(
            FieldSpec(
                section=section,
                name=field.name,
                type=field_type,
                default=field.default,
                env=declared.env,
                doc=declared.doc,
                choices=declared.choices,
            )
        )
    return tuple(specs)


class CoercionError(ValueError):
    """A value that cannot become the setting's type. Carries a human reason."""


def coerce_env(spec: FieldSpec, raw: str) -> Any:
    """Turn the text of an environment variable into the setting's type.

    The caller has already decided the variable is set and not empty.
    """
    text = raw.strip()
    if spec.type is bool:
        lowered = text.lower()
        if lowered in TRUE_WORDS:
            return True
        if lowered in FALSE_WORDS:
            return False
        raise CoercionError(
            f"expected a boolean ({'/'.join(sorted(TRUE_WORDS))} or "
            f"{'/'.join(sorted(FALSE_WORDS))}), got {raw!r}"
        )
    if spec.type is int:
        try:
            return int(text, 10)
        except ValueError:
            raise CoercionError(f"expected an integer, got {raw!r}") from None
    if spec.type is float:
        try:
            return float(text)
        except ValueError:
            raise CoercionError(f"expected a number, got {raw!r}") from None
    return coerce_value(spec, text)


def coerce_value(spec: FieldSpec, value: Any) -> Any:
    """Check an already-typed value (from TOML or from an explicit argument).

    TOML and Python both carry real types, so this converts nothing except an
    integer where a number is wanted — ``timeout = 60`` must not be an error
    just because the setting is a float.
    """
    if spec.type is bool:
        if isinstance(value, bool):
            return value
        raise CoercionError(f"expected a boolean, got {_said(value)}")
    if spec.type is int:
        # bool is a subclass of int; `true` is not an integer to a reader.
        if isinstance(value, bool) or not isinstance(value, int):
            raise CoercionError(f"expected an integer, got {_said(value)}")
        return value
    if spec.type is float:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise CoercionError(f"expected a number, got {_said(value)}")
        return float(value)
    if not isinstance(value, str):
        raise CoercionError(f"expected a string, got {_said(value)}")
    if spec.choices is not None and value not in spec.choices:
        raise CoercionError(
            f"expected {spec.type_name}, got {value!r}"
        )
    return value


def format_env_value(spec: FieldSpec, value: Any) -> str:
    """The text an environment variable must hold to mean ``value``.

    This is the bridge back to the shell: ``vnc-up.sh`` and ``entrypoint.sh``
    cannot read a TOML file, so a process that starts them exports the settings
    through :func:`chuk_agents_config.loader.export_environ`, which formats every
    value here.
    """
    if spec.type is bool:
        return "1" if value else "0"
    if spec.type is float:
        return _float_text(float(value))
    return str(value)


def _float_text(value: float) -> str:
    if math.isnan(value):
        return "nan"
    if math.isinf(value):
        return "inf" if value > 0 else "-inf"
    return repr(value)


def _said(value: Any) -> str:
    """Name a wrong value the way the person who typed it would."""
    if isinstance(value, bool):
        return f"the boolean {str(value).lower()}"
    if isinstance(value, str):
        return f"the string {value!r}"
    if isinstance(value, (int, float)):
        return f"the number {value!r}"
    if isinstance(value, dict):
        return "a table"
    if isinstance(value, list):
        return "an array"
    return repr(value)
