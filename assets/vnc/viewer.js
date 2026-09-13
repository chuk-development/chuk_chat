// The agent's screen, drawn by noVNC inside a WebView.
//
// Why a WebView at all: the pure-Dart RFB client we used before understands
// raw and copyRect only, so every full 1280x800 frame cost about 4 MB. noVNC
// speaks Tight, ZRLE and the cursor pseudo-encoding, and it brings a tested
// gesture and scaling layer. The app ships noVNC as its own asset (see
// ../novnc/VENDORED.txt) and the Dart host serves this page and the RFB
// WebSocket from a token-gated loopback server; the page never talks to
// anything else.
//
// Host contract
// -------------
// The host drives the page through `window.agents` and reads it back through
// the `AgentsVncBridge` JavaScript channel. The page never starts on its own:
// the RFB password arrives with `agents.start()`, so it never rides a URL.
//
// Numbers below are measured behaviour, not taste. Each one carries the
// reason it has that value.

import RFB from "../novnc/core/rfb.js";

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

// Zoom ceiling, in framebuffer pixels rather than a fixed number.
//
// A fixed cap is a cap on ONE screen size. The ceiling belongs where the
// picture runs out of detail, so it is computed from the agent's own
// framebuffer: never zoom past the point where fewer than this many
// framebuffer pixels are left across the viewport. At the 1280-wide desktop we
// run today that lands on exactly 4x, which is the number Grok's viewer uses;
// a wider desktop earns more zoom, a narrower one less, without touching this
// file.
const MIN_VISIBLE_FB_PX = 320;
// ...but a small desktop on a dense screen must still be allowed as far as
// one framebuffer pixel per device pixel, and nothing is allowed past this.
const ZOOM_HARD_CEILING = 8;
// Change in finger separation (CSS px) that can read as a pinch. Below it the
// hand is doing something else.
const PINCH_SLOP_PX = 12;
// Separation change (CSS px) that is a pinch whatever else the hand does.
// Between the two thresholds the spread must also beat the pair's travel,
// which is what keeps a two-finger scroll with some finger drift a scroll.
const PINCH_DECISIVE_PX = 40;
// Centroid travel (CSS px) past which a zoomed two-finger gesture is a pan.
// Below it the gesture may still become a two-finger TAP, which the remote
// owns, so it is left alone.
const PAN_SLOP_PX = 12;
// How far past a viewport edge a zoomed desktop may be dragged, as a fraction
// of that edge. Half, so any row of the desktop can be pulled to the middle of
// the screen out from under the host's floating controls. The view stays where
// it is put; there is no rubber band.
const PAN_OVERSCROLL = 0.5;
// Backoff before re-dialling a connection that has nothing on screen. A drop
// under a held frame retries at once: that recovery is the one the user waits
// on.
const RETRY_MS = 1000;

// --- Trackpad mode only (off by default) ---
// Cursor gain in CSS px. 1:1 feels slow because the desktop is letterboxed
// into a phone width, so the finger crosses far more screen than the cursor
// covers.
const POINTER_GAIN = 1.5;
// Two-finger scroll gain. noVNC emits one wheel notch per 50 accumulated CSS
// px, so above 1 a phone-sized drag scrolls a useful distance.
const WHEEL_GAIN = 2;
// Displacement (CSS px) from touch-down above which a one-finger gesture moves
// the cursor instead of clicking.
const TAP_SLOP_PX = 8;
// A still single touch this long puts the left button down and holds it until
// the finger lifts. Long enough that a slow tap is still a tap.
const HOLD_MS = 500;
// A fresh touch this soon after a tap, and this close to it, starts a held
// drag — the usual double-tap-and-hold.
const DOUBLE_TAP_MS = 300;
const DOUBLE_TAP_SLOP_PX = 24;

// X11 keysyms the host sends by name.
const KEYSYM_CTRL_L = 0xffe3;
const KEYSYM_C = 0x0063;
const KEYSYM_V = 0x0076;
// Code points at or above this ride the X11 Unicode range. A bare code point
// up there would land as an unrelated function keysym.
const KEYSYM_UNICODE_BASE = 0x01000000;

const screen = document.getElementById("screen");
const held = document.getElementById("held");
const overlay = document.getElementById("trackpad");

