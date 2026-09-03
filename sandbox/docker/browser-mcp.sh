#!/bin/sh
# cowork-browser-mcp — launch the Playwright MCP server INSIDE the sandbox
# container, headed, on a virtual display the user can watch over VNC (§9.1).
#
# The agent runtime runs on the host and speaks to this over stdio via
# `docker exec -i <container> cowork-browser-mcp`. Because it runs in the
# container, the Chromium it launches renders to the container's Xvfb :99 — the
# same display x11vnc serves — so "the browser the agent drives" and "the browser
# the user watches" are one and the same process.
#
# Idempotent Xvfb bringup first, then exec the server so it becomes the process
# whose stdio the host is wired to. Xvfb, once started, is left running for reuse
# across launches; it is cheap and orphan-safe inside a disposable container.

set -eu

DISPLAY_NUM="${COWORK_BROWSER_DISPLAY:-:99}"
SCREEN="${COWORK_BROWSER_SCREEN:-1280x800x24}"
PROFILE="${COWORK_BROWSER_PROFILE:-/workspace/.cowork/chrome-profile}"
VIEWPORT="${COWORK_BROWSER_VIEWPORT:-1280x800}"

# Bring up Xvfb on the display if nothing answers there yet.
if ! xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1; then
    Xvfb "${DISPLAY_NUM}" -screen 0 "${SCREEN}" -nolisten tcp >/tmp/xvfb.log 2>&1 &
    # Wait for it to accept connections (up to ~5s) so Chromium never races it.
    i=0
    while [ "${i}" -lt 50 ]; do
        if xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1; then
            break
        fi
        i=$((i + 1))
        sleep 0.1
    done
fi

# Fail loudly if the display never came up, instead of launching the MCP server
# against a dead display and surfacing a confusing browser error later.
if ! xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1; then
    echo "cowork-browser-mcp: Xvfb did not start on ${DISPLAY_NUM}" >&2
    cat /tmp/xvfb.log >&2 2>/dev/null || true
    exit 1
fi

export DISPLAY="${DISPLAY_NUM}"
mkdir -p "${PROFILE}"

# Headed by default (no --headless), so it renders to Xvfb; the single installed
# Chromium via --executable-path (no second download); --no-sandbox because the
# container is the isolation boundary (IN_DOCKER, no CAP_SYS_ADMIN); a persistent
# --user-data-dir in the workspace so a login done via the VNC hand-off survives.
exec npx --yes "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION:-0.0.80}" \
    --executable-path "${COWORK_BROWSER_EXECUTABLE:-/usr/local/bin/chromium}" \
    --user-data-dir "${PROFILE}" \
    --no-sandbox \
    --viewport-size "${VIEWPORT}" \
    "$@"
