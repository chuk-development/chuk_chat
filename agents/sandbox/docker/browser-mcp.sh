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
    # -noreset: by default Xvfb resets when its last client goes away, and a
    # reset drops every root window property. The work area below is such a
    # property, and the browser connects only after this script set it.
    Xvfb "${DISPLAY_NUM}" -screen 0 "${SCREEN}" -nolisten tcp -noreset >/tmp/xvfb.log 2>&1 &
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
# show the whole display, so the browser window must cover it: at 0,0 and as
# large as the work area (see "A work area" below). There is no window manager, so --start-maximized
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

# A work area and a window that fills it (bead chuk_chat-elw7 and the
# fingerprint work, 2026-10-29). Chromium on X11 makes a window that is
# exactly screen-sized 1 px smaller each way, so it is not taken for
# fullscreen: --window-size=1280,800 gave 1279x799 and a black line at the
# right and bottom edge. The old fix was a window 1 px LARGER than the screen
# (1281x801). That is a bot tell: outerWidth/outerHeight were larger than
# screen.width/height, and screen.avail* was the full screen (no taskbar).
# Measured on a real desktop: availHeight = screen minus the panel, and a
# maximized window = the work area.
#
# So the launcher now acts as a desktop with a bottom panel of PANEL px. It
# writes _NET_WORKAREA on the root window (Chromium reads it for
# screen.avail*, also with no window manager) and makes the window as large
# as the work area. The window is then not screen-sized, so Chromium does not
# shrink it. Measured on 1280x800: screen 1280x800, avail 1280x756, outer
# 1280x756 at 0,0. The strip under the window has no content; agents-vnc-up
# reads the same _NET_WORKAREA and clips the live view to it, so the watcher
# does not see the strip. 44 px is the default KDE Plasma panel height.
PANEL=44
if [ "${HEIGHT}" -le $((PANEL * 4)) ]; then
    PANEL=0
fi
WINDOW_W="${WIDTH}"
WINDOW_H=$((HEIGHT - PANEL))
if [ "${PANEL}" -eq 0 ]; then
    # A display too small for a panel: the old 1 px trick.
    WINDOW_W=$((WIDTH + 1))
    WINDOW_H=$((HEIGHT + 1))
fi
# Best effort: with no xprop, screen.avail* is the full screen. Nothing else
# breaks.
xprop -root -f _NET_WORKAREA 32c -set _NET_WORKAREA \
    "0,0,${WIDTH},$((HEIGHT - PANEL))" >/dev/null 2>&1 || true

