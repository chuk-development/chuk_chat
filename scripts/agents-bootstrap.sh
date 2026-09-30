#!/usr/bin/env bash
# Chuk Agents bootstrap: install the Agents host and pair it with one command.
#
# The Chuk app shows this command. It holds a one-time install token:
#
#     curl -fsSL https://api.chuk.chat/agents/install.sh | bash -s -- --token=<token>
#
# This script:
#   1. checks that the computer runs Linux and has curl and tar (or git);
#   2. installs uv into ~/.local/bin if it is missing (no root);
#   3. gets the host source (agents/ and scripts/ only) into
#      $AGENTS_HOME/src, or updates it there;
#   4. runs src/scripts/install.sh (the real installer);
#   5. becomes  agents-host connect  (exec) with the token in
#      $AGENTS_INSTALL_TOKEN. That pairs this computer with the account of
#      the app that made the token.
#
# The token is a secret. This script never prints it and never uses set -x.
# A command line is readable by every local user (/proc/<pid>/cmdline), so
# the token leaves the command line at once: the script starts itself again
# with the token in the environment (only this user can read that), and at
# the end it replaces itself with  agents-host connect  (exec), which also
# gets the token from the environment.
#
# All code is in functions. The last line calls main. If the download stops
# half way, bash gets no call to main and runs nothing.

set -euo pipefail

# All state is set in this function, not at the top level: when the script
# starts itself again (see reexec_without_token) only functions are carried.
defaults() {
    REPO_SLUG="chuk-development/chuk_chat"
    REPO_URL="https://github.com/${REPO_SLUG}.git"
    TARBALL_BASE="https://codeload.github.com/${REPO_SLUG}/tar.gz"
    UV_INSTALLER_URL="https://astral.sh/uv/install.sh"

    # The parts of the repository that the installer and the host need.
    # tools/agents-extension-mcp is optional (the browser add-on bridge).
    SOURCE_PATHS=(agents scripts tools/agents-extension-mcp)

    TOKEN=""
    REF="master"
    SOURCE_DIR=""
    DO_CONNECT=1
    NO_SERVICE=0
    NO_START_GIVEN=0
    DRY_RUN=0
    NO_ENV=0
    STATE_DIR_GIVEN=""
    BIN_DIR=""
    PASSTHROUGH=()
    STAGE_DIR=""
    ARGS_KEPT=()
    TOKEN_IN_ARGV=0
}

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: agents-bootstrap.sh --token=TOKEN [options] [install.sh options]

  --token TOKEN   the install token from the Chuk app (needed, unless
                  --no-connect is given). $AGENTS_INSTALL_TOKEN works too
  --ref REF       the git branch or tag to install (default master)
  --source DIR    copy the source from this checkout, do not download it
  --no-connect    install only, do not pair
  -h, --help      this text

All other options go to scripts/install.sh, for example --no-runtime,
--no-service, --dry-run, --bin-dir DIR, --prefix DIR.
EOF
}