const wsUrl = (() => {
  const raw = new URLSearchParams(window.location.search).get("ws");
  if (raw === null || raw === "") return null;
  try {
    // The WebSocket constructor throws on any fragment, so one riding the URL
    // is stripped instead of killing connect.
    const url = new URL(raw, window.location.href);
    url.hash = "";
    return url.toString();
  } catch (_error) {
    return null;
  }
})();

function post(message) {
  const bridge = window.AgentsVncBridge;
  if (bridge === undefined || bridge === null) return;
  try {
    bridge.postMessage(JSON.stringify(message));
  } catch (_error) {
    // A dead bridge must never break the picture.
  }
}

function clamp(value, low, high) {
  return value < low ? low : value > high ? high : value;
}

// The live desktop canvas. noVNC rebuilds it when the remote resolution
// changes, so it is resolved on every use; a stale reference silently eats
// input. Scoped to #screen so the cursor canvas noVNC puts on <body> is never
// mistaken for it.
function desktopCanvas() {
  return screen.querySelector("canvas");
}

// ---------------------------------------------------------------------------
// View: zoom and pan
// ---------------------------------------------------------------------------
// The view resizes #screen and offsets it with left/top. It never scales it
// with a CSS transform, for two reasons. noVNC observes that element and
// re-runs its own autoscale, so the canvas rect and the scale its coordinate
// maths divides by move together and a tap keeps landing where it was aimed.
// And a transformed #screen stops the Android WebView compositing the whole
// subtree: the desktop then paints one frame after a resume and is black the
// rest of the time.

const view = {
  zoom: 1,
  panX: 0,
  panY: 0,
  // Only the crossing between fitted and zoomed is reported, never a pan frame.
  reportedZoomed: false,
};

// The framebuffer's own pixel size, off the canvas backing store. noVNC makes
// that canvas 0x0 and sizes it when the server reports the framebuffer, which
// happens before it emits `connect` — so this is null exactly while there is
// no desktop.
function framebufferSize() {
  const canvas = desktopCanvas();
  if (canvas === null || canvas.width === 0 || canvas.height === 0) return null;
  return { width: canvas.width, height: canvas.height };
}

// The box the desktop occupies at zoom `z`. At zoom 1 it is the largest box of
// the framebuffer's aspect that the viewport fits — deliberately not the
// viewport itself, so a zoomed view can use the height the letterbox wastes.
function desktopBox(z) {
  const fb = framebufferSize();
  if (fb === null) return null;
  const fit = Math.min(
    window.innerWidth / fb.width,
    window.innerHeight / fb.height,
  );
  return { width: z * fit * fb.width, height: z * fit * fb.height };
}

// The ceiling for the current desktop and the current screen.
function maxZoom() {
  const fb = framebufferSize();
  if (fb === null) return 1;
  const byDetail = fb.width / MIN_VISIBLE_FB_PX;
  const fit = Math.min(
    window.innerWidth / fb.width,
    window.innerHeight / fb.height,
  );
  const dpr = window.devicePixelRatio || 1;
  const byPixels = 1 / (fit * dpr);
  return clamp(Math.max(byDetail, byPixels), 1.5, ZOOM_HARD_CEILING);
}

// An axis with no travel is centred rather than clamped. That is how the
// desktop sits in the height the letterbox leaves it.
function axisOffset(box, viewport, wanted, slack) {
  const low = viewport - box - slack;
  const high = slack;
  if (low >= high) return (viewport - box) / 2;
  return clamp(wanted, low, high);
}

function setView(z, x, y) {
  const next = clamp(z, 1, maxZoom());
  const box = desktopBox(next);
  // With no desktop yet the zoom is left alone too, or a pinch on the black
  // connecting screen would spring into effect the moment the picture arrives.
  if (box === null) return;
  view.zoom = next;
  // Only a zoomed view gets overscroll. Fitted, the desktop is already the
  // largest the viewport holds and there is nowhere to pan.
  const slack = next > 1 ? PAN_OVERSCROLL : 0;
  view.panX = axisOffset(box.width, window.innerWidth, x, slack * window.innerWidth);
  view.panY = axisOffset(box.height, window.innerHeight, y, slack * window.innerHeight);
  screen.style.width = box.width + "px";
  screen.style.height = box.height + "px";
  screen.style.left = view.panX + "px";
  screen.style.top = view.panY + "px";
  const zoomed = view.zoom > 1;
  if (view.reportedZoomed !== zoomed) {
    view.reportedZoomed = zoomed;
    post({ event: "zoom", zoomed: zoomed });
  }
}

