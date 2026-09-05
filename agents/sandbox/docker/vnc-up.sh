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

# Per-view secret (§9.1 hardening). When the executor passes COWORK_VNC_PASSWD
# (it runs this script as root), the secret is written to a root-only file and
# x11vnc is started with `-passwdfile read:FILE` — re-read on EVERY client
# connect, so a new view can rotate the secret without restarting x11vnc. The
# agent's own code runs as `cowork` and cannot read the file, so nothing inside
# the sandbox can watch the screen or inject input without the secret the app
# received inside its sealed frame. Without the variable (old callers) x11vnc
# stays passwordless as before.
PASS_FILE="${COWORK_VNC_PASS_FILE:-/run/cowork-vnc.pass}"
# A secret is REQUIRED. Anything in the sandbox can run this script (it is on
# PATH for the agent's own shell); without this rule the agent could start a
# passwordless x11vnc itself and watch the login hand-off. The only way to get
# `-nopw` is the explicit COWORK_VNC_ALLOW_NOPW=1, which the executor never
# sets — it exists for manual debugging in a throwaway container.
if [ -z "${COWORK_VNC_PASSWD:-}" ] && [ "${COWORK_VNC_ALLOW_NOPW:-0}" != "1" ]; then
    echo "cowork-vnc-up: refusing to start x11vnc without COWORK_VNC_PASSWD" >&2
    exit 4
fi
AUTH_ARGS="-nopw"
if [ -n "${COWORK_VNC_PASSWD:-}" ]; then
    umask 077
    printf '%s\n' "${COWORK_VNC_PASSWD}" > "${PASS_FILE}.tmp"
    chmod 600 "${PASS_FILE}.tmp"
    mv -f "${PASS_FILE}.tmp" "${PASS_FILE}"
    AUTH_ARGS="-passwdfile read:${PASS_FILE}"
    # An x11vnc started passwordless earlier must not keep serving: replace it.
    if pgrep -f "x11vnc.*-rfbport ${PORT}.*-nopw" >/dev/null 2>&1; then
        pkill -f "x11vnc.*-rfbport ${PORT}.*-nopw" || true
        sleep 0.3
    fi
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
        ${AUTH_ARGS} \
        -forever \
        -shared \
        -noxdamage \
        -noshm \
        -quiet \
        -threads \
        -defer 1 \
        -wait 2 \
        -o "${LOG}" \
        -bg </dev/null >>"${LOG}" 2>&1 || true
        # Throughput tuning (measured with executor/tests/live_vnc_speed_probe.py):
        # x11vnc's defaults (-defer 30, -wait 20, no threads) throttled a full
        # 1280x800 frame to ~3.9 MB/s = 0.9 FPS through the docker-exec pipe,
        # while the pipe itself does ~82 MB/s. -threads + -defer 1 -wait 2 lifts a
        # full refresh to ~19 MB/s = ~5 FPS (5x), and incremental updates stay
        # tiny. Frame size is handled by the client negotiating the Tight
        # encoding (JPEG for photos, zlib'd palette/copy for UI): ~0.2 MB per
        # full 1280x800 frame instead of the 4 MB raw pixels the client asked
        # for before it could decode Tight.

    # Wait briefly for the RFB port to accept connections. If a concurrent caller
    # won the port race our own x11vnc exited, but theirs is coming up — either
    # way we only need SOME x11vnc listening. Fail only if none appears.
    # Probe the PORT, not the process: `-bg` returns before x11vnc necessarily
    # accepts connections, and a socat bridge that dials too early gets
    # ECONNREFUSED and the view flashes "stopped". socat is in the image (the
    # bridge itself uses it); this script is /bin/sh, so no bash /dev/tcp.
    up=0
    i=0
    while [ "${i}" -lt 50 ]; do
        if socat -u /dev/null "TCP:127.0.0.1:${PORT},connect-timeout=1" >/dev/null 2>&1; then
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
