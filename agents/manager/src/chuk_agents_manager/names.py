"""Random agent-name generator.

An agent is identified by an auto-assigned random name (§2, §4). Names are
adjective+noun pairs so the collision space is large and the names stay readable
(e.g. "amber-otter"). The roster store guarantees global uniqueness on top of
this by regenerating on collision.
"""

from __future__ import annotations

import random
from collections.abc import Iterable

# Colour-forward adjectives echo the plan's example names ("amber", "cobalt").
_ADJECTIVES: tuple[str, ...] = (
    "amber",
    "cobalt",
    "crimson",
    "azure",
    "olive",
    "violet",
    "teal",
    "scarlet",
    "indigo",
    "coral",
    "jade",
    "russet",
    "slate",
    "copper",
    "ivory",
    "onyx",
    "saffron",
    "maroon",
    "sable",
    "verdant",
    "bronze",
    "cerulean",
    "magenta",
    "sienna",
    "umber",
    "pewter",
    "lilac",
    "ochre",
    "brisk",
    "quiet",
    "swift",
    "clever",
    "steady",
    "keen",
)

_NOUNS: tuple[str, ...] = (
    "otter",
    "falcon",
    "heron",
    "lynx",
    "marten",
    "raven",
    "badger",
    "ferret",
    "osprey",
    "beaver",
    "magpie",
    "shrike",
    "vole",
    "stoat",
    "gannet",
    "puffin",
    "kestrel",
    "wombat",
    "tapir",
    "civet",
    "mongoose",
    "ibis",
    "curlew",
    "plover",
    "dingo",
    "jackal",
    "meerkat",
    "narwhal",
    "walrus",
    "gecko",
    "newt",
    "adder",
)


def random_name(
    *,
    taken: Iterable[str] | None = None,
    rng: random.Random | None = None,
    max_attempts: int = 64,
) -> str:
    """Return an ``adjective-noun`` name not present in ``taken``.

    ``rng`` is injectable so tests are deterministic. After ``max_attempts``
    unique pairs cannot be found, a numeric suffix is appended, which cannot
    collide because the suffix pool is unbounded.
    """
    r = rng or random
    seen = set(taken or ())

    for _ in range(max_attempts):
        name = f"{r.choice(_ADJECTIVES)}-{r.choice(_NOUNS)}"
        if name not in seen:
            return name

    # Exhausted the readable space; fall back to a guaranteed-unique suffix.
    base = f"{r.choice(_ADJECTIVES)}-{r.choice(_NOUNS)}"
    suffix = 2
    while f"{base}-{suffix}" in seen:
        suffix += 1
    return f"{base}-{suffix}"