function reflow() {
  setView(view.zoom, view.panX, view.panY);
}

function panBy(dx, dy) {
  setView(view.zoom, view.panX + dx, view.panY + dy);
}

function zoomToFit() {
  setView(1, 0, 0);
}

window.addEventListener("resize", reflow);

// ---------------------------------------------------------------------------
// Gesture classifier
// ---------------------------------------------------------------------------
// Runs in the capture phase on window, so it decides what a two-finger gesture
// is before noVNC and before the trackpad overlay see it. Once it claims a
// gesture it silences noVNC with `viewOnly`, because noVNC's own pinch sends
// Ctrl+wheel to the REMOTE and would zoom the page under the agent instead of
// the picture in front of the user.
//
// The mute is lifted late on purpose: noVNC has not seen the touchend yet when
// our handler runs, and it reads a release inside its own tap timeout as a
// middle click.

let pinch = null;
// null, not false: noVNC's viewOnly is a value that has to be restored, not
// assumed.
let mutedViewOnly = null;

// There is deliberately NO double-tap-to-fit gesture here, at any zoom level.
// A double click is real work on a remote browser — select a word, replace a
// word, pick out a line — and it is needed MOST when zoomed in, because that
// is when the user is close to a text field. Spending it on a second way to
// reach the fitted view is a bad trade: the "Zoom to fit" button already does
// that, it is always on screen, and it lights up as soon as it has something
// to undo. Every double tap goes to the agent's desktop untouched.

function separation(a, b) {
  // Floored at 1 so a two-finger tap cannot divide by zero.
  return Math.max(Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY), 1);
}

function centroid(a, b) {
  return { x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 };
}

// Measured against the CURRENT view, so a changing finger count never jumps.
function beginPinch(touches, claimed) {
  const c = centroid(touches[0], touches[1]);
  pinch = {
    startSeparation: separation(touches[0], touches[1]),
    startX: c.x,
    startY: c.y,
    lastX: c.x,
    lastY: c.y,
    startZoom: view.zoom,
    startPanX: view.panX,
    startPanY: view.panY,
    claimed: claimed,
  };
}

function claimPinch() {
  pinch.claimed = true;
  trackpad.cancelGesture();
  const rfb = session.rfb;
  if (rfb !== null && mutedViewOnly === null) {
    mutedViewOnly = rfb.viewOnly;
    rfb.viewOnly = true;
  }
}

// Releases whatever button noVNC pressed before the mute. A drag it had begun
// would otherwise stay held down on the agent's desktop.
function unmute(x, y) {
  if (mutedViewOnly === null) return;
  const rfb = session.rfb;
  if (rfb !== null) rfb.viewOnly = mutedViewOnly;
  mutedViewOnly = null;
  const canvas = desktopCanvas();
  if (canvas === null) return;
  canvas.dispatchEvent(new MouseEvent("mouseup", {
    bubbles: true, cancelable: true, view: window,
    clientX: x, clientY: y, buttons: 0, button: 0,
  }));
}

window.addEventListener("touchstart", (e) => {
  const first = e.touches[0];
  if (first === undefined) return;
  // One touch means every other finger is already up, so a gesture still open
  // here is one whose end never arrived. Dropping it matters: a lost touchend
  // would otherwise leave noVNC muted, that is, the viewer silently ignoring
  // everything the user does.
  if (e.touches.length === 1) {
    pinch = null;
    unmute(first.clientX, first.clientY);
    return;
  }
  beginPinch(e.touches, pinch !== null && pinch.claimed);
}, { capture: true, passive: false });

