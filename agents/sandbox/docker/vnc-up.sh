#!/bin/sh
# agents-vnc-up — start x11vnc on the browser display, on demand, for the live
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
# lock fd, so x11vnc holds the lock forever and the NEXT `agents-vnc-up`
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

DISPLAY_NUM="${AGENTS_BROWSER_DISPLAY:-:99}"
PORT="${AGENTS_VNC_PORT:-5900}"
LOG="${AGENTS_VNC_LOG:-/tmp/x11vnc.log}"

# Nothing to serve if the display is not up. The browser launcher brings Xvfb up;
# if the agent never opened the browser there is nothing to watch yet.
if ! xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1; then
    echo "agents-vnc-up: no display ${DISPLAY_NUM} yet" >&2
    exit 3
fi

# How many browser PAGES are on the display? A bare Xvfb with no browser open
# has none, so the stream would be an all-black framebuffer — the classic "VNC
# not transmitting" confusion. Report the count so the executor can open the
# browser instead of streaming a silent black screen.
#
# Count by WM_CLASS, not by "any mapped window": Chromium maps two helpers next
# to every page — a 1x1 window and a 10x10 one named "Chromium clipboard" — and
# neither carries a class. Counting them reported a browser on a display that
# had none (measured in a live container: 2 windows by name, 1 by class, for
# one open page), and the user was shown a black screen that claimed to work.
# Best-effort: if nothing can count, report -1 (unknown), never fail.
WINDOWS=-1
if command -v xwininfo >/dev/null 2>&1; then
    WINDOWS=$(DISPLAY="${DISPLAY_NUM}" xwininfo -root -children 2>/dev/null \
        | grep -Eci '\("[^"]*[Cc]hrom' || true)
    [ -n "${WINDOWS}" ] || WINDOWS=-1
elif command -v xdotool >/dev/null 2>&1; then
    WINDOWS=$(DISPLAY="${DISPLAY_NUM}" xdotool search --onlyvisible --class '[Cc]hrom' 2>/dev/null | wc -l | tr -d ' ')
    [ -n "${WINDOWS}" ] || WINDOWS=-1
fi

# Per-view secret (§9.1 hardening). When the executor passes AGENTS_VNC_PASSWD
# (it runs this script as root), the secret is written to a root-only file and
# x11vnc is started with `-passwdfile read:FILE` — re-read on EVERY client
# connect, so a new view can rotate the secret without restarting x11vnc. The
# agent's own code runs as `agents` and cannot read the file, so nothing inside
# the sandbox can watch the screen or inject input without the secret the app
# received inside its sealed frame. Without the variable (old callers) x11vnc
# stays passwordless as before.
PASS_FILE="${AGENTS_VNC_PASS_FILE:-/run/agents-vnc.pass}"
# A secret is REQUIRED. Anything in the sandbox can run this script (it is on
# PATH for the agent's own shell); without this rule the agent could start a
# passwordless x11vnc itself and watch the login hand-off. The only way to get
# `-nopw` is the explicit AGENTS_VNC_ALLOW_NOPW=1, which the executor never
# sets — it exists for manual debugging in a throwaway container.
if [ -z "${AGENTS_VNC_PASSWD:-}" ] && [ "${AGENTS_VNC_ALLOW_NOPW:-0}" != "1" ]; then
    echo "agents-vnc-up: refusing to start x11vnc without AGENTS_VNC_PASSWD" >&2
    exit 4
fi
AUTH_ARGS="-nopw"
if [ -n "${AGENTS_VNC_PASSWD:-}" ]; then
    umask 077
    printf '%s\n' "${AGENTS_VNC_PASSWD}" > "${PASS_FILE}.tmp"
    chmod 600 "${PASS_FILE}.tmp"
    mv -f "${PASS_FILE}.tmp" "${PASS_FILE}"
    AUTH_ARGS="-passwdfile read:${PASS_FILE}"
    # An x11vnc started passwordless earlier must not keep serving: replace it.
    if pgrep -f "x11vnc.*-rfbport ${PORT}.*-nopw" >/dev/null 2>&1; then
        pkill -f "x11vnc.*-rfbport ${PORT}.*-nopw" || true
        sleep 0.3
    fi
fi

