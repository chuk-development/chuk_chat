# CoWork agent base image (§6, §9).
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
# Deliberately NOT here: the browser stack (Chromium + its system libraries,
# several hundred MB). It lands in a separate image built on top of this one —
# `Dockerfile.browser`, tagged `cowork-browser:latest` — so an agent that never
# browses does not pay for it, and so this image stays quick to build. §8 makes
# that the normal case: API tools first, the browser only as the fallback.

ARG DEBIAN_BASE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
FROM ${DEBIAN_BASE}

# uv release to install, and the Python it provisions. Python comes from uv (a
# standalone build) rather than apt, so the version is exactly what the plan
# pins and does not drift with the Debian release.
ARG UV_VERSION=0.9.28
ARG PYTHON_VERSION=3.12
ARG COWORK_USER=cowork
ARG COWORK_UID=1000
ARG COWORK_GID=1000

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

# The agent's user: unprivileged, but with **passwordless sudo** — the plan's
# "its own little Debian box it can apt-install into" (§6). Isolation here is
# about a disposable environment, not about defending the host from the agent.
RUN set -eux; \
    groupadd -g "${COWORK_GID}" "${COWORK_USER}"; \
    useradd -m -u "${COWORK_UID}" -g "${COWORK_GID}" -s /bin/bash "${COWORK_USER}"; \
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${COWORK_USER}" > /etc/sudoers.d/"${COWORK_USER}"; \
    chmod 0440 /etc/sudoers.d/"${COWORK_USER}"; \
    visudo -c; \
    install -d -o "${COWORK_UID}" -g "${COWORK_GID}" -m 0755 /workspace; \
    printf 'cd /workspace 2>/dev/null || true\n' >> /home/"${COWORK_USER}"/.bashrc

COPY entrypoint.sh /usr/local/bin/cowork-entrypoint
RUN chmod 0755 /usr/local/bin/cowork-entrypoint

ENV COWORK_USER=${COWORK_USER} \
    COWORK_WORKSPACE=/workspace

WORKDIR /workspace

# The entrypoint runs as root only to align the agent user with the host owner of
# the bind mount, then hands control to the command. Commands arrive later as
# `docker exec -u cowork`, so nothing the agent runs is root by default.
ENTRYPOINT ["/usr/local/bin/cowork-entrypoint"]
CMD ["sleep", "infinity"]