cleanup() {
    if [ -n "${STAGE_DIR}" ] && [ -d "${STAGE_DIR}" ]; then
        rm -rf -- "${STAGE_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --token) [ $# -ge 2 ] || die "--token needs a value"; TOKEN="$2"; TOKEN_IN_ARGV=1; shift 2; continue ;;
            --token=*) TOKEN="${1#*=}"; TOKEN_IN_ARGV=1; shift; continue ;;
        esac
        ARGS_KEPT+=("$1")
        case "$1" in
            --ref) [ $# -ge 2 ] || die "--ref needs a value"; REF="$2"; ARGS_KEPT+=("$2"); shift 2 ;;
            --ref=*) REF="${1#*=}"; shift ;;
            --source) [ $# -ge 2 ] || die "--source needs a directory"; SOURCE_DIR="$2"; ARGS_KEPT+=("$2"); shift 2 ;;
            --source=*) SOURCE_DIR="${1#*=}"; shift ;;
            --no-connect) DO_CONNECT=0; shift ;;
            -h|--help) usage; exit 0 ;;
            # The options below go to install.sh, but this script must know
            # them too: where the launcher is, and which state directory to pair.
            --no-service) NO_SERVICE=1; PASSTHROUGH+=("$1"); shift ;;
            --no-start) NO_START_GIVEN=1; PASSTHROUGH+=("$1"); shift ;;
            --dry-run) DRY_RUN=1; PASSTHROUGH+=("$1"); shift ;;
            --no-env) NO_ENV=1; PASSTHROUGH+=("$1"); shift ;;
            --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a directory"; BIN_DIR="$2"; PASSTHROUGH+=("$1" "$2"); ARGS_KEPT+=("$2"); shift 2 ;;
            --bin-dir=*) BIN_DIR="${1#*=}"; PASSTHROUGH+=("$1"); shift ;;
            --prefix|--state-dir) [ $# -ge 2 ] || die "$1 needs a directory"; STATE_DIR_GIVEN="$2"; PASSTHROUGH+=("$1" "$2"); ARGS_KEPT+=("$2"); shift 2 ;;
            --prefix=*|--state-dir=*) STATE_DIR_GIVEN="${1#*=}"; PASSTHROUGH+=("$1"); shift ;;
            # install.sh options that take a value.
            --tag|--image|--runtime|--sandbox)
                [ $# -ge 2 ] || die "$1 needs a value"; PASSTHROUGH+=("$1" "$2"); ARGS_KEPT+=("$2"); shift 2 ;;
            *) PASSTHROUGH+=("$1"); shift ;;
        esac
    done

    # The token can also come from the environment: the restarted script
    # gets it that way. Take it, then remove it, so no child process (the
    # installer, uv, docker) inherits it.
    if [ -z "${TOKEN}" ]; then
        TOKEN="${AGENTS_INSTALL_TOKEN:-}"
    fi
    unset AGENTS_INSTALL_TOKEN

    if [ "${DO_CONNECT}" -eq 1 ] && [ -z "${TOKEN}" ]; then
        die "no install token. Copy the full command from the Chuk app, or use --no-connect"
    fi
    # Only a simple branch or tag name. The ref goes into a URL and a git call.
    case "${REF}" in
        ''|-*|*..*) die "--ref must be a branch or tag name" ;;
    esac
    if ! [[ "${REF}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        die "--ref must be a branch or tag name"
    fi
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
check_platform() {
    local os
    os="$(uname -s 2>/dev/null || echo unknown)"
    if [ "${os}" != "Linux" ]; then
        die "the Agents host runs on Linux only. This computer runs ${os}."
    fi
    [ -n "${HOME:-}" ] || die "HOME is not set"
}

check_tools() {
    if [ -n "${SOURCE_DIR}" ]; then
        command -v tar >/dev/null 2>&1 || die "tar is needed. Install it and run the command again."
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "curl is needed. Install it and run the command again."
    if ! command -v git >/dev/null 2>&1 && ! command -v tar >/dev/null 2>&1; then
        die "git or tar is needed. Install one and run the command again."
    fi
}

state_dir() {
    if [ -n "${STATE_DIR_GIVEN}" ]; then
        printf '%s' "${STATE_DIR_GIVEN}"
        return 0
    fi
    local data="${XDG_DATA_HOME:-}"
    case "${data}" in
        /*) ;;
        *) data="${HOME}/.local/share" ;;
    esac
    printf '%s' "${AGENTS_HOME:-${COWORK_HOME:-${data}/chuk-agents}}"
}

ensure_uv() {
    export PATH="${HOME}/.local/bin:${PATH}"
    # install.sh needs uv only for the Python environment.
    if [ "${NO_ENV}" -eq 1 ] || command -v uv >/dev/null 2>&1; then
        return 0
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
        say "would install uv into ${HOME}/.local/bin"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "uv is missing and curl is needed to install it"
    say "Installing uv (the Python tool) into ${HOME}/.local/bin."
    curl -fsSL "${UV_INSTALLER_URL}" </dev/null | sh -s -- --quiet \
        || die "could not install uv. See https://docs.astral.sh/uv/"
    command -v uv >/dev/null 2>&1 || die "uv is still not on PATH after the install"
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------

# Move the old Python environment into the new tree, so an update does not
# build it again. Its paths do not change: the new tree takes the old place.
keep_venv() {
    local old="$1" new="$2"
    if [ -d "${old}/agents/host/.venv" ] && [ -d "${new}/agents/host" ] \
        && [ ! -e "${new}/agents/host/.venv" ]; then
        mv -- "${old}/agents/host/.venv" "${new}/agents/host/.venv"
    fi
}

# Put the staged tree in place of the old one.
swap_in() {
    local src="$1" new="$2"
    case "${src}" in
        */src) ;;
        *) die "refusing to replace ${src}: it is not a src directory" ;;
    esac
    if [ -e "${src}" ]; then
        keep_venv "${src}" "${new}"
        rm -rf -- "${src}"
    fi
    mv -- "${new}" "${src}"
}