window.addEventListener("touchmove", (e) => {
  if (pinch === null || e.touches.length < 2) return;
  const gap = separation(e.touches[0], e.touches[1]);
  const c = centroid(e.touches[0], e.touches[1]);
  pinch.lastX = c.x;
  pinch.lastY = c.y;
  const spread = Math.abs(gap - pinch.startSeparation);
  const travel = Math.hypot(c.x - pinch.startX, c.y - pinch.startY);
  // Two thresholds. A decisive spread is proof on its own; an ambiguous one
  // must also out-measure the pair's travel. A hand pinches and moves at the
  // same time, so asking every pinch to beat its own travel would reject
  // ordinary ones — while a scroll's separation barely changes at all.
  const pinching = spread > PINCH_DECISIVE_PX ||
    (spread > PINCH_SLOP_PX && spread > travel);
  // Fitted, the gesture belongs to the remote until a pinch proves otherwise.
  // That is what keeps noVNC's own two-finger scroll working there.
  if (!pinch.claimed && !pinching && view.zoom === 1) return;
  // Zoomed, withholding the MOVE is what stops it leaking through: noVNC banks
  // wheel deltas across gestures until they add up to a scroll step. Muting
  // here would be wrong — a two-finger TAP is still the remote's, and the mute
  // outlives the touchend that would deliver it.
  e.preventDefault();
  e.stopPropagation();
  if (!pinch.claimed && !pinching && travel <= PAN_SLOP_PX) return;
  if (!pinch.claimed) claimPinch();
  const next = clamp(pinch.startZoom * (gap / pinch.startSeparation), 1, maxZoom());
  // Hold the picture point grabbed at gesture start under the live centroid.
  // That zooms about the pinch and follows a drag in one expression, so the
  // view never snaps to the middle of the screen.
  const anchorX = (pinch.startX - pinch.startPanX) / pinch.startZoom;
  const anchorY = (pinch.startY - pinch.startPanY) / pinch.startZoom;
  setView(next, c.x - anchorX * next, c.y - anchorY * next);
}, { capture: true, passive: false });

function endPinch(e) {
  if (pinch === null) return;
  if (e.touches.length >= 2) {
    beginPinch(e.touches, pinch.claimed);
    return;
  }
  // One finger left still belongs to this gesture; the next to land re-anchors.
  if (e.touches.length > 0) return;
  const claimed = pinch.claimed;
  const lastX = pinch.lastX;
  const lastY = pinch.lastY;
  pinch = null;
  if (claimed) e.preventDefault();
  // Deferred: noVNC has not seen this touchend yet. Skipped if another gesture
  // has already begun, because that one owns the mute now.
  setTimeout(() => {
    if (pinch === null) unmute(lastX, lastY);
  }, 0);
}

window.addEventListener("touchend", endPinch, { capture: true, passive: false });
window.addEventListener("touchcancel", endPinch, { capture: true, passive: false });

// ---------------------------------------------------------------------------
// Trackpad mode
// ---------------------------------------------------------------------------
// OFF by default. The default is direct touch: the user taps the thing they
// want, which is what noVNC's own gesture handler does and what feels right on
// a phone.
//
// Trackpad mode is the second mode, for work that needs a pointer the finger
// does not cover: hover, small targets, a precise drag. It consumes every
// touch and drives a virtual cursor, then dispatches ordinary ABSOLUTE mouse
// events at that position onto noVNC's canvas. One dispatch drives both the
// RFB pointer event and noVNC's own cursor canvas, so there is no second dot
// on screen and no noVNC internals are touched.

const CAPTURE_ELEM_ID = "noVNC_mouse_capture_elem";

