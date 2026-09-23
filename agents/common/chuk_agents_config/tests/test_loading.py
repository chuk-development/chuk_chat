"""A missing file, a broken file, an unknown key, a wrong type, a bad enum."""

from __future__ import annotations

import pytest

from chuk_agents_config import ConfigError, config_home, default_config_path, load_config


def test_missing_file_is_not_an_error(tmp_path):
    config = load_config(path=tmp_path / "absent.toml", environ={})
    assert config.sandbox.kind == "auto"


def test_missing_directory_is_not_an_error(tmp_path):
    config = load_config(path=tmp_path / "nope" / "config.toml", environ={})
    assert config.sandbox.kind == "auto"


def test_default_path_follows_agents_home(tmp_path):
    env = {"AGENTS_HOME": str(tmp_path / "state")}
    assert config_home(env) == tmp_path / "state"
    assert default_config_path(env) == tmp_path / "state" / "config.toml"


def test_default_path_expands_a_tilde():
    assert not str(config_home({"AGENTS_HOME": "~/elsewhere"})).startswith("~")


def test_unknown_key_is_named_with_its_line(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text(
        "version = 1\n"
        "\n"
        "[model]\n"
        "default = \"x\"\n"
        "defualt = \"x\"\n",
        encoding="utf-8",
    )
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    problem = caught.value.problems[0]
    assert problem.path == "model.defualt"
    assert problem.line == 5
    assert "is not a known setting" in problem.message
    assert str(path) in str(caught.value)


def test_unknown_section_is_named(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 1\n\n[browsers]\nheadless = true\n", encoding="utf-8")
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    assert caught.value.paths() == ("browsers",)
    assert caught.value.problems[0].line == 3


def test_wrong_type_is_named_never_silently_defaulted(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 1\n[vnc]\nport = \"5900\"\n", encoding="utf-8")
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    problem = caught.value.problems[0]
    assert problem.path == "vnc.port"
    assert "expected an integer" in problem.message
    assert problem.line == 3


def test_boolean_is_not_an_integer(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 1\n[vnc]\nport = true\n", encoding="utf-8")
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    assert "expected an integer" in caught.value.problems[0].message


def test_integer_is_accepted_where_a_number_is_wanted(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 1\n[limits]\nrun_max_seconds = 60\n", encoding="utf-8")
    config = load_config(path=path, environ={})
    assert config.limits.run_max_seconds == 60.0
    assert isinstance(config.limits.run_max_seconds, float)


def test_bad_enum_value_lists_the_choices(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 1\n[sandbox]\nkind = \"podman\"\n", encoding="utf-8")
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    message = caught.value.problems[0].message
    assert "'auto'" in message and "'docker'" in message and "'local'" in message


def test_every_problem_is_reported_at_once(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text(
        "version = 1\n"
        "[sandbox]\n"
        "kind = \"podman\"\n"
        "[vnc]\n"
        "port = \"x\"\n"
        "prot = 1\n"
        "[nosuch]\n"
        "a = 1\n",
        encoding="utf-8",
    )
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    assert set(caught.value.paths()) == {"nosuch", "vnc.prot", "sandbox.kind", "vnc.port"}


def test_broken_toml_names_the_line(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 1\n[model\ndefault = \"x\"\n", encoding="utf-8")
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    assert caught.value.problems[0].line == 2


def test_a_file_from_a_newer_agents_is_refused(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 99\n", encoding="utf-8")
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    assert caught.value.paths() == ("version",)
    assert "newer Agents" in caught.value.problems[0].message


def test_a_file_with_no_version_still_loads(tmp_path):
    """An old hand-written file must not be a wall."""
    path = tmp_path / "config.toml"
    path.write_text("[model]\ndefault = \"x\"\n", encoding="utf-8")
    assert load_config(path=path, environ={}).model.default == "x"


def test_section_written_as_a_value_is_named(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text("version = 1\nmodel = \"opus\"\n", encoding="utf-8")
    with pytest.raises(ConfigError) as caught:
        load_config(path=path, environ={})
    assert caught.value.paths() == ("model",)
    assert "must be a table" in caught.value.problems[0].message
