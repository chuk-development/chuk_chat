#!/usr/bin/env bash
# Agents host installer (§5: "install = one shell script + connect").
#
# What it does, in this order:
#   1. preflight  — check everything it will need, and report ALL problems at
#                   once. Nothing is changed until every check passes, so a
#                   missing prerequisite can never leave a half-install behind.
#   2. image      — build the agent base image (agents/sandbox/docker/Dockerfile).
#   3. dirs       — create the state directory (0700). The host fills it.
#   4. env        — sync the Python environment with uv and install the
#                   launchers ``agents-host`` and ``cowork-host`` (an alias).
#   5. service    — write the systemd **user** unit, enable and start it.
#                   ``Restart=always`` + ``WantedBy=default.target``: it starts
#                   with the user manager. Add ``--enable-linger`` (or run
#                   ``loginctl enable-linger``) so that happens at boot, not only
#                   at the first login.
#
# The state directory is ``$XDG_DATA_HOME/chuk-agents`` (``~/.local/share/
# chuk-agents``). Not ``~/.agents``: other tools (the ``skills`` CLI) own that
# one. A legacy ``~/.cowork``, or host files at the top of ``~/.agents``, are
# moved there by the host on its first start, so the pairing survives.
#
# No secret is written into the unit. The host takes the Supabase URL and anon
# key from the account token the app provisions; optional overrides go into
# ``~/.config/chuk-agents/host.env``, which the unit reads if it exists.
#
# It is idempotent: every step checks the current state first, and running the
# script twice changes nothing the second time. Use --dry-run to see the plan.
#
# It deliberately does NOT install a container runtime by itself. Doing that
# needs root and rewrites the user's system; the script tells you the one
# command to run instead. Pass --install-runtime to opt in.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
UNIT_TEMPLATE="${SCRIPT_DIR}/agents-manager.service"
UNIT_NAME="agents-manager.service"

