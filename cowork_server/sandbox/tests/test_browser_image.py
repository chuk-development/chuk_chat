"""The browser image variant (§8, §9) — static contract, no build.

Building it downloads Chromium plus its system libraries (several hundred MB), so
this suite does not build it. What it does pin is the property that made it a
separate file in the first place: **the default build must stay the cheap one.**

``docker build`` without ``--target`` builds the LAST stage of a Dockerfile. A
browser stage appended to ``Dockerfile`` would therefore silently turn the build
``scripts/install.sh`` runs into the heavy one. So:

* ``Dockerfile`` must not install a browser, and
* ``Dockerfile.browser`` must build FROM the base image, not from Debian again —
  otherwise the two images drift apart on Python, uv and tmux.
"""

from __future__ import annotations

from pathlib import Path

DOCKER_DIR = Path(__file__).resolve().parents[1] / "docker"
BASE = DOCKER_DIR / "Dockerfile"
BROWSER = DOCKER_DIR / "Dockerfile.browser"


def _instructions(path: Path) -> list[str]:
    """The Dockerfile without comments and blank lines, line continuations joined."""
    joined = path.read_text(encoding="utf-8").replace("\\\n", " ")
    return [
        line.strip()
        for line in joined.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def test_the_browser_variant_exists_as_its_own_file():
    assert BROWSER.is_file()


def test_the_browser_variant_builds_on_top_of_the_base_image():
    lines = _instructions(BROWSER)
    froms = [line for line in lines if line.upper().startswith("FROM ")]
    assert froms == ["FROM ${BASE_IMAGE}"]
    args = " ".join(line for line in lines if line.upper().startswith("ARG "))
    assert "BASE_IMAGE=cowork-base:latest" in args


def test_the_base_image_installs_no_browser():
    lines = _instructions(BASE)
    installs = [
        line
        for line in lines
        if any(token in line for token in ("chromium", "chrome", "playwright"))
    ]
    assert installs == [], f"the base image must stay browser-free: {installs}"
    # And it must stay a single-stage file: a second stage would become what a
    # plain `docker build` produces instead of the base image.
    assert len([line for line in lines if line.upper().startswith("FROM ")]) == 1


def test_the_browser_variant_pins_the_installer_and_keeps_the_entrypoint():
    lines = _instructions(BROWSER)
    text = " ".join(lines)
    # Pinned, like every other tool in the base image.
    assert "PLAYWRIGHT_VERSION=" in text
    assert 'playwright==${PLAYWRIGHT_VERSION}"' in text or "playwright==${PLAYWRIGHT_VERSION}" in text
    # The uid-remapping entrypoint must survive, or workspace files land on the
    # host owned by the wrong user.
    assert any(line.startswith("ENTRYPOINT") and "cowork-entrypoint" in line for line in lines)
    # A browser in a container has no CAP_SYS_ADMIN for its own sandbox; the
    # marker browser-use reads for that has to be set.
    assert "IN_DOCKER=true" in text
    # No phone-home from a user's machine.
    assert "ANONYMIZED_TELEMETRY=false" in text
    assert "BROWSER_USE_CLOUD_SYNC=false" in text
