"""Write it, read it, get the same object. And nobody else can read the file."""

from __future__ import annotations

import dataclasses
import stat

import pytest

from cowork_config import (
    ALL_FIELDS,
    ConfigError,
    CoworkConfig,
    export_environ,
    get_value,
    load_config,
    save_config,
    set_value,
    to_toml,
)


def _every_field_changed() -> CoworkConfig:
    """A configuration where no field is its default.

    A round trip over defaults proves nothing: a writer that dropped a key
    would still read back the same object.
    """
    config = CoworkConfig()
    for spec in ALL_FIELDS:
        if spec.type is bool:
            value = not spec.default
        elif spec.type is int:
            value = int(spec.default) + 7
        elif spec.type is float:
            value = float(spec.default) + 0.5
        elif spec.choices:
            value = next(c for c in spec.choices if c != spec.default)
        else:
            value = f"changed-{spec.name}"
        config = set_value(config, spec.path, value)
    return config


def test_round_trip_is_lossless_for_every_field(tmp_path):
    original = _every_field_changed()
    for spec in ALL_FIELDS:
        assert get_value(original, spec.path) != spec.default, spec.path
    path = save_config(original, tmp_path / "config.toml")
    assert load_config(path=path, environ={}) == original


def test_round_trip_of_the_defaults(tmp_path):
    original = CoworkConfig()
    path = save_config(original, tmp_path / "config.toml")
    assert load_config(path=path, environ={}) == original


def test_round_trip_survives_awkward_strings(tmp_path):
    config = CoworkConfig()
    config = set_value(config, "browser.home_url", 'https://x/?a="b"&c=\\d')
    config = set_value(config, "notify.icon", "a\ttab\nand a newline")
    config = set_value(config, "emulator.extra_args", "-no-snapshot -gpu 'swiftshader'")
    path = save_config(config, tmp_path / "config.toml")
    assert load_config(path=path, environ={}) == config


def test_saved_file_is_private(tmp_path):
    path = save_config(CoworkConfig(), tmp_path / "config.toml")
    mode = stat.S_IMODE(path.stat().st_mode)
    assert mode == 0o600, oct(mode)


def test_saved_file_replaces_an_existing_one_and_stays_private(tmp_path):
    target = tmp_path / "config.toml"
    target.write_text("version = 1\n", encoding="utf-8")
    target.chmod(0o644)
    save_config(set_value(CoworkConfig(), "vnc.port", 5901), target)
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert load_config(path=target, environ={}).vnc.port == 5901
    assert not (tmp_path / "config.toml.tmp").exists()


def test_save_creates_the_state_directory(tmp_path):
    path = save_config(CoworkConfig(), tmp_path / "deep" / "state" / "config.toml")
    assert path.exists()


def test_file_starts_with_the_version(tmp_path):
    text = to_toml(CoworkConfig())
    body = [line for line in text.splitlines() if line and not line.startswith("#")]
    assert body[0] == "version = 1"


def test_only_changed_values_can_be_written(tmp_path):
    config = set_value(CoworkConfig(), "model.default", "claude-opus-5")
    text = to_toml(config, include_defaults=False)
    assert "claude-opus-5" in text
    assert "[vnc]" not in text
    path = tmp_path / "config.toml"
    path.write_text(text, encoding="utf-8")
    assert load_config(path=path, environ={}) == config


def test_set_value_returns_a_new_configuration():
    config = CoworkConfig()
    changed = set_value(config, "model.default", "claude-opus-5")
    assert config.model.default == "deepseek/deepseek-v4-flash"
    assert changed.model.default == "claude-opus-5"
    with pytest.raises(dataclasses.FrozenInstanceError):
        config.model.default = "no"  # type: ignore[misc]


def test_set_value_accepts_text_for_any_type():
    config = CoworkConfig()
    assert set_value(config, "vnc.port", "5901").vnc.port == 5901
    assert set_value(config, "notify.desktop", "off").notify.desktop is False
    assert set_value(config, "limits.run_max_seconds", "30").limits.run_max_seconds == 30.0


def test_set_value_refuses_a_bad_value():
    with pytest.raises(ConfigError) as caught:
        set_value(CoworkConfig(), "sandbox.kind", "podman")
    assert caught.value.paths() == ("sandbox.kind",)


def test_unknown_paths_are_refused_by_both_accessors():
    with pytest.raises(ConfigError):
        get_value(CoworkConfig(), "model.defualt")
    with pytest.raises(ConfigError):
        set_value(CoworkConfig(), "model.defualt", "x")


def test_export_environ_carries_only_what_was_chosen():
    config = set_value(CoworkConfig(), "vnc.port", 5901)
    exported = export_environ(config)
    assert exported == {"COWORK_VNC_PORT": "5901"}


def test_export_environ_formats_the_way_the_shell_reads_it():
    config = CoworkConfig()
    config = set_value(config, "vnc.xdamage", False)
    config = set_value(config, "browser.headless", True)
    config = set_value(config, "limits.run_max_seconds", 30.0)
    exported = export_environ(config)
    assert exported["COWORK_VNC_XDAMAGE"] == "0"
    assert exported["COWORK_BROWSER_HEADLESS"] == "1"
    assert exported["COWORK_RUN_MAX_SECONDS"] == "30.0"


def test_export_environ_round_trips_through_the_environment(tmp_path):
    original = _every_field_changed()
    exported = export_environ(original, include_defaults=True)
    assert load_config(path=tmp_path / "absent.toml", environ=exported) == original