const trackpad = (() => {
  // The virtual cursor in viewport coordinates. It survives gestures.
  let cx = 0;
  let cy = 0;
  let seeded = false;
  let gesture = null;
  let lastTapEnd = 0;
  let lastTapX = 0;
  let lastTapY = 0;
  let enabled = false;

  // Zoomed in, the canvas overhangs the screen, so clamping against the canvas
  // alone would leave the cursor somewhere nobody can see.
  function visibleRect() {
    const canvas = desktopCanvas();
    if (canvas === null) return null;
    const r = canvas.getBoundingClientRect();
    const left = Math.max(r.left, 0);
    const top = Math.max(r.top, 0);
    const right = Math.min(r.right, window.innerWidth);
    const bottom = Math.min(r.bottom, window.innerHeight);
    if (right <= left || bottom <= top) return null;
    return { left: left, top: top, right: right, bottom: bottom };
  }

  function clampToCanvas() {
    const r = visibleRect();
    if (r === null) return;
    let overflowX = 0;
    let overflowY = 0;
    if (cx < r.left) { overflowX = cx - r.left; cx = r.left; }
    else if (cx > r.right - 1) { overflowX = cx - (r.right - 1); cx = r.right - 1; }
    if (cy < r.top) { overflowY = cy - r.top; cy = r.top; }
    else if (cy > r.bottom - 1) { overflowY = cy - (r.bottom - 1); cy = r.bottom - 1; }
    // Past a visible edge the view moves instead of the cursor stopping, so the
    // whole desktop stays reachable without pinching back out.
    if (overflowX !== 0 || overflowY !== 0) panBy(-overflowX, -overflowY);
  }

  function center() {
    const r = visibleRect();
    if (r === null) return false;
    cx = (r.left + r.right) / 2;
    cy = (r.top + r.bottom) / 2;
    seeded = true;
    return true;
  }

  function seed() {
    if (!seeded) center();
  }

  function dispatchMouse(type, buttons, button) {
    const canvas = desktopCanvas();
    if (canvas === null) return;
    canvas.dispatchEvent(new MouseEvent(type, {
      bubbles: true, cancelable: true, view: window,
      clientX: cx, clientY: cy, buttons: buttons, button: button,
    }));
  }

  function dispatchWheel(dx, dy) {
    const canvas = desktopCanvas();
    if (canvas === null) return;
    canvas.dispatchEvent(new WheelEvent("wheel", {
      bubbles: true, cancelable: true, view: window,
      clientX: cx, clientY: cy, deltaX: dx, deltaY: dy, deltaMode: 0,
    }));
  }

  // noVNC emulates setCapture with a fixed full-viewport div it shows on every
  // mousedown. It tears that down on a real mouseup reaching its window proxy,
  // which a synthetic one cannot be relied on to be. Hiding it after each press
  // is idempotent and costs nothing.
  function clearCaptureElem() {
    const cap = document.getElementById(CAPTURE_ELEM_ID);
    if (cap !== null) cap.style.display = "none";
  }

  // button: 0 left, 2 right. buttons bitmask: 1 left, 2 right — noVNC reads
  // the bitmask.
  function press(buttons, button) {
    seed();
    dispatchMouse("mousedown", buttons, button);
    dispatchMouse("mouseup", 0, button);
    clearCaptureElem();
  }

  function moveBy(dx, dy, buttons) {
    seed();
    cx += dx * POINTER_GAIN;
    cy += dy * POINTER_GAIN;
    clampToCanvas();
    dispatchMouse("mousemove", buttons, 0);
  }

  function touchCentroid(touches) {
    let x = 0;
    let y = 0;
    const n = Math.min(touches.length, 2);
    for (let i = 0; i < n; i++) {
      x += touches[i].clientX;
      y += touches[i].clientY;
    }
    return { x: x / n, y: y / n };
  }

  function reanchor(touches) {
    if (touches.length >= 2) {
      const c = touchCentroid(touches);
      gesture.lastX = c.x;
      gesture.lastY = c.y;
    } else if (touches.length === 1) {
      gesture.lastX = touches[0].clientX;
      gesture.lastY = touches[0].clientY;
    }
  }

  // The left button goes down at the cursor and stays down until the finger
  // lifts. The host is told, so it can answer with a haptic: on a still desktop
  // nothing else marks the moment the button went down.
  function beginHold() {
    gesture.dragging = true;
    seed();
    dispatchMouse("mousedown", 1, 0);
    post({ event: "hold" });
  }

  function cancelHoldTimer() {
    if (gesture === null || gesture.holdTimer === null) return;
    clearTimeout(gesture.holdTimer);
    gesture.holdTimer = null;
  }

  function cancelGesture() {
    if (gesture === null) return;
    cancelHoldTimer();
    if (gesture.dragging) {
      dispatchMouse("mouseup", 0, 0);
      clearCaptureElem();
    }
    gesture = null;
  }

  overlay.addEventListener("touchstart", (e) => {
    e.preventDefault();
    const now = Date.now();
    if (gesture === null) {
      const t = e.touches[0];
      gesture = {
        maxFingers: e.touches.length,
        moved: false,
        scrolled: false,
        dragging: false,
        startX: t ? t.clientX : 0,
        startY: t ? t.clientY : 0,
        lastX: 0,
        lastY: 0,
        holdTimer: null,
      };
      if (e.touches.length === 1 &&
          now - lastTapEnd < DOUBLE_TAP_MS &&
          Math.hypot(t.clientX - lastTapX, t.clientY - lastTapY) < DOUBLE_TAP_SLOP_PX) {
        beginHold();
      } else if (e.touches.length === 1) {
        gesture.holdTimer = setTimeout(() => {
          gesture.holdTimer = null;
          beginHold();
        }, HOLD_MS);
      }
    } else {
      gesture.maxFingers = Math.max(gesture.maxFingers, e.touches.length);
      cancelHoldTimer();
      // A second finger during a held drag: release the button and hand the
      // gesture to the two-finger path, so the button never sticks down.
      if (gesture.dragging && e.touches.length >= 2) {
        dispatchMouse("mouseup", 0, 0);
        clearCaptureElem();
        gesture.dragging = false;
      }
    }
    reanchor(e.touches);
  }, { passive: false });

  overlay.addEventListener("touchmove", (e) => {
    e.preventDefault();
    if (gesture === null) return;
    if (e.touches.length >= 2) {
      const c = touchCentroid(e.touches);
      dispatchWheel((c.x - gesture.lastX) * WHEEL_GAIN, (c.y - gesture.lastY) * WHEEL_GAIN);
      gesture.scrolled = true;
      gesture.lastX = c.x;
      gesture.lastY = c.y;
      return;
    }
    const t = e.touches[0];
    moveBy(t.clientX - gesture.lastX, t.clientY - gesture.lastY, gesture.dragging ? 1 : 0);
    gesture.lastX = t.clientX;
    gesture.lastY = t.clientY;
    if (Math.hypot(t.clientX - gesture.startX, t.clientY - gesture.startY) > TAP_SLOP_PX) {
      gesture.moved = true;
      cancelHoldTimer();
    }
  }, { passive: false });

  function endTouch(e, canceled) {
    e.preventDefault();
    if (gesture === null) return;
    cancelHoldTimer();
    if (e.touches.length > 0) {
      reanchor(e.touches);
      return;
    }
    if (gesture.dragging) {
      dispatchMouse("mouseup", 0, 0);
      clearCaptureElem();
    } else if (!canceled && gesture.maxFingers >= 2) {
      // Two-finger tap is the right click. The overlay eats every touch, so
      // noVNC's own long-press right click never arms.
      if (!gesture.scrolled && !gesture.moved) press(2, 2);
    } else if (!canceled && gesture.maxFingers === 1 && !gesture.moved) {
      // A tap clicks at the CURSOR, not at the touch point. That is the whole
      // idea of the mode.
      press(1, 0);
      lastTapEnd = Date.now();
      lastTapX = gesture.lastX;
      lastTapY = gesture.lastY;
    }
    gesture = null;
  }

  overlay.addEventListener("touchend", (e) => endTouch(e, false), { passive: false });
  overlay.addEventListener("touchcancel", (e) => endTouch(e, true), { passive: false });

  return {
    get enabled() { return enabled; },
    setEnabled(on) {
      if (enabled === on) return;
      enabled = on;
      overlay.hidden = !on;
      if (on) {
        // The agent moves the remote pointer with xdotool, so the virtual
        // cursor and the real one drift apart while the mode is off.
        this.recenter();
      } else {
        cancelGesture();
      }
    },
    cancelGesture: cancelGesture,
    recenter() {
      if (center()) dispatchMouse("mousemove", 0, 0);
    },
  };
})();

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
// One RFB in flight at a time, the last painted frame held over a
// re-handshake, and retries driven by the document's visibility rather than a
// blind timer.
//
// Android pauses the WebView of a backgrounded app, so every trip through
// another app can land the viewer on a dead socket. noVNC detaches its own
// subtree the instant the socket closes, so recovery parks that subtree over
// the emptied target and reports `reconnecting`: a picture on screen, being
// refreshed. Only a recovery the user watched fail drops the picture and
// reports `disconnected`.

