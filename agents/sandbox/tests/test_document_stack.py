"""The document-authoring stack in the base image (§9) — contract, then reality.

The sandbox could always *read* a document: ``read_document`` runs
``firecrawl-anydoc`` on the host, so nothing had to be in the image for it. It
could create nothing, because the image shipped Python and uv and no library
above them. An agent asked for a spreadsheet had one option — install a
toolchain first, on the user's clock, over the user's network, in the middle of
the task.

So the libraries live in the image, and these tests pin the two things that make
that worth anything:

* every package is **pinned to an exact version**, like uv and the base digest,
  so two builds of the file give the agent the same library; and
* they go into the **pinned interpreter**, not into a virtualenv — a plain
  ``python3 script.py`` in an agent shell has to import them with no activation,
  because the agent writes that shell command from a skill, not from a memory of
  which venv it made.

The static half parses the Dockerfile and needs no daemon. The live half runs
the imports inside the real image and is skipped where that image is not built.
"""

from __future__ import annotations

from pathlib import Path
import subprocess

import pytest

DOCKER_DIR = Path(__file__).resolve().parents[1] / "docker"
BASE = DOCKER_DIR / "Dockerfile"
BASE_IMAGE = "cowork-base:latest"

#: distribution name on PyPI -> module name to import.
DOC_PACKAGES = {
    "openpyxl": "openpyxl",
    "python-docx": "docx",
    "python-pptx": "pptx",
    "pypdf": "pypdf",
    "reportlab": "reportlab",
    "weasyprint": "weasyprint",
    "Pillow": "PIL",
    "markdown": "markdown",
    "pandas": "pandas",
}

#: WeasyPrint's documented system side, plus a font: a PDF with no font on disk
#: renders blank. Most of this arrives anyway as ffmpeg's dependency tree, which
#: is exactly why it is named — the report must not break when ffmpeg moves.
WEASYPRINT_SYSTEM_LIBS = (
    "libpango-1.0-0",
    "libpangoft2-1.0-0",
    "libpangocairo-1.0-0",
    "libcairo2",
    "libgdk-pixbuf-2.0-0",
    "libharfbuzz0b",
    "libjpeg62-turbo",
    "libfontconfig1",
    "fonts-dejavu-core",
)