copy_from_source() {
    local src="$1" new="$2" dir
    local paths=()
    [ -f "${SOURCE_DIR}/scripts/install.sh" ] || die "${SOURCE_DIR} has no scripts/install.sh"
    [ -f "${SOURCE_DIR}/agents/host/pyproject.toml" ] || die "${SOURCE_DIR} has no agents/host"
    for dir in "${SOURCE_PATHS[@]}"; do
        if [ -e "${SOURCE_DIR}/${dir}" ]; then
            paths+=("${dir}")
        fi
    done
    say "Copying the host source from ${SOURCE_DIR}."
    mkdir -p -- "${new}"
    tar -C "${SOURCE_DIR}" \
        --exclude=.venv --exclude=__pycache__ --exclude=.pytest_cache \
        --exclude='*.pyc' --exclude=node_modules \
        -cf - "${paths[@]}" </dev/null | tar -C "${new}" -xf -
    swap_in "${src}" "${new}"
}

git_update() {
    local src="$1"
    [ -d "${src}/.git" ] || return 1
    [ "$(git -C "${src}" config --get remote.origin.url 2>/dev/null || true)" = "${REPO_URL}" ] || return 1
    say "Updating the host source to ${REF}."
    git -C "${src}" sparse-checkout set "${SOURCE_PATHS[@]}" </dev/null >/dev/null 2>&1 || return 1
    git -C "${src}" fetch --quiet --depth 1 --filter=blob:none origin "${REF}" </dev/null || return 1
    git -C "${src}" checkout --quiet --force --detach FETCH_HEAD </dev/null || return 1
}

git_clone() {
    local src="$1" new="$2"
    say "Downloading the host source (${REF})."
    git clone --quiet --depth 1 --filter=blob:none --sparse --branch "${REF}" \
        "${REPO_URL}" "${new}" </dev/null || return 1
    git -C "${new}" sparse-checkout set "${SOURCE_PATHS[@]}" </dev/null || return 1
    swap_in "${src}" "${new}"
}

tarball_fetch() {
    local src="$1" new="$2" archive top dir
    local members=()
    command -v tar >/dev/null 2>&1 || die "tar is needed to download the source"
    say "Downloading the host source (${REF}) as an archive."
    archive="${STAGE_DIR}/source.tar.gz"
    curl -fsSL "${TARBALL_BASE}/${REF}" -o "${archive}" </dev/null \
        || die "could not download ${TARBALL_BASE}/${REF}"
    # The archive has one top directory (repo name and ref). Read its name.
    top="$(tar -tzf "${archive}" 2>/dev/null | head -n 1 || true)"
    top="${top%%/*}"
    [ -n "${top}" ] || die "the downloaded archive is empty"
    for dir in "${SOURCE_PATHS[@]}"; do
        if tar -tzf "${archive}" "${top}/${dir}" >/dev/null 2>&1; then
            members+=("${top}/${dir}")
        fi
    done
    [ "${#members[@]}" -gt 0 ] || die "the archive holds no agents/ directory"
    rm -rf -- "${new}"
    mkdir -p -- "${new}"
    tar -xzf "${archive}" -C "${new}" --strip-components=1 "${members[@]}"
    rm -f -- "${archive}"
    swap_in "${src}" "${new}"
}

