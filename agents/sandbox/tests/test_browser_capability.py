"""The browser capability is a property of the image, not of its tag.

Bead cowork-3i5c: the host used to decide "this sandbox can browse" by looking
for the word ``browser`` in ``COWORK_SANDBOX_IMAGE``. With the variable unset —
the normal case — that is always false, so the Playwright MCP server never
started, every ``mcp__playwright__browser_*`` call came back "unknown tool", and
the app's "take over the screen" target stayed dead. These tests pin the
replacement: ask the image whether the launcher is in it.
"""

from __future__ import annotations

from cowork_sandbox.docker import (
    BASE_IMAGE,
    BROWSER_IMAGE,
    BROWSER_MCP_PATH,
    IMAGE_ENV_VAR,
    default_image,
    forget_image_probes,
    image_has_browser,
    image_present,
)
from cowork_sandbox.lifecycle import CliResult


class FakeCli:
    """A docker CLI that answers from a set of images it "has"."""

    def __init__(self, images: set[str], *, with_browser: set[str] | None = None):
        self.images = images
        self.with_browser = with_browser or set()
        self.calls: list[tuple[str, ...]] = []

    def run(self, *args: str, timeout: int | None = None) -> CliResult:
        self.calls.append(args)
        if args[:2] == ("image", "inspect"):
            return CliResult("", "", 0 if args[2] in self.images else 1)
        if args[0] == "run":
            image = args[args.index("test") + 1]
            ok = image in self.with_browser and args[-1] == BROWSER_MCP_PATH
            return CliResult("", "", 0 if ok else 1)
        return CliResult("", "", 0)


def setup_function() -> None:
    forget_image_probes()


def test_image_present_reads_the_daemon():
    cli = FakeCli({BROWSER_IMAGE})
    assert image_present(BROWSER_IMAGE, cli) is True
    assert image_present(BASE_IMAGE, cli) is False


def test_browser_capability_is_the_launcher_not_the_tag():
    cli = FakeCli({"own:1"}, with_browser={"own:1"})
    # A tag that never says "browser" still carries the launcher.
    assert image_has_browser("own:1", cli) is True


def test_a_browserless_image_is_refused_however_it_is_tagged():
    cli = FakeCli({"looks-like-browser:1"})
    assert image_has_browser("looks-like-browser:1", cli) is False


def test_the_probe_runs_once_per_image():
    cli = FakeCli({BROWSER_IMAGE}, with_browser={BROWSER_IMAGE})
    assert image_has_browser(BROWSER_IMAGE, cli) is True
    assert image_has_browser(BROWSER_IMAGE, cli) is True
    assert len([c for c in cli.calls if c[0] == "run"]) == 1


def test_default_image_takes_the_browser_image_when_it_is_built(monkeypatch):
    monkeypatch.delenv(IMAGE_ENV_VAR, raising=False)
    assert default_image(FakeCli({BROWSER_IMAGE})) == BROWSER_IMAGE


def test_default_image_falls_back_to_base(monkeypatch):
    monkeypatch.delenv(IMAGE_ENV_VAR, raising=False)
    assert default_image(FakeCli(set())) == BASE_IMAGE


def test_the_environment_override_still_wins(monkeypatch):
    monkeypatch.setenv(IMAGE_ENV_VAR, "mine:9")
    assert default_image(FakeCli({BROWSER_IMAGE})) == "mine:9"
