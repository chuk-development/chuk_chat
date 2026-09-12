"""The four layers, in order, and the rule that an env var still wins.

The last one matters most: docker-compose, the systemd unit and the existing
test suites all export ``COWORK_*`` variables today. If the file could beat
them, this package would change the behaviour of every deployment the day it
lands.
"""

from __future__ import annotations

import pytest

from cowork_config import ConfigError, get_value, load_config


def write(tmp_path, text):
    target = tmp_path / "config.toml"
    target.write_text(text, encoding="utf-8")
    return target


def test_default_wins_when_nothing_else_is_set(tmp_path):
    config = load_config(path=tmp_path / "config.toml", environ={})
    assert config.model.default == "deepseek/deepseek-v4-flash"
    assert config.vnc.port == 5900
    assert config.browser.auto_open is True


def test_file_beats_default(tmp_path):
    path = write(tmp_path, "version = 1\n[model]\ndefault = \"from-file\"\n")
    config = load_config(path=path, environ={})
    assert config.model.default == "from-file"


def test_environment_beats_file(tmp_path):
    path = write(tmp_path, "version = 1\n[model]\ndefault = \"from-file\"\n")
    config = load_config(path=path, environ={"COWORK_MODEL_DEFAULT": "from-env"})
    assert config.model.default == "from-env"


def test_argument_beats_environment(tmp_path):
    path = write(tmp_path, "version = 1\n[model]\ndefault = \"from-file\"\n")
    config = load_config(
        path=path,
        environ={"COWORK_MODEL_DEFAULT": "from-env"},
        overrides={"model.default": "from-argument"},
    )
    assert config.model.default == "from-argument"


def test_all_four_layers_at_once(tmp_path):
    """One load, one field per layer, so the order is checked as a whole."""
    path = write(
        tmp_path,
        "version = 1\n"
        "[model]\n"
        "default = \"from-file\"\n"
        "provider = \"file-provider\"\n"
        "[vnc]\n"
        "port = 5901\n",
    )
    config = load_config(
        path=path,
        environ={"COWORK_MODEL_DEFAULT": "from-env", "COWORK_VNC_PORT": "5902"},
        overrides={"model.default": "from-argument"},
    )
    assert config.model.default == "from-argument"  # argument
    assert config.vnc.port == 5902  # environment
    assert config.model.provider == "file-provider"  # file
    assert config.model.reasoning_effort == ""  # default


@pytest.mark.parametrize(
    ("env", "path", "expected"),
    [
        ({"COWORK_SANDBOX_IMAGE": "custom:9"}, "sandbox.image", "custom:9"),
        ({"COWORK_SANDBOX_KIND": "docker"}, "sandbox.kind", "docker"),
        ({"COWORK_DESKTOP_NOTIFY": "0"}, "notify.desktop", False),
        ({"COWORK_RUN_MAX_SECONDS": "7200"}, "limits.run_max_seconds", 7200.0),
        ({"COWORK_VNC_XDAMAGE": "0"}, "vnc.xdamage", False),
        ({"COWORK_BROWSER_AUTO_OPEN": "false"}, "browser.auto_open", False),
        ({"COWORK_BROWSER_TARGET": "user_browser"}, "browser.target", "user_browser"),
    ],
)
def test_existing_deployments_keep_working(tmp_path, env, path, expected):
    """Every variable a deployment sets today still decides the value."""
    config = load_config(path=tmp_path / "config.toml", environ=env)
    assert get_value(config, path) == expected


def test_empty_environment_variable_counts_as_unset(tmp_path):
    """``${VAR:-default}`` is what the shell scripts already do."""
    config = load_config(path=tmp_path / "config.toml", environ={"COWORK_BROWSER_DISPLAY": ""})
    assert config.browser.display == ":99"


def test_environment_boolean_words(tmp_path):
    for word in ("1", "true", "TRUE", "yes", "on"):
        config = load_config(path=tmp_path / "c.toml", environ={"COWORK_BROWSER_HEADLESS": word})
        assert config.browser.headless is True
    for word in ("0", "false", "no", "off"):
        config = load_config(path=tmp_path / "c.toml", environ={"COWORK_BROWSER_HEADLESS": word})
        assert config.browser.headless is False


def test_bad_environment_value_is_named_not_ignored(tmp_path):
    with pytest.raises(ConfigError) as caught:
        load_config(path=tmp_path / "c.toml", environ={"COWORK_VNC_PORT": "five thousand"})
    assert caught.value.paths() == ("vnc.port",)
    assert "COWORK_VNC_PORT" in str(caught.value)


def test_unknown_override_path_is_named(tmp_path):
    with pytest.raises(ConfigError) as caught:
        load_config(path=tmp_path / "c.toml", environ={}, overrides={"model.defualt": "x"})
    assert caught.value.paths() == ("model.defualt",)
