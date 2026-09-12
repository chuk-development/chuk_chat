"""The schema must cover every ``COWORK_*`` variable in the repository.

This test greps the tree the same way the inventory did:

    grep -rhoE "COWORK_[A-Z0-9_]+" --include="*.py" --include="*.sh" \\
        agent/src executor/src manager/src sandbox host scripts | sort -u

Every name it finds must be either a field of the schema or an entry in
:data:`cowork_config.NOT_CONFIG` with a written reason. That is the point of
the test: the schema cannot quietly fall behind the code. A new
``COWORK_SOMETHING`` added anywhere in the tree fails this test until somebody
decides, in writing, whether it is a setting.

It is skipped outside a checkout, because an installed wheel has no repository
to read.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from cowork_config import FIELDS_BY_ENV, NOT_CONFIG

#: The same directories the inventory used.
SEARCH_DIRS = (
    "agent/src",
    "executor/src",
    "manager/src",
    "sandbox",
    "host",
    "scripts",
)
SEARCH_SUFFIXES = (".py", ".sh")
NAME_RE = re.compile(r"COWORK_[A-Z0-9_]+")


def repo_root() -> Path | None:
    # tests/ -> cowork_config/ -> common/ -> the repository
    root = Path(__file__).resolve().parents[3]
    return root if (root / "agent" / "src").is_dir() else None


def found_names() -> set[str]:
    root = repo_root()
    assert root is not None
    names: set[str] = set()
    for folder in SEARCH_DIRS:
        base = root / folder
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.suffix not in SEARCH_SUFFIXES or not path.is_file():
                continue
            if "__pycache__" in path.parts or ".venv" in path.parts:
                continue
            names.update(NAME_RE.findall(path.read_text(encoding="utf-8", errors="replace")))
    return names


@pytest.mark.skipif(repo_root() is None, reason="not run from a checkout")
def test_every_environment_variable_is_decided():
    undecided = sorted(
        name
        for name in found_names()
        if name not in FIELDS_BY_ENV and name not in NOT_CONFIG
    )
    assert undecided == [], (
        "these COWORK_ variables are in the tree but not in the schema: "
        + ", ".join(undecided)
        + ". Add a setting for each, or an entry in NOT_CONFIG saying why not."
    )


@pytest.mark.skipif(repo_root() is None, reason="not run from a checkout")
def test_the_inventory_is_not_empty():
    """A grep that finds nothing would make the test above pass for free."""
    assert len(found_names()) > 40


def test_every_exclusion_has_a_reason():
    for name, reason in NOT_CONFIG.items():
        assert name.startswith("COWORK_")
        assert len(reason) > 30, name


def test_nothing_is_both_a_setting_and_an_exclusion():
    assert set(NOT_CONFIG) & set(FIELDS_BY_ENV) == set()