# Latency/stability tuning, measured with executor/tests/live_vnc_connect_probe.py
# against a live sandbox container (cowork-c0zd). Every flag below is here
# because a number moved:
#
# -sb 0        x11vnc's default is `-sb 60`: after 60 s with nothing happening
#              it "really throttles down the screen polls (sleep about 1.5 s)".
#              A view opened while the agent was quiet then waits for that sleep
#              loop before ANY picture arrives. Measured on a live box: first
#              full frame 3973 ms after 70 s idle vs 5 ms when busy — the whole
#              of "it loads forever". With -sb 0 the same idle box answers in
#              5-60 ms. It costs nothing while nobody watches: with no client
#              connected x11vnc burns 0 CPU ticks over 20 s either way.
# -nonap       the other half of the same throttle (`-nap` is the default and
#              "takes longer naps between screen polls" when activity is low).
#              Only safe TOGETHER with DAMAGE: measured with -noxdamage it
#              costs 391 CPU ticks/15 s against 168 for the default, while with
#              DAMAGE on it costs 154 — less than the default.
# (no -noxdamage)
#              The Xvfb in this image advertises DAMAGE, so x11vnc is told what
#              changed instead of re-scanning 1280x800. Measured: the pixels are
#              byte-identical to the polling capture over repeated full frames,
#              and CPU while watching drops (154 vs 175 ticks/15 s).
#              AGENTS_VNC_XDAMAGE=0 forces the old polling behaviour back for a
#              display where DAMAGE misbehaves; x11vnc itself already falls back
#              when the extension is absent.
# -ping 30     a 1x1 framebuffer update every 30 s. The stream leaves this
#              container through a docker-exec pipe, the sealed relay and a
#              phone's mobile link; a view that is quiet for minutes is exactly
#              what an idle timeout on that path reaps. Bytes keep flowing.
# -readtimeout 120
#              libvncserver's rfbMaxClientWait, default 20 s: when a write to
#              the client cannot complete for that long, the client is DROPPED.
#              Our writes stall whenever the phone's link stalls — the executor
#              pump stops draining socat, socat stops reading, x11vnc blocks —
#              so a 20 s tunnel hiccup killed the view for good. 120 s rides out
#              a tunnel or a lift.
# -desktop     a version marker, nothing else. It is how the block below tells
#              an x11vnc started by an OLDER copy of this script (an image that
#              was already running when the flags changed) from a current one,
#              so the stale one is replaced instead of reused forever.
# (no -nocursor)
#              x11vnc's cursor defaults are already the ones we want and must
#              stay: `-cursor` (on) and `-cursorpos` (on). Measured against a
#              live box — a client that advertises the cursor pseudo-encodings
#              is sent the REAL remote pointer as RichCursor (-239) rectangles
#              plus CursorPos (-232); a client that does not gets the same
#              pointer composited into the framebuffer. Either way the user sees
#              the agent's actual mouse, so nothing here has to draw a fake one.
#              How BIG it is comes from the cursor theme, which the browser
#              launcher sets (XCURSOR_SIZE), not from x11vnc.
#              Note for whoever wires a new client: this x11vnc (0.9.16) does
#              NOT support ContinuousUpdates. It never sends
#              EndOfContinuousUpdates, and a client that sends
#              EnableContinuousUpdates (message 150) anyway has its connection
#              CLOSED — measured. noVNC only sends it after the server offers
#              it, so noVNC is safe; a hand-written client must not assume.
# -noshm       stays. MIT-SHM is advertised, but x11vnc runs as ROOT against an
#              Xvfb owned by `agents`, and XShmAttach then fails with BadAccess
#              (measured; x11vnc aborts on the X error). Shared memory is not
#              available to us, whatever the extension list says.
#
# Throughput tuning (measured earlier, executor/tests/live_vnc_speed_probe.py):
# x11vnc's defaults (-defer 30, -wait 20, no threads) throttled a full 1280x800
# frame to ~3.9 MB/s = 0.9 FPS through the docker-exec pipe, while the pipe
# itself does ~82 MB/s. -threads + -defer 1 -wait 2 lifts a full refresh to
# ~19 MB/s = ~5 FPS (5x), and incremental updates stay tiny. Frame size is
# handled by the client negotiating the Tight encoding (JPEG for photos, zlib'd
# palette/copy for UI): ~0.2 MB per full 1280x800 frame instead of the 4 MB raw
# pixels the client asked for before it could decode Tight.
#
# Bump AGENTS_VNC_REVISION whenever the flag list changes, so a container that
# is already running picks the new flags up on the next view instead of serving
# the old ones until it is recreated.
AGENTS_VNC_REVISION=2
DESKTOP_NAME="cowork-vnc/${AGENTS_VNC_REVISION}"
DAMAGE_ARGS="-nonap"
if [ "${AGENTS_VNC_XDAMAGE:-1}" = "0" ]; then
    DAMAGE_ARGS="-noxdamage"
fi

# An x11vnc from an older copy of this script serves the port with the old
# flags — including the 4-second wake-up and the 20-second write timeout. It
# does not carry our marker, so replace it. `browser_start` has already torn
# the previous view down by the time we run, so nothing is watching.
if pgrep -f "x11vnc.*-rfbport ${PORT}" >/dev/null 2>&1 \
   && ! pgrep -f "x11vnc.*-rfbport ${PORT}.*-desktop ${DESKTOP_NAME}" >/dev/null 2>&1; then
    pkill -f "x11vnc.*-rfbport ${PORT}" || true
    sleep 0.3
fi

# Start x11vnc only if none is already serving the port. `setsid … </dev/null
# >>LOG 2>&1` fully detaches the daemon from this script's stdin/stdout/stderr,
# so `docker exec` gets EOF and returns at once and no fd is leaked into the
# long-lived process. -localhost: reachable only inside the container. -nopw: no
# VNC secret — the boundary is the sealed E2E channel and device approval.
# -forever -shared: survive client disconnects; allow the agent's view alongside.
if ! pgrep -f "x11vnc.*-rfbport ${PORT}" >/dev/null 2>&1; then
    setsid x11vnc \
        -display "${DISPLAY_NUM}" \
        -rfbport "${PORT}" \
        -localhost \
        ${AUTH_ARGS} \
        -desktop "${DESKTOP_NAME}" \
        -forever \
        -shared \
        ${DAMAGE_ARGS} \
        -noshm \
        -quiet \
        -threads \
        -defer 1 \
        -wait 2 \
        -sb 0 \
        -ping 30 \
        -readtimeout 120 \
        -o "${LOG}" \
        -bg </dev/null >>"${LOG}" 2>&1 || true

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
        echo "agents-vnc-up: x11vnc did not come up on ${DISPLAY_NUM}" >&2
        cat "${LOG}" >&2 2>/dev/null || true
        exit 1
    fi
fi

# Machine-readable line the executor parses; keep it last and the only stdout.
echo "WINDOWS=${WINDOWS}"
exit 0
