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
# Empty by default: the page fills the window and the window fills the display
# (see "Window = display" below). Set it only to force a fixed page size; the
# window then grows to page + browser chrome and no longer matches the display.
VIEWPORT="${AGENTS_BROWSER_VIEWPORT:-}"

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

# Window = display (bead chuk_chat-elw7). The live view and every screenshot
# show the whole display, so the browser window must cover it exactly: at 0,0
# and as large as the screen. There is no window manager, so --start-maximized
# does nothing and Chromium picks its own bounds: measured at +10+10 and
# 1288x931 on a 1280x800 screen with the old fixed viewport (black strips at
# the top and left, page bottom cut off), about 1050 px wide without one, and
# 58% black on a 1440x2000 display. The fix needs no WM: --window-position
# and --window-size. The size is MEASURED from the display, not copied from
# AGENTS_BROWSER_SCREEN, because the display may already exist with another
# size (someone else started Xvfb on this number); the window then still
# covers it. AGENTS_BROWSER_SCREEN stays the one knob for the size.
#
# The page viewport follows the window ("viewport": null = no emulation). A
# fixed viewport cannot work here: Playwright then resizes a headed window to
# viewport + browser chrome (85 px tab/URL bar, +46 px for a persistent
# profile), which is taller than a screen of the same size, and the bottom of
# the page is cut off in the live view. --viewport-size on the command line
# wins over this file, so AGENTS_BROWSER_VIEWPORT still forces one if set.
geometry=$(xdpyinfo -display "${DISPLAY_NUM}" 2>/dev/null \
    | awk '/dimensions:/ { print $2; exit }')
case "${geometry}" in
    *[!0-9x]* | x* | *x | "")
        geometry=$(printf '%s\n' "${SCREEN}" | awk -Fx '{ print $1 "x" $2 }') ;;
esac
WIDTH="${geometry%%x*}"
HEIGHT="${geometry#*x}"
HEIGHT="${HEIGHT%%x*}"
case "${WIDTH}${HEIGHT}" in
    *[!0-9]* | "") WIDTH=1280; HEIGHT=800 ;;
esac

# One pixel MORE than the display, on purpose: Chromium on X11 shrinks a window
# that is exactly screen-sized by 1 px each way (so it is not taken for
# fullscreen), which left a black line at the right and bottom edge. Measured
# in a container: --window-size=1280,800 gives 1279x799, 1281,801 gives
# 1281x801, and the framebuffer then has no black column or row.
WINDOW_W=$((WIDTH + 1))
WINDOW_H=$((HEIGHT + 1))

# Playwright MCP has no CLI flag for extra Chromium arguments; its config file
# carries them (browser.launchOptions.args). One file per uid, rewritten on
# every launch, so nothing piles up and no other uid's file blocks us.
CONFIG="${TMPDIR:-/tmp}/agents-browser-mcp-$(id -u).json"
cat >"${CONFIG}.tmp" <<JSON
{
  "browser": {
    "launchOptions": {
      "args": ["--window-position=0,0", "--window-size=${WINDOW_W},${WINDOW_H}"]
    },
    "contextOptions": { "viewport": null }
  }
}
JSON
mv -f "${CONFIG}.tmp" "${CONFIG}"

set -- --config "${CONFIG}" "$@"
if [ -n "${VIEWPORT}" ]; then
    set -- --viewport-size "${VIEWPORT}" "$@"
fi

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
    "$@"