def _instructions(path: Path) -> list[str]:
    """The Dockerfile without comments and blank lines, line continuations joined."""
    joined = path.read_text(encoding="utf-8").replace("\\\n", " ")
    return [
        line.strip()
        for line in joined.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def _args(lines: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in lines:
        if not line.upper().startswith("ARG "):
            continue
        _, _, rest = line.partition(" ")
        name, sep, value = rest.strip().partition("=")
        if sep:
            values[name.strip()] = value.strip().strip('"')
    return values


def _expand(text: str, values: dict[str, str]) -> str:
    for name, value in values.items():
        text = text.replace("${" + name + "}", value)
    return text


@pytest.fixture(scope="module")
def dockerfile() -> str:
    lines = _instructions(BASE)
    return _expand(" ".join(lines), _args(lines))


# ------------------------------------------------------------ static contract


def test_every_document_package_is_installed_and_pinned(dockerfile):
    for package in DOC_PACKAGES:
        pin = f"{package}=="
        assert pin in dockerfile, f"{package} is missing from the base image"
        version = dockerfile.split(pin, 1)[1].split('"', 1)[0].split()[0]
        assert version and version[0].isdigit(), (
            f"{package} is not pinned to an exact version (got {version!r})"
        )
        # An unresolved ARG reference would mean the build installs nothing
        # reproducible at all.
        assert "$" not in version


def test_the_libraries_land_in_the_pinned_interpreter_not_a_venv(dockerfile):
    """`python3 script.py` in an agent shell must import them with no activation."""
    install = next(
        line
        for line in _instructions(BASE)
        if "uv pip install" in line and "openpyxl==" in line
    )
    assert "--python /usr/local/bin/python3" in install
    # The uv interpreter marks itself externally managed, so a system install
    # needs both flags; without them the build fails and nothing is installed.
    assert "--system" in install
    assert "--break-system-packages" in install
    assert "uv venv" not in dockerfile
    assert "VIRTUAL_ENV" not in dockerfile


def test_the_install_layer_sits_after_the_interpreter_and_before_yt_dlp():
    """Order is cache economy: the heavy apt and Python layers must not be
    invalidated by a change further down the file."""
    lines = _instructions(BASE)
    python_layer = next(i for i, line in enumerate(lines) if "uv python install" in line)
    doc_layer = next(i for i, line in enumerate(lines) if "openpyxl==" in line)
    yt_layer = next(i for i, line in enumerate(lines) if "uv tool install yt-dlp" in line)
    assert python_layer < doc_layer < yt_layer


def test_the_build_verifies_the_imports_itself(dockerfile):
    """A wheel that resolves is not a library that imports. weasyprint in
    particular fails at import when its system side is missing — the build has
    to find that, not the agent mid-task."""
    assert (
        'python3 -c "import openpyxl, docx, pptx, pypdf, reportlab, weasyprint, pandas"'
        in dockerfile
    )


def test_the_apt_layer_carries_the_weasyprint_system_libraries(dockerfile):
    for package in WEASYPRINT_SYSTEM_LIBS:
        assert f" {package} " in dockerfile, f"{package} is missing from the apt layer"


def test_conversion_and_repair_tools_are_installed(dockerfile):
    # docx/xlsx/pptx -> pdf has no pure-Python answer; qpdf repairs what a
    # generator leaves odd.
    assert " qpdf " in dockerfile
    for package in ("libreoffice-writer", "libreoffice-calc", "libreoffice-impress"):
        assert f" {package} " in dockerfile
    assert "--no-install-recommends" in dockerfile
    # ~280 MB of JRE that `--convert-to pdf` never asks for.
    assert "default-jre-headless" not in dockerfile


def test_the_document_stack_stays_out_of_the_browser_variant():
    """The base image is the cheap one; the browser image builds on top of it,
    so nothing here may be installed twice."""
    browser = (DOCKER_DIR / "Dockerfile.browser").read_text(encoding="utf-8")
    for package in DOC_PACKAGES:
        assert f"{package}==" not in browser


# ---------------------------------------------------------------- live image


def _image_present(image: str) -> bool:
    try:
        probe = subprocess.run(
            ["docker", "image", "inspect", image],
            capture_output=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return probe.returncode == 0


requires_base_image = pytest.mark.skipif(
    not _image_present(BASE_IMAGE),
    reason=f"{BASE_IMAGE} is not built on this machine",
)


@requires_base_image
def test_every_library_imports_inside_the_real_image():
    modules = ", ".join(sorted(set(DOC_PACKAGES.values())))
    probe = subprocess.run(
        ["docker", "run", "--rm", BASE_IMAGE, "python3", "-c", f"import {modules}"],
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert probe.returncode == 0, probe.stderr


@requires_base_image
def test_the_pinned_versions_are_what_the_image_actually_has():
    lines = _instructions(BASE)
    wanted = {}
    text = _expand(" ".join(lines), _args(lines))
    for package in DOC_PACKAGES:
        wanted[package.lower()] = text.split(f"{package}==", 1)[1].split('"', 1)[0].split()[0]
    probe = subprocess.run(
        ["docker", "run", "--rm", BASE_IMAGE, "uv", "pip", "list",
         "--python", "/usr/local/bin/python3", "--system", "--format", "json"],
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert probe.returncode == 0, probe.stderr
    import json

    have = {entry["name"].lower(): entry["version"] for entry in json.loads(probe.stdout)}
    for name, version in wanted.items():
        assert have.get(name) == version, f"{name}: image has {have.get(name)}, file pins {version}"


@requires_base_image
def test_the_image_can_write_a_pdf_and_convert_a_document():
    """The two paths an agent actually takes: HTML -> PDF in process, and
    docx -> PDF through headless LibreOffice (which has no Java here)."""
    script = (
        "from weasyprint import HTML; "
        "HTML(string='<h1>hello</h1>').write_pdf('/tmp/a.pdf'); "
        "import docx; d = docx.Document(); d.add_paragraph('hello'); "
        "d.save('/tmp/b.docx')"
    )
    command = (
        f"python3 -c \"{script}\" && "
        "soffice --headless --convert-to pdf --outdir /tmp /tmp/b.docx >/dev/null && "
        "qpdf --linearize /tmp/b.pdf /tmp/c.pdf && "
        "head -c 5 /tmp/a.pdf && head -c 5 /tmp/c.pdf"
    )
    probe = subprocess.run(
        ["docker", "run", "--rm", BASE_IMAGE, "bash", "-lc", command],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert probe.returncode == 0, probe.stderr
    assert probe.stdout.strip() == "%PDF-%PDF-"
