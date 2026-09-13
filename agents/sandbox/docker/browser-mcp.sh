#!/bin/sh
# agents-browser-mcp — launch the Playwright MCP server INSIDE the sandbox
# container, headed, on a virtual display the user can watch over VNC (§9.1).
#
# The agent runtime runs on the host and speaks to this over stdio via
# `docker exec -i <container> agents-browser-mcp`. Because it runs in the
# container, the Chromium it launches renders to the container's Xvfb :99 — the
# same display x11vnc serves — so "the browser the agent drives" and "the browser
# the user watches" are one and the same process.
#
# Idempotent Xvfb bringup first, then a profile-owning supervisor relays inherited
# stdio directly to MCP and reaps its browser descendants on exit. Xvfb remains
# available across launches inside the disposable container.

set -eu

DISPLAY_NUM="${AGENTS_BROWSER_DISPLAY:-:99}"
SCREEN="${AGENTS_BROWSER_SCREEN:-1280x800x24}"
PROFILE="${AGENTS_BROWSER_PROFILE:-/workspace/.agents/chrome-profile}"
VIEWPORT="${AGENTS_BROWSER_VIEWPORT:-1280x800}"

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
    echo "agents-browser-mcp: Xvfb did not start on ${DISPLAY_NUM}" >&2
    cat /tmp/xvfb.log >&2 2>/dev/null || true
    exit 1
fi

export DISPLAY="${DISPLAY_NUM}"

# Make the agent's mouse visible to the person watching it (bead cowork-c0zd).
# x11vnc sends the REAL remote pointer — as a cursor pseudo-encoding to a client
# that asks for one, composited into the framebuffer for a client that does not
# — so what the user sees is whatever shape Chromium sets. With no cursor theme
# installed that is the X core cursor font at a fixed 10x16 pixels, which on a
# 1280x800 screen scaled onto a phone is a few specks. libXcursor honours these
# two variables and picks the nearest size the theme ships, so 64 lands on DMZ's
# 48x48 bitmaps: measured 10x16 -> 48x48, about five times the height. The theme
# comes from Dockerfile.browser; if it is ever missing, libXcursor simply falls
# back to the old core font and nothing breaks.
export XCURSOR_THEME="${AGENTS_BROWSER_CURSOR_THEME:-DMZ-White}"
export XCURSOR_SIZE="${AGENTS_BROWSER_CURSOR_SIZE:-64}"

mkdir -p "${PROFILE}"

# Headed by default (no --headless), so it renders to Xvfb; the single installed
# Chromium via --executable-path (no second download); --no-sandbox because the
# container is the isolation boundary (IN_DOCKER, no CAP_SYS_ADMIN); a persistent
# --user-data-dir in the workspace so a login done via the VNC hand-off survives.
# The image already installs the pinned server. Do not invoke npx here: a
# browser reconnect must not depend on npm registry availability/cache state.
exec python3 /usr/local/lib/agents/browser-mcp-owner.py playwright-mcp \
    --executable-path "${AGENTS_BROWSER_EXECUTABLE:-/usr/local/bin/chromium}" \
    --user-data-dir "${PROFILE}" \
    --no-sandbox \
    --viewport-size "${VIEWPORT}" \
    "$@"
