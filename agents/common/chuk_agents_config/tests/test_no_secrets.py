"""No field of the schema may hold a secret.

A key, a token or a password in ``config.toml`` is one in every backup, bug
report and screenshot of that file. The convention is a **reference**: a field
named ``*_key_ref`` or ``*_token_ref`` holds the NAME of an entry in the
encrypted vault the host already keeps, and the process resolves the name when
it needs the value.

This test is the enforcement. A new field called ``api_key`` fails it, and the
only way to pass is to rename it ``api_key_ref`` and store the reference.
"""

from __future__ import annotations

from chuk_agents_config import ALL_FIELDS, NOT_CONFIG

#: A name with one of these in it is about a credential.
SECRET_WORDS = ("token", "password", "passwd", "api_key", "secret", "credential")

#: The only suffix that makes such a name acceptable: it names a vault entry.
REFERENCE_SUFFIX = "_ref"


def _looks_like_a_secret(name: str) -> bool:
    lowered = name.lower()
    return any(word in lowered for word in SECRET_WORDS)


def test_no_field_holds_a_secret():
    offenders = [
        spec.path
        for spec in ALL_FIELDS
        # Only text can be a credential. A float named
        # ``secret_request_timeout_seconds`` is a clock, not a key.
        if spec.type is str
        and _looks_like_a_secret(spec.name)
        and not spec.name.endswith(REFERENCE_SUFFIX)
    ]
    assert offenders == [], (
        "these settings look like secrets: "
        + ", ".join(offenders)
        + ". Hold a vault entry name in a field ending in _ref instead."
    )


def test_no_environment_variable_of_a_field_holds_a_secret():
    offenders = [
        spec.path
        for spec in ALL_FIELDS
        if spec.type is str
        and _looks_like_a_secret(spec.env)
        and not spec.name.endswith(REFERENCE_SUFFIX)
    ]
    assert offenders == []


def test_the_reference_fields_exist_and_default_to_empty():
    references = [spec for spec in ALL_FIELDS if spec.name.endswith(REFERENCE_SUFFIX)]
    assert {spec.path for spec in references} == {
        "model.api_key_ref",
        "memory.embed_api_key_ref",
    }
    for spec in references:
        assert spec.type is str
        assert spec.default == ""
        assert "vault" in spec.doc


def test_the_secret_variables_are_excluded_on_purpose():
    """The three secret-carrying variables in the tree are named and refused."""
    for name in ("AGENTS_ACCOUNT_TOKEN", "AGENTS_VNC_PASSWD", "AGENTS_MEM_EMBED_API_KEY"):
        assert name in NOT_CONFIG
        assert "secret" in NOT_CONFIG[name].lower()