const session = {
  rfb: null,
  // The live attempt. A superseded one no longer speaks for the page.
  attempt: null,
  phase: "idle",
  painted: null,
  retry: null,
  password: null,
  started: false,
};

function holdFrame() {
  if (session.painted === null) return;
  held.style.width = screen.style.width;
  held.style.height = screen.style.height;
  held.style.left = screen.style.left;
  held.style.top = screen.style.top;
  held.appendChild(session.painted);
  held.style.display = "block";
  session.painted = null;
}

function releaseFrame() {
  held.style.display = "none";
  held.replaceChildren();
}

function holdingFrame() {
  return held.style.display === "block";
}

function scheduleRetry() {
  if (session.retry !== null || document.visibilityState === "hidden") return;
  session.retry = setTimeout(connect, RETRY_MS);
}

function connect() {
  if (session.retry !== null) {
    clearTimeout(session.retry);
    session.retry = null;
  }
  if (!session.started || session.phase !== "idle") return;
  if (wsUrl === null) {
    post({ event: "state", state: "disconnected" });
    return;
  }
  // A hidden page cannot hold a socket open, so the return to visible is the
  // reconnect — not a timer firing into a suspended document.
  if (document.visibilityState === "hidden") return;

  const warm = holdingFrame();
  session.phase = warm ? "recovering" : "connecting";
  post({ event: "state", state: warm ? "reconnecting" : "connecting" });

  let rfb;
  try {
    rfb = new RFB(screen, wsUrl, {
      credentials: { password: session.password },
      shared: true,
    });
  } catch (_error) {
    // A constructor throw fires no disconnect event, so the failure has to be
    // reported and re-armed here. The error itself is not posted: it can carry
    // the URL, and the URL carries the session token.
    session.phase = "idle";
    releaseFrame();
    post({ event: "state", state: "disconnected" });
    scheduleRetry();
    return;
  }

  const attempt = { rfb: rfb, interrupted: false };
  session.attempt = attempt;
  session.rfb = rfb;
  rfb.scaleViewport = true;
  rfb.background = "#000000";
  // LOAD-BEARING. Do not delete this line, and do not set it back to true.
  //
  // noVNC grabs DOM focus on every click by default. Inside an Android WebView
  // that hands the input connection to the WebView, and the WebView closes the
  // host's soft keyboard. So with this line removed, ONE tap on the desktop
  // makes typing impossible for the rest of the session — and typing on the
  // agent's machine is the whole reason this screen exists: the user opens it
  // to sign in to a site the agent cannot. The failure is silent: the picture
  // still moves, the keyboard just never comes back.
  //
  // Nothing is lost by switching it off. The page needs no DOM focus, because
  // it never reads the keyboard itself: every key arrives from the host
  // through `agents.typeText` and `agents.sendKeysym`.
  rfb.focusOnClick = false;
  // Deliberately NOT enabling continuous updates. Our x11vnc is 0.9.16: the
  // binary has no such code, it never sends EndOfContinuousUpdates, and a
  // client that sends message 150 anyway has its connection CLOSED (measured).
  // noVNC only sends it after the server offers it, so leaving this alone is
  // what keeps the view alive. Never force `_enabledContinuousUpdates`.

  rfb.addEventListener("connect", () => {
    if (session.attempt !== attempt) return;
    releaseFrame();
    session.painted = screen.firstElementChild;
    session.phase = "live";
    reflow();
    post({ event: "state", state: "connected" });
  });

  rfb.addEventListener("clipboard", (e) => {
    if (session.attempt !== attempt) return;
    const text = e.detail && e.detail.text;
    if (typeof text === "string") post({ event: "clipboard", text: text });
  });

  rfb.addEventListener("disconnect", () => {
    if (session.attempt !== attempt) return;
    session.attempt = null;
    session.rfb = null;
    // The mute belonged to the socket that just died. Left standing it would
    // stop the next gesture muting the NEW connection, and every pinch would
    // leak through to the agent's desktop as a Ctrl+wheel.
    mutedViewOnly = null;
    const wasLive = session.phase === "live";
    session.phase = "idle";
    if (wasLive) holdFrame();
    // Only a recovery the user watched fail earns the placeholder: that is the
    // box refusing. A live drop gets its one warm attempt, and a close the app
    // walked away from is another app switch, so its picture is kept too and
    // the return to visible re-handshakes.
    const refused = !wasLive && !attempt.interrupted;
    if (holdingFrame() && !refused) {
      connect();
      return;
    }
    releaseFrame();
    post({ event: "state", state: "disconnected" });
    scheduleRetry();
  });
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    connect();
  } else if (session.attempt !== null) {
    session.attempt.interrupted = true;
  }
});

