"""chuk_agents_config — the one typed configuration for every Agents process.

Replaces about forty ``AGENTS_*`` environment variables read at the point of
use across ``host/``, ``executor/``, ``manager/``, ``agent/`` and ``sandbox/``
with one frozen, validated, documented object.

```python
from chuk_agents_config import load_config, get_value, set_value, save_config

config = load_config()                       # $AGENTS_HOME/config.toml
config.sandbox.image                          # typed, never a str | None surprise
get_value(config, "model.default")
config = set_value(config, "model.default", "claude-opus-5")
save_config(config, "~/.agents/config.toml")  # 0600, atomic, lossless
```

Precedence, for every setting, with no exceptions:
**explicit argument > environment variable > config.toml > built-in default.**
An environment variable that is set today still wins, so nothing that runs now
changes behaviour when a file appears.

See :mod:`chuk_agents_config.schema` for every setting and its meaning, and the
README for the environment variable each one replaces.
"""

from .errors import (
    SOURCE_ARGUMENT,
    SOURCE_ENV,
    SOURCE_FILE,
    ConfigError,
    ConfigProblem,
)
from .fields import FieldSpec, Setting
from .loader import (
    CONFIG_FILENAME,
    DEFAULT_HOME,
    config_home,
    migrate_state_home,
    default_config_path,
    export_environ,
    get_value,
    load_config,
    save_config,
    set_value,
    to_toml,
)
from .schema import (
    ALL_FIELDS,
    CONFIG_VERSION,
    FIELDS_BY_ENV,
    FIELDS_BY_PATH,
    NOT_CONFIG,
    SECTIONS,
    AutomationConfig,
    BrowserConfig,
    AgentsConfig,
    DocumentsConfig,
    EmulatorConfig,
    LimitsConfig,
    MemoryConfig,
    ModelConfig,
    NotifyConfig,
    PathsConfig,
    RelayConfig,
    SandboxConfig,
    SkillsConfig,
    VncConfig,
)

__all__ = [
    "ALL_FIELDS",
    "CONFIG_FILENAME",
    "CONFIG_VERSION",
    "DEFAULT_HOME",
    "FIELDS_BY_ENV",
    "FIELDS_BY_PATH",
    "NOT_CONFIG",
    "SECTIONS",
    "SOURCE_ARGUMENT",
    "SOURCE_ENV",
    "SOURCE_FILE",
    "AutomationConfig",
    "BrowserConfig",
    "ConfigError",
    "ConfigProblem",
    "AgentsConfig",
    "DocumentsConfig",
    "EmulatorConfig",
    "FieldSpec",
    "LimitsConfig",
    "MemoryConfig",
    "ModelConfig",
    "NotifyConfig",
    "PathsConfig",
    "RelayConfig",
    "SandboxConfig",
    "Setting",
    "SkillsConfig",
    "VncConfig",
    "config_home",
    "migrate_state_home",
    "default_config_path",
    "export_environ",
    "get_value",
    "load_config",
    "save_config",
    "set_value",
    "to_toml",
]
