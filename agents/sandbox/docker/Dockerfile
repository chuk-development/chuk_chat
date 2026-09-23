# Agents agent base image (§6, §9).
#
# One of these runs per agent: a small Debian the agent owns completely. It may
# `sudo apt install` anything, break it, and be thrown away — the workspace it
# must not lose is a host bind mount at /workspace, not part of this image.
#
# Reproducibility: the base layer is pinned by **digest**, apt installs are
# version-agnostic but recorded in the layer, and `uv` is pinned to an exact
# release and verified against its published checksum. Two builds of this file
# therefore install the same tool versions.
#
# Size, measured on amd64 with `docker image inspect`, not guessed: the
# document-authoring stack below (LibreOffice + qpdf + nine pinned wheels) takes
# the image from 858 MB to 1.42 GB, so **+565 MB** — 379 MB of it apt
# (LibreOffice is nearly all of that), 186 MB of it wheels (pandas and numpy are
# nearly all of that), and 0 for WeasyPrint's system libraries, which ffmpeg
# already pulled in. That is the price of an agent that can hand back a
# spreadsheet at all, paid once at build time and never again per task.
#
# Deliberately NOT here: the browser stack (Chromium + its system libraries,
# several hundred MB). It lands in a separate image built on top of this one —
# `Dockerfile.browser`, tagged `agents-browser:latest` — so an agent that never
# browses does not pay for it, and so this image stays quick to build. §8 makes
# that the normal case: API tools first, the browser only as the fallback.

ARG DEBIAN_BASE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
FROM ${DEBIAN_BASE}

# uv release to install, and the Python it provisions. Python comes from uv (a
# standalone build) rather than apt, so the version is exactly what the plan
# pins and does not drift with the Debian release.
ARG UV_VERSION=0.9.28
ARG PYTHON_VERSION=3.12
ARG AGENTS_USER=agents
ARG AGENTS_UID=1000
ARG AGENTS_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_LINK_MODE=copy \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

