"""The schema's own rules: frozen, documented, unique, and one type per field."""

from __future__ import annotations

import dataclasses

import pytest

from chuk_agents_config import (
    ALL_FIELDS,
    FIELDS_BY_ENV,
    FIELDS_BY_PATH,
    SECTIONS,
    AgentsConfig,
)


def test_the_required_sections_exist():
    for name in (
        "sandbox",
        "browser",
        "vnc",
        "documents",
        "model",
        "memory",
        "notify",
        "skills",
        "relay",
        "limits",
    ):
        assert name in SECTIONS


def test_the_sandbox_section_has_what_it_must():
    for name in ("image", "image_digest", "kind", "runtime", "workspace"):
        assert f"sandbox.{name}" in FIELDS_BY_PATH


def test_every_section_is_frozen():
    for cls in SECTIONS.values():
        assert dataclasses.fields(cls)
        assert cls.__dataclass_params__.frozen, cls.__name__
    assert AgentsConfig.__dataclass_params__.frozen


def test_every_setting_documents_itself():
    for spec in ALL_FIELDS:
        assert len(spec.doc) > 25, spec.path
        assert spec.doc[0].isupper() or spec.doc.startswith("``"), spec.path


def test_every_setting_names_an_environment_variable():
    for spec in ALL_FIELDS:
        assert spec.env.startswith("AGENTS_"), spec.path
        assert spec.env.isupper(), spec.path


def test_no_two_settings_share_a_variable_or_a_path():
    assert len(FIELDS_BY_ENV) == len(ALL_FIELDS)
    assert len(FIELDS_BY_PATH) == len(ALL_FIELDS)


def test_every_default_matches_its_own_type():
    for spec in ALL_FIELDS:
        assert isinstance(spec.default, spec.type), spec.path
        if spec.choices:
            assert spec.default in spec.choices, spec.path


def test_a_default_configuration_equals_itself():
    assert AgentsConfig() == AgentsConfig()


def test_the_configuration_cannot_be_mutated():
    config = AgentsConfig()
    with pytest.raises(dataclasses.FrozenInstanceError):
        config.version = 2  # type: ignore[misc]