fetch_source() {
    local src="$1" new
    # The state directory holds keys later. Owner only from the start.
    (umask 077 && mkdir -p -- "$(dirname -- "${src}")")
    STAGE_DIR="$(mktemp -d "$(dirname -- "${src}")/.src-stage.XXXXXX")"
    new="${STAGE_DIR}/tree"
    if [ -n "${SOURCE_DIR}" ]; then
        copy_from_source "${src}" "${new}"
        return 0
    fi
    if command -v git >/dev/null 2>&1; then
        export GIT_TERMINAL_PROMPT=0
        if git_update "${src}"; then
            return 0
        fi
        rm -rf -- "${new}"
        if git_clone "${src}" "${new}"; then
            return 0
        fi
        warn "git could not get the source; trying the archive download"
        rm -rf -- "${new}"
    fi
    tarball_fetch "${src}" "${new}"
}

# ---------------------------------------------------------------------------
# Install and pair
# ---------------------------------------------------------------------------
run_installer() {
    local src="$1"
    local args=("${PASSTHROUGH[@]}")
    # Pairing restarts the service. So the installer only enables it, and the
    # service does not start once unpaired just to be stopped again.
    if [ "${DO_CONNECT}" -eq 1 ] && [ "${NO_START_GIVEN}" -eq 0 ] && [ "${NO_SERVICE}" -eq 0 ]; then
        args+=(--no-start)
    fi
    say "Running the installer."
    bash "${src}/scripts/install.sh" "${args[@]}" </dev/null
}

# Start this script again without the token on its command line. Every local
# user can read a command line, and this process lives for the whole install.
# The new process gets the token in its environment, which only this user can
# read. It carries the functions only; defaults() sets the state again.
reexec_without_token() {
    if [ "${TOKEN_IN_ARGV}" -eq 0 ] || [ -n "${AGENTS_BOOTSTRAP_REEXEC:-}" ]; then
        unset AGENTS_BOOTSTRAP_REEXEC
        return 0
    fi
    export AGENTS_INSTALL_TOKEN="${TOKEN}"
    export AGENTS_BOOTSTRAP_REEXEC=1
    local body
    body="set -euo pipefail
$(declare -f)
main \"\$@\""
    exec "${BASH:-bash}" -c "${body}" agents-bootstrap "${ARGS_KEPT[@]}"
}

connect_host() {
    local launcher="${BIN_DIR:-${HOME}/.local/bin}/agents-host"
    local args=(connect)
    if [ "${NO_SERVICE}" -eq 1 ]; then
        args+=(--no-service)
    fi
    if [ -n "${STATE_DIR_GIVEN}" ]; then
        args+=(--workspace "${STATE_DIR_GIVEN}")
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
        say "would run: AGENTS_INSTALL_TOKEN=<hidden> ${launcher} ${args[*]}"
        return 0
    fi
    [ -x "${launcher}" ] || die "the launcher ${launcher} is missing. The install did not finish."
    say ""
    say "Pairing this computer with your Chuk account."
    # The last step: this process becomes  agents-host connect. The token goes
    # in the environment, never on the command line. connect reads it and
    # removes it. Nothing runs after this line.
    export AGENTS_INSTALL_TOKEN="${TOKEN}"
    exec "${launcher}" "${args[@]}" </dev/null
}

main() {
    defaults
    parse_args "$@"
    reexec_without_token
    trap cleanup EXIT
    check_platform
    check_tools
    local src
    src="$(state_dir)/src"
    ensure_uv
    if [ "${DRY_RUN}" -eq 1 ]; then
        # A dry run changes nothing. It reads a source tree that is already
        # there, and it downloads nothing.
        if [ -n "${SOURCE_DIR}" ]; then
            src="${SOURCE_DIR}"
        elif [ ! -f "${src}/scripts/install.sh" ]; then
            say "would download the host source (${REF}) into ${src}"
            say "would run: ${src}/scripts/install.sh ${PASSTHROUGH[*]}"
            if [ "${DO_CONNECT}" -eq 1 ]; then
                connect_host
            fi
            return 0
        fi
    else
        fetch_source "${src}"
        cleanup
        STAGE_DIR=""
    fi
    run_installer "${src}"
    if [ "${DO_CONNECT}" -eq 1 ]; then
        connect_host
    elif [ "${DRY_RUN}" -eq 1 ]; then
        say ""
        say "Dry run: nothing was changed. Pairing is skipped (--no-connect)."
    else
        say ""
        say "Installed. Pairing is skipped (--no-connect)."
    fi
}

main "$@"