# Runtime dependencies the agent runtime and its tools assume are present.
# tmux backs the interactive-terminal tool (§7.8); git backs the versioned
# workspace (§7.7); the rest is what any shell session needs.
#
# The document block in the middle is the *writing* half of §9: the host can
# already read any document (`read_document` / firecrawl-anydoc), so the gap was
# that the agent could produce nothing. qpdf repairs and linearizes a PDF that a
# generator left odd. libreoffice-writer/calc/impress is the only honest
# docx/xlsx/pptx -> pdf converter; `soffice --headless --convert-to pdf` needs
# no display. **No `default-jre-headless`**: it costs ~190 MB installed (11
# packages, measured with apt-cache Installed-Size on this base) and
# nothing in the convert-to-pdf path asks for it — Java in LibreOffice is for
# Base, for macros and for a handful of Calc add-in functions, none of which an
# agent script uses. Add it only when a real task proves it missing.
# The pango/cairo/gdk-pixbuf/harfbuzz/jpeg/fontconfig set plus fonts-dejavu-core
# is WeasyPrint's documented system side. On this image the whole set is already
# pulled in as ffmpeg's dependency tree, so naming it costs **0 bytes** — but it
# is named anyway, because "HTML report renders" must not depend on ffmpeg
# staying in the list, and because without a font on disk every PDF comes out
# blank.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
        git \
        git-lfs \
        tmux \
        sudo \
        procps \
        psmisc \
        less \
        nano \
        file \
        jq \
        unzip \
        zip \
        xz-utils \
        bzip2 \
        gzip \
        tar \
        rsync \
        openssh-client \
        gnupg \
        locales \
        tzdata \
        ripgrep \
        ffmpeg \
        qpdf \
        libreoffice-writer \
        libreoffice-calc \
        libreoffice-impress \
        libpango-1.0-0 \
        libpangoft2-1.0-0 \
        libpangocairo-1.0-0 \
        libcairo2 \
        libgdk-pixbuf-2.0-0 \
        libharfbuzz0b \
        libjpeg62-turbo \
        libfontconfig1 \
        fontconfig \
        fonts-dejavu-core \
        libexpat1 \
        zlib1g \
        libsqlite3-0 \
        libssl3 \
        libffi8 \
        libbz2-1.0 \
        liblzma5 \
        libncursesw6 \
        libreadline8 \
        libuuid1 \
    ; \
    rm -rf /var/lib/apt/lists/*

# uv, pinned and checksum-verified. `uv` is the only Python installer in the
# image: it provisions the interpreter and every project environment (§9).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) target='x86_64-unknown-linux-gnu' ;; \
        arm64) target='aarch64-unknown-linux-gnu' ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"; \
    curl -fsSL -o /tmp/uv.tar.gz "${base}/uv-${target}.tar.gz"; \
    curl -fsSL -o /tmp/uv.sha256 "${base}/uv-${target}.tar.gz.sha256"; \
    printf '%s  /tmp/uv.tar.gz\n' "$(cut -d' ' -f1 < /tmp/uv.sha256)" | sha256sum -c -; \
    tar -xzf /tmp/uv.tar.gz -C /tmp; \
    install -m 0755 "/tmp/uv-${target}/uv" /usr/local/bin/uv; \
    install -m 0755 "/tmp/uv-${target}/uvx" /usr/local/bin/uvx; \
    rm -rf /tmp/uv.tar.gz /tmp/uv.sha256 "/tmp/uv-${target}"; \
    uv --version

# The pinned interpreter, installed system-wide and linked onto PATH so a plain
# `python3` in an agent command works without activating anything.
RUN set -eux; \
    uv python install "${PYTHON_VERSION}"; \
    uv python find "${PYTHON_VERSION}" > /tmp/pybin; \
    ln -sf "$(cat /tmp/pybin)" /usr/local/bin/python3; \
    ln -sf /usr/local/bin/python3 /usr/local/bin/python; \
    rm -f /tmp/pybin; \
    python3 --version; \
    chmod -R a+rX /opt/python

# The document-authoring stack, installed into the pinned interpreter itself so
# that `python3 make_report.py` in a plain agent shell just works — no venv, no
# activation, no `pip install` round trip in the middle of a task. Reading a
# document happens on the host (`read_document`); *creating* one happens here,
# and an agent that has to install its own toolchain first spends a minute of
# the user's time before it writes a single cell.
#
# One library per target, no overlap: openpyxl (xlsx), python-docx (docx),
# python-pptx (pptx), reportlab (PDF drawn programmatically), weasyprint (PDF
# from HTML+CSS, for anything that reads like a report), pypdf (fill an existing
# AcroForm, merge, split, watermark), Pillow (images, and what weasyprint uses
# to embed them), markdown (md -> HTML, the usual input to weasyprint) and
# pandas (the table in the middle of all of it).
#
# Pinned exactly, like uv and the base digest above: two builds of this file
# install the same versions. `--system --break-system-packages` because the uv
# interpreter marks itself externally managed; the alternative is a venv the
# agent would have to know to activate, which defeats the point.
ARG DOC_OPENPYXL=3.1.5
ARG DOC_PYTHON_DOCX=1.2.0
ARG DOC_PYTHON_PPTX=1.0.2
ARG DOC_PYPDF=6.18.1
ARG DOC_REPORTLAB=5.0.1
ARG DOC_WEASYPRINT=70.0
ARG DOC_PILLOW=12.3.0
ARG DOC_MARKDOWN=3.10.3
ARG DOC_PANDAS=3.0.5
RUN set -eux; \
    uv pip install --no-cache --python /usr/local/bin/python3 --system --break-system-packages \
        "openpyxl==${DOC_OPENPYXL}" \
        "python-docx==${DOC_PYTHON_DOCX}" \
        "python-pptx==${DOC_PYTHON_PPTX}" \
        "pypdf==${DOC_PYPDF}" \
        "reportlab==${DOC_REPORTLAB}" \
        "weasyprint==${DOC_WEASYPRINT}" \
        "Pillow==${DOC_PILLOW}" \
        "markdown==${DOC_MARKDOWN}" \
        "pandas==${DOC_PANDAS}" \
    ; \
    chmod -R a+rX "$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"

# Verification, not decoration: a wheel that resolves is not the same as a
# library that imports. weasyprint in particular fails at import time when its
# system libraries are missing, and that is exactly the failure an agent would
# otherwise hit mid-task.
RUN set -eux; \
    python3 -c "import openpyxl, docx, pptx, pypdf, reportlab, weasyprint, pandas"; \
    python3 -c "import markdown, PIL"; \
    soffice --version; \
    qpdf --version

# The agent's user: unprivileged, but with **passwordless sudo** — the plan's
# "its own little Debian box it can apt-install into" (§6). Isolation here is
# about a disposable environment, not about defending the host from the agent.
RUN set -eux; \
    groupadd -g "${AGENTS_GID}" "${AGENTS_USER}"; \
    useradd -m -u "${AGENTS_UID}" -g "${AGENTS_GID}" -s /bin/bash "${AGENTS_USER}"; \
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${AGENTS_USER}" > /etc/sudoers.d/"${AGENTS_USER}"; \
    chmod 0440 /etc/sudoers.d/"${AGENTS_USER}"; \
    visudo -c; \
    install -d -o "${AGENTS_UID}" -g "${AGENTS_GID}" -m 0755 /workspace; \
    printf 'cd /workspace 2>/dev/null || true\n' >> /home/"${AGENTS_USER}"/.bashrc

# yt-dlp, installed system-wide with uv so it lands on PATH (UV_TOOL_BIN_DIR)
# and any agent can pull a video's captions immediately. The youtube-transcript
# skill also self-installs it, so this is only the fast path, not a hard
# dependency. ffmpeg (above) backs yt-dlp's subtitle conversion and any audio
# fallback.
RUN set -eux; \
    uv tool install yt-dlp; \
    yt-dlp --version

COPY entrypoint.sh /usr/local/bin/agents-entrypoint
RUN chmod 0755 /usr/local/bin/agents-entrypoint

ENV AGENTS_USER=${AGENTS_USER} \
    AGENTS_WORKSPACE=/workspace

WORKDIR /workspace

# The entrypoint runs as root only to align the agent user with the host owner of
# the bind mount, then hands control to the command. Commands arrive later as
# `docker exec -u agents`, so nothing the agent runs is root by default.
ENTRYPOINT ["/usr/local/bin/agents-entrypoint"]
CMD ["sleep", "infinity"]
