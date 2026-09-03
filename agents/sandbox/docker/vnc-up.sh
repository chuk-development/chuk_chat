#!/bin/sh
# cowork-vnc-up — start x11vnc on the browser display, on demand, for the live
# view / login hand-off (§9). Called via a detached `docker exec` when the user
# opens the browser view; the host then bridges x11vnc's localhost RFB port over
# the sealed E2E channel with `docker exec -i <container> socat STDIO
# TCP:127.0.0.1:<port>` — no port is ever published on the container.
#
# Idempotent: if x11vnc is already serving the display, do not start a second.
# Binds to localhost only, so the RFB port is reachable only from inside the
# container (the socat bridge runs inside too, over docker exec's stdio).
#
# NO flock here, on purpose. The obvious `exec flock <lock> … exec x11vnc -bg`
# is a trap: `-bg` daemonizes and keeps every inherited fd open, INCLUDING the
# lock fd, so x11vnc holds the lock forever and the NEXT `cowork-vnc-up`
# deadlocks — the executor then times out and reports "vnc start failed", i.e.
# the view stops transmitting after the first open. x11vnc already serialises
# itself: only one process can bind the RFB port, so a lost race just makes the
# second x11vnc exit and we re-check. Two other rules, both learned the hard way:
#  * The daemon must not hold this script's stdout (the `docker exec` pipe), or
#    the exec never sees EOF and hangs — so x11vnc is launched fully detached
#    (setsid, stdio to a log file), never on our stdout.
#  * The only line this script prints to stdout is the machine-readable WINDOWS=
#    line the executor parses. Nothing else, so parsing stays trivial.

set -eu

DISPLAY_NUM="${COWORK_BROWSER_DISPLAY:-:99}"
PORT="${COWORK_VNC_PORT:-5900}"
LOG="${COWORK_VNC_LOG:-/tmp/x11vnc.log}"

# Nothing to serve if the display is not up. The browser launcher brings Xvfb up;
# if the agent never opened the browser there is nothing to watch yet.
if ! xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1; then
    echo "cowork-vnc-up: no display ${DISPLAY_NUM} yet" >&2
    exit 3
fi

# How many visible top-level windows are on the display? A bare Xvfb with no
# browser open has none, so the stream would be an all-black framebuffer — the
# classic "VNC not transmitting" confusion. Report the count so the executor can
# tell the user "no page open yet" instead of streaming a silent black screen.
# Best-effort: if xdotool is missing or errors, report -1 (unknown), never fail.
WINDOWS=-1
if command -v xdotool >/dev/null 2>&1; then
    WINDOWS=$(DISPLAY="${DISPLAY_NUM}" xdotool search --onlyvisible "" 2>/dev/null | wc -l | tr -d ' ')
    [ -n "${WINDOWS}" ] || WINDOWS=-1
fi

# Start x11vnc only if none is already serving the port. `setsid … </dev/null
# >>LOG 2>&1` fully detaches the daemon from this script's stdin/stdout/stderr,
# so `docker exec` gets EOF and returns at once and no fd is leaked into the
# long-lived process. -localhost: reachable only inside the container. -nopw: no
# VNC secret — the boundary is the sealed E2E channel and device approval.
# -forever -shared: survive client disconnects; allow the agent's view alongside.
# -noxdamage/-noshm: robust capture under headless Xvfb in a container.
if ! pgrep -f "x11vnc.*-rfbport ${PORT}" >/dev/null 2>&1; then
    setsid x11vnc \
        -display "${DISPLAY_NUM}" \
        -rfbport "${PORT}" \
        -localhost \
        -nopw \
        -forever \
        -shared \
        -noxdamage \
        -noshm \
        -quiet \
        -o "${LOG}" \
        -bg </dev/null >>"${LOG}" 2>&1 || true

    # Wait briefly for the RFB port to accept connections. If a concurrent caller
    # won the port race our own x11vnc exited, but theirs is coming up — either
    # way we only need SOME x11vnc listening. Fail only if none appears.
    up=0
    i=0
    while [ "${i}" -lt 50 ]; do
        if pgrep -f "x11vnc.*-rfbport ${PORT}" >/dev/null 2>&1; then
            up=1
            break
        fi
        i=$((i + 1))
        sleep 0.1
    done
    if [ "${up}" -eq 0 ]; then
        echo "cowork-vnc-up: x11vnc did not come up on ${DISPLAY_NUM}" >&2
        cat "${LOG}" >&2 2>/dev/null || true
        exit 1
    fi
fi

# Machine-readable line the executor parses; keep it last and the only stdout.
echo "WINDOWS=${WINDOWS}"
exit 0
