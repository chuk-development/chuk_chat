"""The install token: one command from the app pairs this host to its account.

The logged-in Chuk app mints the token and shows the user one command::

    curl -fsSL https://api.chuk.chat/agents/install.sh | bash -s -- --token=<P>-<D>

The installer then runs ``agents-host connect --token <P>-<D>``.

Shape of the token (the app implements the same contract):

- ``P`` is exactly 64 lower-case hex characters (256 CSPRNG bits). It has no
  ``-``. The host uses ``P`` for two things: the relay pairing channel that its
  unauthenticated socket parks on, and the §15 ``channel_id``.
- ``D`` is exactly 8 decimal digits. It is the §15 digits.

So the §15 pairing code is the token string itself: ``PC = f"{P}-{D}"``.

The token is a bearer secret. Only the app that minted it knows it, and the app
claims channel ``P`` with its own login. This module never puts the token, ``P``
or ``D`` in an exception message or in a ``repr``: an error message is the
usual way that a secret gets into a log.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

#: Hex characters in ``P``. 64 hex characters = 256 bits.
CHANNEL_HEX_LENGTH = 64

#: Decimal digits in ``D``.
TOKEN_DIGITS = 8

_TOKEN_RE = re.compile(
    rf"\A(?P<channel>[0-9a-f]{{{CHANNEL_HEX_LENGTH}}})-(?P<digits>[0-9]{{{TOKEN_DIGITS}}})\Z"
)


class InvalidInstallToken(ValueError):
    """The text is not an install token.

    The message says what is wrong with the shape. It never contains the text
    itself, because a token with a typing error is still almost a live secret.
    """


@dataclass(frozen=True)
class InstallToken:
    """A parsed install token. ``repr`` and ``str`` show no secret part."""

    channel: str = field(repr=False)
    digits: str = field(repr=False)

    @property
    def pairing_code(self) -> str:
        """The §15 pairing code. It is the same string as the token."""
        return f"{self.channel}-{self.digits}"

    def __str__(self) -> str:  # pragma: no cover - trivial
        return "InstallToken(<hidden>)"


def parse_install_token(text: object) -> InstallToken:
    """Parse and validate an install token. Strict: no case change, no trim.

    A token that the app did not make exactly like this is refused. The only
    thing removed is surrounding white space, because a copy from a terminal
    often adds a line end.
    """
    if not isinstance(text, str):
        raise InvalidInstallToken("the install token is missing")
    candidate = text.strip()
    if not candidate:
        raise InvalidInstallToken("the install token is empty")
    match = _TOKEN_RE.match(candidate)
    if match is None:
        raise InvalidInstallToken(
            "the install token has the wrong format. Copy the full command from "
            "the Chuk app again"
        )
    return InstallToken(channel=match.group("channel"), digits=match.group("digits"))