// ---------------------------------------------------------------------------
// Host API
// ---------------------------------------------------------------------------
// Everything the host can ask the page to do. Keyboard and clipboard work only
// while the socket is live: a key handed to a dead page is dropped, and there
// is nothing to replay it from.

function liveRfb() {
  return session.phase === "live" ? session.rfb : null;
}

function tapKey(rfb, keysym, code) {
  rfb.sendKey(keysym, code === undefined ? null : code, true);
  rfb.sendKey(keysym, code === undefined ? null : code, false);
}

function ctrlChord(rfb, keysym, code) {
  rfb.sendKey(KEYSYM_CTRL_L, "ControlLeft", true);
  rfb.sendKey(keysym, code, true);
  rfb.sendKey(keysym, code, false);
  rfb.sendKey(KEYSYM_CTRL_L, "ControlLeft", false);
}

window.agents = {
  // The one way in. The password never rides the page URL, so it cannot land
  // in a WebView history entry or a log line — and it is never posted back.
  start(password) {
    session.password = typeof password === "string" ? password : null;
    if (session.started) return;
    session.started = true;
    connect();
  },

  // A rotated secret. The executor re-handshakes with the box on its own and
  // rotates the per-view password each time, so the page has to be told before
  // it dials again — the old one would be refused.
  setPassword(password) {
    session.password = typeof password === "string" ? password : null;
    // Sitting idle under a held frame, the new secret is the reason to retry.
    if (session.started && session.phase === "idle") connect();
  },

  // "Try again" after a failed recovery.
  reconnect() {
    connect();
  },

  zoomToFit: zoomToFit,

  isZoomed() {
    return view.zoom > 1;
  },

  setTrackpad(on) {
    trackpad.setEnabled(on === true);
  },

  recenterPointer() {
    trackpad.recenter();
  },

  // Latin-1 code points ARE their X11 keysyms; everything above rides the X11
  // Unicode range.
  typeText(text) {
    const rfb = liveRfb();
    if (rfb === null || typeof text !== "string") return;
    for (const ch of text) {
      const cp = ch.codePointAt(0);
      tapKey(rfb, cp < 0x100 ? cp : cp + KEYSYM_UNICODE_BASE);
    }
  },

  sendKeysym(keysym) {
    const rfb = liveRfb();
    if (rfb === null || typeof keysym !== "number") return;
    tapKey(rfb, keysym);
  },

  // Paste stages the text in the remote clipboard over RFB and then fires ONE
  // Ctrl+V chord. No per-character synthesis, and no delay is needed: the cut
  // text and the chord travel the same socket in order.
  pasteText(text) {
    const rfb = liveRfb();
    if (rfb === null || typeof text !== "string" || text.length === 0) return;
    rfb.clipboardPasteFrom(text);
    ctrlChord(rfb, KEYSYM_V, "KeyV");
  },

  // Copy fires one Ctrl+C. The text itself comes back out of band, as the
  // server's new cut text, and is forwarded as a `clipboard` message.
  copySelection() {
    const rfb = liveRfb();
    if (rfb === null) return;
    ctrlChord(rfb, KEYSYM_C, "KeyC");
  },

  // The canvas is drawn from socket data, never from cross-origin pixels, so
  // it is not tainted. Gated on `live`, so the black connecting screen can
  // never be saved as a screenshot.
  screenshot() {
    const canvas = desktopCanvas();
    if (session.phase !== "live" || canvas === null ||
        canvas.width === 0 || canvas.height === 0) {
      return;
    }
    post({ event: "screenshot", data: canvas.toDataURL("image/png") });
  },
};

// The page is up. The host answers with `agents.start(password)`.
post({ event: "ready" });
