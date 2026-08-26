#!/bin/sh
# CoWork base image entrypoint.
#
# Its one job: make the container's agent user own the same uid/gid as the host
# user who owns the bind-mounted workspace. Without this, every file the agent
# writes into /workspace shows up on the host owned by uid 1000 (or refuses to
# be written at all), which breaks the host-side ffmpeg passthrough and the
# git-versioned workspace (§7.7, §9).
#
# The remap is driven by COWORK_UID / COWORK_GID, which the sandbox passes on
# `docker run`. With neither set, nothing changes.
#
# Runs as root, then execs the command (normally `sleep infinity`). Agent
# commands arrive afterwards as `docker exec -u cowork`, never as root.

set -eu

user="${COWORK_USER:-cowork}"

remap_user() {
    want_uid="$1"
    want_gid="$2"

    have_uid="$(id -u "$user" 2>/dev/null || echo '')"
    have_gid="$(id -g "$user" 2>/dev/null || echo '')"
    [ -n "$have_uid" ] || return 0
    if [ "$have_uid" = "$want_uid" ] && [ "$have_gid" = "$want_gid" ]; then
        return 0
    fi

    # -o allows a non-unique id: the host uid may already belong to another
    # account in the image, and matching the host is what matters here.
    if [ "$have_gid" != "$want_gid" ]; then
        groupmod -o -g "$want_gid" "$user" 2>/dev/null || true
    fi
    if [ "$have_uid" != "$want_uid" ]; then
        usermod -o -u "$want_uid" -g "$want_gid" "$user" 2>/dev/null || true
    fi

    home="$(getent passwd "$user" | cut -d: -f6)"
    if [ -n "$home" ] && [ -d "$home" ]; then
        # Everything in the home directory, but never into the mounted workspace:
        # its files are already owned by this uid on the host, and a recursive
        # chown of a large workspace would be slow for no gain.
        find "$home" -mindepth 1 -maxdepth 1 ! -name workspace \
            -exec chown -R "$want_uid:$want_gid" {} + 2>/dev/null || true
        chown "$want_uid:$want_gid" "$home" 2>/dev/null || true
    fi
}

if [ "$(id -u)" = "0" ] && [ -n "${COWORK_UID:-}" ] && [ -n "${COWORK_GID:-}" ]; then
    remap_user "$COWORK_UID" "$COWORK_GID"
fi

# The workspace mount point itself must be enterable and writable by the agent.
# When a fresh host directory is mounted it already belongs to the host user, so
# this only fixes the empty-image case.
if [ "$(id -u)" = "0" ] && [ -d "${COWORK_WORKSPACE:-/workspace}" ]; then
    ws="${COWORK_WORKSPACE:-/workspace}"
    if [ -z "$(ls -A "$ws" 2>/dev/null)" ]; then
        chown "$(id -u "$user" 2>/dev/null || echo 0):$(id -g "$user" 2>/dev/null || echo 0)" "$ws" 2>/dev/null || true
    fi
fi

exec "$@"