# ---------------------------------------------------------------------------
# Defaults (override with flags or the environment)
# ---------------------------------------------------------------------------
DEFAULT_STATE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/chuk-agents"
case "${XDG_DATA_HOME:-}" in /*|'') ;; *) DEFAULT_STATE_DIR="${HOME}/.local/share/chuk-agents" ;; esac
AGENTS_HOME="${AGENTS_HOME:-${COWORK_HOME:-${DEFAULT_STATE_DIR}}}"
BIN_DIR="${HOME}/.local/bin"
IMAGE_TAG="${AGENTS_SANDBOX_IMAGE:-agents-base:latest}"
PULL_IMAGE=""
RUNTIME="${AGENTS_RUNTIME:-}"
SANDBOX_KIND="${AGENTS_SANDBOX_KIND:-docker}"
DRY_RUN=0
DO_RUNTIME=1
DO_IMAGE=1
DO_ENV=1
DO_SERVICE=1
DO_START=1
INSTALL_RUNTIME=0
FORCE_REBUILD=0
ENABLE_LINGER=0

usage() {
    cat <<'EOF'
Usage: install.sh [options]

  --prefix DIR        the host state directory (default $AGENTS_HOME, else
                      ~/.local/share/chuk-agents); --state-dir is the same
  --bin-dir DIR       where the agents-host / cowork-host launchers go
                      (default ~/.local/bin)
  --tag REF           image tag to build (default agents-base:latest)
  --image REF         pull this prebuilt image and tag it, instead of building
  --runtime BIN       container runtime to use (default: docker, else podman)
  --sandbox KIND      sandbox backend the service uses (docker|local, default docker)
  --install-runtime   install the container runtime if missing (needs sudo)
  --force-rebuild     rebuild the base image even if it already exists
  --no-runtime        skip the container-runtime check (implies --no-image)
  --no-image          skip building/pulling the base image
  --no-env            skip creating the Python environment
  --no-service        do not touch systemd (the unit file is still written)
  --no-start          install and enable the service but do not start it
  --enable-linger     run 'loginctl enable-linger' so the service starts at
                      boot, before anybody logs in
  --dry-run           print every action, change nothing
  -h, --help          this text

After a successful install, pair the phone once:

    agents-host connect

(cowork-host is the same command under its old name.) From then on the
systemd user service runs the host automatically, and restarts it when it
stops. To start it at boot without a login, once:

    loginctl enable-linger "$USER"
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix|--state-dir) AGENTS_HOME="${2:?$1 needs a directory}"; shift 2 ;;
        --prefix=*|--state-dir=*) AGENTS_HOME="${1#*=}"; shift ;;
        --bin-dir) BIN_DIR="${2:?--bin-dir needs a directory}"; shift 2 ;;
        --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
        --enable-linger) ENABLE_LINGER=1; shift ;;
        --tag) IMAGE_TAG="${2:?--tag needs a reference}"; shift 2 ;;
        --tag=*) IMAGE_TAG="${1#*=}"; shift ;;
        --image) PULL_IMAGE="${2:?--image needs a reference}"; shift 2 ;;
        --image=*) PULL_IMAGE="${1#*=}"; shift ;;
        --runtime) RUNTIME="${2:?--runtime needs a binary}"; shift 2 ;;
        --runtime=*) RUNTIME="${1#*=}"; shift ;;
        --sandbox) SANDBOX_KIND="${2:?--sandbox needs a kind}"; shift 2 ;;
        --sandbox=*) SANDBOX_KIND="${1#*=}"; shift ;;
        --install-runtime) INSTALL_RUNTIME=1; shift ;;
        --force-rebuild) FORCE_REBUILD=1; shift ;;
        --no-runtime) DO_RUNTIME=0; DO_IMAGE=0; shift ;;
        --no-image) DO_IMAGE=0; shift ;;
        --no-env) DO_ENV=0; shift ;;
        --no-service) DO_SERVICE=0; shift ;;
        --no-start) DO_START=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'install.sh: unknown option %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "${SANDBOX_KIND}" in
    docker|local) ;;
    *) printf 'install.sh: --sandbox must be docker or local, got %s\n' "${SANDBOX_KIND}" >&2; exit 2 ;;
esac

LAUNCHER="${BIN_DIR}/agents-host"
ALIAS_LAUNCHER="${BIN_DIR}/cowork-host"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
UNIT_PATH="${UNIT_DIR}/${UNIT_NAME}"
HOST_PROJECT="${REPO_ROOT}/agents/host"
VENV_BIN="${HOST_PROJECT}/.venv/bin/agents-host"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
say()  { printf '  %s\n' "$*"; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '  would run: %s\n' "$*"
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# 1. Preflight — collect every problem, then decide
# ---------------------------------------------------------------------------
PROBLEMS=()
problem() { PROBLEMS+=("$1"); }

detect_runtime() {
    if [ -n "${RUNTIME}" ]; then
        command -v "${RUNTIME}" >/dev/null 2>&1 && { printf '%s' "${RUNTIME}"; return 0; }
        return 1
    fi
    for candidate in docker podman; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

runtime_install_hint() {
    if command -v apt-get >/dev/null 2>&1; then
        printf 'curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker %s' "${USER:-$(id -un)}"
    elif command -v dnf >/dev/null 2>&1; then
        printf 'sudo dnf install -y docker && sudo systemctl enable --now docker'
    elif command -v pacman >/dev/null 2>&1; then
        printf 'sudo pacman -S --needed docker && sudo systemctl enable --now docker'
    else
        printf 'install Docker or Podman with your package manager'
    fi
}

install_runtime() {
    command -v curl >/dev/null 2>&1 || die "curl is needed to install the container runtime"
    command -v sudo >/dev/null 2>&1 || die "sudo is needed to install the container runtime"
    say "installing Docker via get.docker.com (needs sudo)"
    run bash -c 'curl -fsSL https://get.docker.com | sudo sh'
    run sudo usermod -aG docker "${USER:-$(id -un)}"
    warn "group membership applies to NEW logins: log out and back in, or run 'newgrp docker', then re-run install.sh"
}

step 1/5 "preflight"

RUNTIME_BIN=""
if [ "${DO_RUNTIME}" -eq 1 ]; then
    if RUNTIME_BIN="$(detect_runtime)"; then
        say "container runtime: ${RUNTIME_BIN} ($(command -v "${RUNTIME_BIN}"))"
    elif [ "${INSTALL_RUNTIME}" -eq 1 ]; then
        install_runtime
        RUNTIME_BIN="$(detect_runtime)" || problem "the container runtime is still missing after installing it"
    else
        problem "no container runtime found. Install one:
      $(runtime_install_hint)
    ...or re-run with --install-runtime, or with --no-runtime to skip this."
    fi
    if [ -n "${RUNTIME_BIN}" ] && ! "${RUNTIME_BIN}" info >/dev/null 2>&1; then
        problem "${RUNTIME_BIN} is installed but its daemon does not answer.
      Start it (sudo systemctl enable --now docker) and make sure '${USER:-$(id -un)}'
      is in the 'docker' group (sudo usermod -aG docker ${USER:-$(id -un)}, then re-login)."
    fi
else
    say "container runtime: check skipped (--no-runtime)"
fi

if [ "${DO_IMAGE}" -eq 1 ] && [ -z "${PULL_IMAGE}" ] && [ ! -f "${REPO_ROOT}/agents/sandbox/docker/Dockerfile" ]; then
    problem "agents/sandbox/docker/Dockerfile is missing — run install.sh from a full checkout"
fi

if [ "${DO_ENV}" -eq 1 ]; then
    if command -v uv >/dev/null 2>&1; then
        say "uv: $(uv --version 2>/dev/null || echo present)"
    else
        problem "uv is not installed. Install it:
      curl -fsSL https://astral.sh/uv/install.sh | sh
    ...or re-run with --no-env to skip the Python environment."
    fi
    [ -f "${HOST_PROJECT}/pyproject.toml" ] || problem "agents/host/pyproject.toml is missing — run install.sh from a full checkout"
fi

if [ "${DO_SERVICE}" -eq 1 ]; then
    [ -f "${UNIT_TEMPLATE}" ] || problem "unit template ${UNIT_TEMPLATE} is missing"
    if ! command -v systemctl >/dev/null 2>&1; then
        problem "systemctl not found: this host has no systemd.
      Re-run with --no-service and start 'agents-host run' yourself."
    elif ! systemctl --user show-environment >/dev/null 2>&1; then
        problem "the systemd **user** instance is not reachable (no session bus).
      Enable it (sudo loginctl enable-linger ${USER:-$(id -un)}) and log in again,
      or re-run with --no-service."
    fi
fi

# Writability: the parent must exist and accept new entries, or we would fail
# halfway through creating things.
check_writable_parent() {
    local target="$1" label="$2" parent
    parent="$(dirname -- "${target}")"
    while [ ! -e "${parent}" ] && [ "${parent}" != "/" ]; do
        parent="$(dirname -- "${parent}")"
    done
    [ -w "${parent}" ] || problem "${label}: ${parent} is not writable by $(id -un)"
}
check_writable_parent "${AGENTS_HOME}" "state directory"
check_writable_parent "${BIN_DIR}/x" "launcher directory"
if [ "${DO_SERVICE}" -eq 1 ]; then
    check_writable_parent "${UNIT_DIR}" "systemd user unit directory"
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    printf '\ninstall.sh stopped BEFORE changing anything. %s problem(s):\n\n' "${#PROBLEMS[@]}" >&2
    for p in "${PROBLEMS[@]}"; do printf '  * %s\n' "${p}" >&2; done
    printf '\n' >&2
    exit 1
fi
say "all checks passed"
if [ "${DRY_RUN}" -eq 1 ]; then
    say "DRY RUN: nothing below is actually executed"
fi

# ---------------------------------------------------------------------------
# 2. Base image
# ---------------------------------------------------------------------------
step 2/5 "agent base image"
if [ "${DO_IMAGE}" -eq 0 ]; then
    say "skipped (--no-image)"
elif [ -n "${PULL_IMAGE}" ]; then
    say "pulling ${PULL_IMAGE} and tagging it ${IMAGE_TAG}"
    run "${RUNTIME_BIN}" pull "${PULL_IMAGE}"
    run "${RUNTIME_BIN}" tag "${PULL_IMAGE}" "${IMAGE_TAG}"
elif [ "${FORCE_REBUILD}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ] \
     && "${RUNTIME_BIN}" image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    say "${IMAGE_TAG} already exists — keeping it (--force-rebuild to rebuild)"
else
    say "building ${IMAGE_TAG} from agents/sandbox/docker/Dockerfile"
    run "${RUNTIME_BIN}" build -t "${IMAGE_TAG}" "${REPO_ROOT}/agents/sandbox/docker"
fi

# ---------------------------------------------------------------------------
# 3. Directories
# ---------------------------------------------------------------------------
step 3/5 "directories"
# Only the state directory itself: the host creates what it needs inside, and
# moves a legacy state into it on its first start.
for dir in "${AGENTS_HOME}" "${BIN_DIR}"; do
    if [ -d "${dir}" ]; then
        say "exists: ${dir}"
    else
        say "create: ${dir}"
        run mkdir -p "${dir}"
    fi
done
# The state directory holds the channel key and the device seed; owner only.
if [ "${DRY_RUN}" -eq 1 ] || [ "$(stat -c '%a' -- "${AGENTS_HOME}" 2>/dev/null)" != "700" ]; then
    run chmod 700 "${AGENTS_HOME}"
fi

# ---------------------------------------------------------------------------
# 4. Python environment + launcher
# ---------------------------------------------------------------------------
step 4/5 "python environment"
if [ "${DO_ENV}" -eq 0 ]; then
    say "skipped (--no-env)"
else
    say "uv sync --project ${HOST_PROJECT}"
    run uv sync --project "${HOST_PROJECT}"
fi

# The launcher is what systemd and the user's shell call. It is a wrapper, not a
# copy, so an updated checkout is picked up without reinstalling.
write_file() {
    local path="$1" mode="$2" content="$3"
    if [ -f "${path}" ] && [ "$(cat -- "${path}" 2>/dev/null)" = "${content}" ]; then
        say "unchanged: ${path}"
        return 0
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '  would write: %s\n' "${path}"
        return 0
    fi
    mkdir -p -- "$(dirname -- "${path}")"
    printf '%s\n' "${content}" > "${path}"
    chmod "${mode}" "${path}"
    say "wrote: ${path}"
}

LAUNCHER_BODY="#!/usr/bin/env bash
# Generated by agents install.sh — edit the checkout, not this file.
set -euo pipefail
exec \"${VENV_BIN}\" \"\$@\""
write_file "${LAUNCHER}" 0755 "${LAUNCHER_BODY}"
ALIAS_BODY="#!/usr/bin/env bash
# Generated by agents install.sh — the pre-rename name of agents-host.
exec \"${LAUNCHER}\" \"\$@\""
write_file "${ALIAS_LAUNCHER}" 0755 "${ALIAS_BODY}"
say "launcher: ${LAUNCHER} (alias: ${ALIAS_LAUNCHER})"
case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) warn "${BIN_DIR} is not on PATH; call ${LAUNCHER} by its full path, or add it to PATH" ;;
esac

# ---------------------------------------------------------------------------
# 5. systemd user service
# ---------------------------------------------------------------------------
step 5/5 "systemd user service"
# The default state directory is not written into the unit: the host resolves
# it itself, and only then moves a legacy ~/.cowork or ~/.agents state into it
# (an explicit path is used as given and never migrated into).
if [ "${AGENTS_HOME}" = "${DEFAULT_STATE_DIR}" ]; then
    WORKSPACE_ARG=""
else
    WORKSPACE_ARG="--workspace ${AGENTS_HOME} "
fi
UNIT_BODY="$(sed \
    -e "s|@EXEC@|${LAUNCHER}|g" \
    -e "s|@WORKSPACE_ARG@|${WORKSPACE_ARG}|g" \
    -e "s|@IMAGE@|${IMAGE_TAG}|g" \
    -e "s|@SANDBOX_KIND@|${SANDBOX_KIND}|g" \
    -- "${UNIT_TEMPLATE}")"
write_file "${UNIT_PATH}" 0644 "${UNIT_BODY}"

if [ "${DO_SERVICE}" -eq 0 ]; then
    say "systemd not touched (--no-service); the unit file is in place"
else
    run systemctl --user daemon-reload
    if [ "${DRY_RUN}" -eq 0 ] && systemctl --user is-enabled --quiet "${UNIT_NAME}" 2>/dev/null; then
        say "already enabled: ${UNIT_NAME}"
    else
        run systemctl --user enable "${UNIT_NAME}"
    fi
    if [ "${DO_START}" -eq 0 ]; then
        say "not started (--no-start)"
    elif [ "${DRY_RUN}" -eq 0 ] && systemctl --user is-active --quiet "${UNIT_NAME}" 2>/dev/null; then
        say "already running — restarting to pick up this install"
        run systemctl --user restart "${UNIT_NAME}"
    else
        run systemctl --user start "${UNIT_NAME}"
    fi
    # Boot without a login: a user manager only starts at boot when lingering is
    # on. Without it the service starts at the first login and not before.
    LINGER="$(loginctl show-user "${USER:-$(id -un)}" -p Linger --value 2>/dev/null || true)"
    if [ "${LINGER}" = "yes" ]; then
        say "linger: on (the service starts at boot, no login needed)"
    elif [ "${ENABLE_LINGER}" -eq 1 ]; then
        run loginctl enable-linger "${USER:-$(id -un)}"
    else
        say "linger: off. The service starts at your first login, not at boot."
        say "  To start it at boot:  loginctl enable-linger ${USER:-$(id -un)}   (or re-run with --enable-linger)"
    fi
fi

# ---------------------------------------------------------------------------
printf '\nAgents is installed.\n\n'
printf '  state:    %s\n' "${AGENTS_HOME}"
printf '  launcher: %s\n' "${LAUNCHER}"
printf '  image:    %s\n' "${IMAGE_TAG}"
printf '  service:  %s\n\n' "${UNIT_PATH}"
# A reinstall on a paired machine must not tell the user to pair again: the
# pairing survives (it is migrated, never replaced). `status` only reads.
if [ "${DRY_RUN}" -eq 0 ] && "${LAUNCHER}" status 2>/dev/null | grep -Eq '^ *Paired: +yes'; then
  printf 'Already paired: the app reconnects by itself, no code needed.\n\n'
else
  printf 'Pair your phone once:\n\n    %s connect\n\n' "${LAUNCHER}"
fi
printf 'Then it runs by itself. Status:  systemctl --user status %s\n\n' "${UNIT_NAME}"
