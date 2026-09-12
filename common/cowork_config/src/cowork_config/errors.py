"""One error for every problem in a configuration, never one error per problem.

A configuration is read once, at start-up, and the reader is a person who is
about to walk away. If the loader stops at the first bad key, that person fixes
it, starts again, and finds the second bad key. Three typos become three
restarts. So every check in :mod:`cowork_config.loader` appends a
:class:`ConfigProblem` and the loader raises **one** :class:`ConfigError` that
lists all of them.

A problem always names four things:

* the ``section.key`` path, so the reader can find the setting;
* the source it came from (the file, the environment, an explicit argument),
  because the same key can be wrong in three places at once;
* the file and line when the value came from the file, because a name alone is
  not a location;
* what was expected, in words, not a Python type repr.

The rule behind this module: a typo must be loud. A silent fall back to the
built-in default is the worst outcome, because the agent then runs for hours
with the wrong model and the log says nothing.
"""

from __future__ import annotations

from dataclasses import dataclass

__all__ = [
    "SOURCE_ARGUMENT",
    "SOURCE_ENV",
    "SOURCE_FILE",
    "ConfigError",
    "ConfigProblem",
]

#: An explicit argument given by the caller (the highest precedence).
SOURCE_ARGUMENT = "argument"
#: An environment variable.
SOURCE_ENV = "environment"
#: The ``config.toml`` file.
SOURCE_FILE = "file"


@dataclass(frozen=True)
class ConfigProblem:
    """One thing that is wrong, in one place.

    ``path`` is the dotted ``section.key`` the reader edits. For a problem that
    belongs to no single key (an unreadable file, an unknown section) it is the
    section name, or ``"config.toml"`` for the file itself.
    """

    path: str
    message: str
    source: str = SOURCE_FILE
    #: The file the value came from. Only set for :data:`SOURCE_FILE`.
    file: str | None = None
    #: 1-based line in that file, when it could be found. TOML parsers do not
    #: keep line numbers per value, so the loader looks the line up in the raw
    #: text. A key it cannot find gives ``None`` rather than a wrong number.
    line: int | None = None

    def __str__(self) -> str:
        where = f" [{self.source}]"
        if self.source == SOURCE_FILE and self.file:
            where = f" [{self.file}"
            where += f":{self.line}]" if self.line else "]"
        return f"{self.path}: {self.message}{where}"


class ConfigError(Exception):
    """Every problem found while reading one configuration.

    Never raised for a single problem when more were found: read
    :attr:`problems` to act on them one by one, or ``str(error)`` to print the
    whole list to a person.
    """

    def __init__(self, problems: list[ConfigProblem] | tuple[ConfigProblem, ...]) -> None:
        self.problems: tuple[ConfigProblem, ...] = tuple(problems)
        super().__init__(self._render())

    def _render(self) -> str:
        count = len(self.problems)
        head = "1 problem in the CoWork configuration:" if count == 1 else (
            f"{count} problems in the CoWork configuration:"
        )
        body = "\n".join(f"  - {problem}" for problem in self.problems)
        return f"{head}\n{body}"

    def paths(self) -> tuple[str, ...]:
        """The ``section.key`` path of every problem, in the order found."""
        return tuple(problem.path for problem in self.problems)