# Look like a normal Chrome, not like a test browser. Sites such as PayPal
# answer an automated browser with endless captchas, and they do not need the
# IP for that: the browser says it itself. Measured in this image with
# Playwright's defaults: navigator.webdriver = true, the time zone UTC on a
# German IP. The fixes:
# - Playwright passes --enable-automation by default. That flag sets
#   navigator.webdriver and shows the "controlled by automated test software"
#   bar. ignoreDefaultArgs drops it. --disable-blink-features=
#   AutomationControlled keeps navigator.webdriver false also when the
#   browser is started some other way.
# - The time zone and the language come from the host (TZ and
#   AGENTS_BROWSER_LOCALE, set by the sandbox when it creates the container),
#   so they agree with the user's IP. Chromium ships its own time zone data,
#   so TZ works without tzdata in the image.
# - The language goes to Chrome through LANGUAGE, as on a real Linux desktop.
#   Chrome then picks its UI language and its default Accept-Language list
#   itself. Measured for de-DE: Accept-Language "de-DE,de;q=0.9,en-US;q=0.8,
#   en;q=0.7", navigator.languages ["de-DE","de","en-US","en"], Intl locale
#   "de" - the same as a real German Chrome. Two traps: Playwright's
#   contextOptions.locale overrides the header with the bare locale
#   ("de-DE", one entry, a tell), so it is not set. And --lang does nothing
#   on Linux (Chrome reads the environment there).
# - WebGL: with no GPU, Chrome draws with SwiftShader and says so in
#   UNMASKED_RENDERER ("ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device
#   (Subzero)...)"). That is the strongest bot tell. Xvfb has no GLX for a
#   real GPU, so ANGLE's GL backend cannot use one, but its Vulkan backend
#   can. When the sandbox gave the container an NVIDIA GPU (docker.py,
#   --gpus with capability graphics), --use-angle=vulkan makes WebGL and the
#   compositor use it. Measured on an RTX 3060: "ANGLE (NVIDIA, Vulkan 1.4.341
#   (NVIDIA NVIDIA GeForce RTX 3060 (0x00002504)), NVIDIA)", and the live view
#   shows the page and the WebGL canvas. With no GPU the flag is not set (it
#   would fall back to SwiftShader too, measured). Instead webgl-mesa.js
#   (an init script) makes a software renderer report "ANGLE (Intel, Mesa
#   Intel(R) UHD Graphics 620 (KBL GT2), OpenGL 4.6)". That is the usual
#   host: a VPS has no GPU. The pixels are still SwiftShader's, see the
#   script.
#   --use-angle=gl and gl-egl give no WebGL at all on Xvfb;
#   --ignore-gpu-blocklist gives "llvmpipe", a tell of its own.
# - Media devices: a container has no microphone, camera or speaker, so
#   enumerateDevices() was []. A real PC lists one of each.
#   --use-fake-device-for-media-stream gives one audioinput, videoinput and
#   audiooutput. Before a permission grant the labels are empty, as on a real
#   PC; getUserMedia still asks for permission as usual.
# - Google Chrome instead of Chrome for Testing: see Dockerfile.browser.
# Measure again with fingerprint-probe.py (next to this file) after a change.
# Also measured clean: bot.sannysoft.com all passed; creepjs 0% headless,
# 0% stealth. Its "like headless" hits left are noWebShare, noContentIndex,
# noContactsManager, noDownlinkMax (true on every desktop Linux Chrome),
# hasKnownBgColor and prefersLightColor (a light theme).
LOCALE="${AGENTS_BROWSER_LOCALE:-en-US}"
case "${LOCALE}" in
    *[!A-Za-z0-9-]* | "") LOCALE=en-US ;;
esac
# de-DE -> de_DE, the form the environment uses.
export LANGUAGE="$(printf '%s' "${LOCALE}" | tr '-' '_')"

# /dev/nvidiactl exists only when the NVIDIA container toolkit put the GPU
# into this container (docker.py decides that, AGENTS_SANDBOX_GPU=0 turns it
# off).
GPU_ARGS=""
# AGENTS_BROWSER_WEBGL_SCRIPT="" turns the WebGL init script off.
WEBGL_SCRIPT="${AGENTS_BROWSER_WEBGL_SCRIPT-/usr/local/lib/agents/webgl-mesa.js}"
if [ -e /dev/nvidiactl ]; then
    GPU_ARGS='"--use-angle=vulkan",'
elif [ -r "${WEBGL_SCRIPT}" ]; then
    # No GPU (a VPS, a headless server): WebGL is SwiftShader. The init
    # script makes it report a common Intel GPU on Mesa; read its header for
    # what it cannot hide.
    set -- --init-script "${WEBGL_SCRIPT}" "$@"
fi

# Playwright MCP has no CLI flag for extra Chromium arguments; its config file
# carries them (browser.launchOptions.args). One file per uid, rewritten on
# every launch, so nothing piles up and no other uid's file blocks us.
CONFIG="${TMPDIR:-/tmp}/agents-browser-mcp-$(id -u).json"
cat >"${CONFIG}.tmp" <<JSON
{
  "browser": {
    "launchOptions": {
      "args": [
        ${GPU_ARGS}
        "--window-position=0,0",
        "--window-size=${WINDOW_W},${WINDOW_H}",
        "--disable-blink-features=AutomationControlled",
        "--use-fake-device-for-media-stream"
      ],
      "ignoreDefaultArgs": ["--enable-automation"]
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
