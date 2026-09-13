"""The pairing URI and its terminal QR code.

One string carries everything a phone needs to reach a host that is waiting to
pair (docs/PLAN_2026-09-09_CLOUD_PAIRING_TRANSPORT.md, "Pairing UX")::

    cowork://pair?c=<pairing channel>&k=<pairing code>&r=<relay base url>

- ``c`` is the relay pairing channel: 256 CSPRNG bits, the bearer capability the
  host's unauthenticated socket is parked on.
- ``k`` is the §15 pairing code (``<channel id>-<digits>``) — the human path and
  the crypto binding. It is what the user can type when the camera fails.
- ``r`` lets a self-hosted backend be reached without a rebuild. It defaults to
  ``wss://api.chuk.chat`` when absent, so the app must tolerate it missing.

The QR is a convenience, never the only way: the code is printed next to it, and
a terminal that renders the block characters badly still shows a code to type.
"""

from __future__ import annotations

from urllib.parse import urlencode

from .cloud_relay import DEFAULT_RELAY_BASE_URL

#: The scheme + path the app registers for. One line, both pairing paths.
PAIRING_URI_PREFIX = "cowork://pair"


def pairing_uri(
    *,
    pairing_channel: str,
    code: str,
    relay_base_url: str = DEFAULT_RELAY_BASE_URL,
) -> str:
    """Build the one-line pairing URI. Query order is fixed (``c``, ``k``, ``r``)
    so the string is reproducible and testable."""
    query = urlencode(
        [("c", pairing_channel), ("k", code), ("r", relay_base_url or DEFAULT_RELAY_BASE_URL)]
    )
    return f"{PAIRING_URI_PREFIX}?{query}"


def qr_lines(data: str, *, border: int = 1, invert: bool = True) -> list[str]:
    """Render ``data`` as a QR code in half-block characters, one string per line.

    Two module rows per text row, so the code stays square in a terminal whose
    cells are twice as tall as they are wide — a QR stretched to double height is
    one most scanners refuse. The rendering is ``qrcode``'s own ``print_ascii``,
    not a second implementation of it.

    ``invert=True`` (the default) draws for a **dark** terminal: the block
    characters are the light modules and the quiet zone, the background is the
    dark module. That is the common case; a light-background terminal wants
    ``invert=False`` or the scan fails on polarity alone.

    Returns an empty list when the QR library is unavailable, so a caller can
    fall back to printing the code alone rather than failing to pair at all.
    """
    try:
        # Imported here, not at module scope: a missing QR library must cost the
        # QR, never the pairing code next to it.
        import qrcode
    except ImportError:  # pragma: no cover - the dependency is declared
        return []
    import io

    qr = qrcode.QRCode(border=border, box_size=1)
    qr.add_data(data)
    qr.make(fit=True)
    buffer = io.StringIO()
    qr.print_ascii(out=buffer, invert=invert)
    return [line for line in buffer.getvalue().split("\n") if line.strip("\n")]


def qr_text(data: str, *, border: int = 1, invert: bool = True) -> str:
    """The QR code as one printable block, or an empty string when unavailable."""
    return "\n".join(qr_lines(data, border=border, invert=invert))
