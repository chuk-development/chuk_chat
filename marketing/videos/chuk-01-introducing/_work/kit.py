"""Shared building blocks for the frame generator: page wrapper, app window
markup, deterministic JS runtime. Frames are written as HyperFrames
sub-compositions (one <template> each, styles and scripts inside)."""
import html
import os
import re

from icons import icon

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
UI_CSS = open(os.path.join(HERE, "ui.css"), encoding="utf-8").read()
GSAP = "https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"

# App window placement (logical px x zoom) used by every desktop world.
APP_X, APP_Y, ZOOM = 85, 50, 1.75
APP_W, APP_H = 1000, 560


def esc(s):
    return html.escape(s, quote=False)


def words(text, cls="w"):
    """Wrap each word (and its trailing space) in a span for streaming."""
    parts = re.findall(r"\S+\s*", text)
    return "".join(f'<span class="{cls}">{esc(p)}</span>' for p in parts)


def app_xy(lx, ly):
    """Logical app coordinates -> frame px."""
    return APP_X + lx * ZOOM, APP_Y + ly * ZOOM


RUNTIME = r"""
  var R = document.querySelector('[data-composition-id="' + ID + '"]');
  var $ = function (s) { return R.querySelector(s); };
  var $$ = function (s) { return Array.prototype.slice.call(R.querySelectorAll(s)); };
  var tl = gsap.timeline({ paused: true });
  var ups = [];
  function c01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function setText(el, s) { if (el.__v !== s) { el.textContent = s; el.__v = s; } }
  function type(el, text, t0, cps) {
    ups.push(function (t) {
      var n = Math.floor((t - t0) * cps);
      n = n < 0 ? 0 : n > text.length ? text.length : n;
      setText(el, text.slice(0, n));
    });
    return t0 + text.length / cps;
  }
  function stream(el, t0, wps, fade) {
    var ws = Array.prototype.slice.call(el.querySelectorAll('.w'));
    fade = fade || 0.16;
    var firsts = [];
    ws.forEach(function (w, i) {
      var li = w.parentNode && w.parentNode.tagName === 'LI' ? w.parentNode : null;
      if (li && li.querySelector('.w') === w) firsts.push([li, i]);
    });
    ups.push(function (t) {
      for (var i = 0; i < ws.length; i++) {
        var o = c01((t - t0 - i / wps) / fade);
        if (ws[i].__o !== o) { ws[i].style.opacity = o; ws[i].__o = o; }
      }
      for (var j = 0; j < firsts.length; j++) firsts[j][0].style.setProperty('--bo', ws[firsts[j][1]].__o);
    });
    return t0 + ws.length / wps;
  }
  function spin(el) {
    ups.push(function (t) { el.style.transform = 'rotate(' + ((t * 460) % 360).toFixed(1) + 'deg)'; });
  }
  function showBetween(el, t0, t1) {
    ups.push(function (t) { var on = t >= t0 && t < t1; var d = on ? '' : 'none'; if (el.__d !== d) { el.style.display = d; el.__d = d; } });
  }
  function caret(el, t0, t1, hideAfter) {
    ups.push(function (t) {
      var v;
      if (hideAfter != null && t >= hideAfter) v = 0;
      else if (t >= t0 && t <= t1) v = 1;
      else v = (Math.floor(t / 0.5) % 2 === 0) ? 1 : 0;
      el.style.opacity = v;
    });
  }
  function rng(seed) {
    return function () {
      seed |= 0; seed = seed + 0x6D2B79F5 | 0;
      var q = Math.imul(seed ^ seed >>> 15, 1 | seed);
      q = q + Math.imul(q ^ q >>> 7, 61 | q) ^ q;
      return ((q ^ q >>> 14) >>> 0) / 4294967296;
    };
  }
  function scramble(els, ts, dur, seed) {
    var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var r = rng(seed), nodes = [], total = 0;
    els.forEach(function (el) {
      var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), n;
      while ((n = w.nextNode())) {
        var o = n.nodeValue;
        if (!o.trim().length) continue;
        var c = o.replace(/\S/g, function () { return B64.charAt(Math.floor(r() * 64)); });
        nodes.push({ n: n, o: o, c: c, off: total });
        total += o.length;
      }
    });
    ups.push(function (t) {
      var k = c01((t - ts) / dur), cut = Math.floor(total * k);
      for (var i = 0; i < nodes.length; i++) {
        var d = nodes[i];
        var l = Math.max(0, Math.min(d.o.length, cut - d.off));
        var v = d.c.slice(0, l) + d.o.slice(l);
        if (d.n.nodeValue !== v) d.n.nodeValue = v;
      }
    });
  }
  function rise(sel, t, opt) {
    opt = opt || {};
    var el = typeof sel === 'string' ? $(sel) : sel;
    tl.fromTo(el, { opacity: 0, y: opt.y == null ? 14 : opt.y },
      { opacity: 1, y: 0, duration: opt.d || 0.45, ease: opt.ease || 'power3.out' }, t);
  }
  function fadeIn(sel, t, d) {
    var el = typeof sel === 'string' ? $(sel) : sel;
    tl.fromTo(el, { opacity: 0 }, { opacity: 1, duration: d || 0.3, ease: 'power1.out' }, t);
  }
  function fadeOut(sel, t, d) {
    var el = typeof sel === 'string' ? $(sel) : sel;
    tl.fromTo(el, { opacity: 1 }, { opacity: 0, duration: d || 0.25, ease: 'power1.in', immediateRender: false }, t);
  }
  function headline(t) {
    var eb = $('.hb-eyebrow');
    if (eb) tl.fromTo(eb, { opacity: 0, y: 12 }, { opacity: 1, y: 0, duration: 0.4, ease: 'power3.out' }, t);
    $$('.hb-title .wd').forEach(function (w, i) {
      tl.fromTo(w, { opacity: 0, y: 44 }, { opacity: 1, y: 0, duration: 0.5, ease: 'power3.out' }, t + 0.04 + i * 0.04);
    });
  }
  function headOut(t) {
    tl.fromTo($('.hb'), { opacity: 1, y: 0 }, { opacity: 0, y: -70, duration: 0.3, ease: 'power2.in', immediateRender: false }, t);
  }
  function winIn(sel, t) {
    tl.fromTo($(sel), { y: 1120 }, { y: 0, duration: 0.5, ease: 'power3.out' }, t);
  }
  function cursorPath(cur, pts) {
    // pts: [[t, x, y, dur?], ...]; the first point is the start position.
    tl.fromTo(cur, { x: pts[0][1], y: pts[0][2] }, { x: pts[0][1], y: pts[0][2], duration: 0.01 }, 0);
    for (var i = 1; i < pts.length; i++) {
      var d = pts[i][3] || 0.45;
      tl.fromTo(cur, { x: pts[i - 1][1], y: pts[i - 1][2] },
        { x: pts[i][1], y: pts[i][2], duration: d, ease: 'power2.inOut', immediateRender: false }, pts[i][0] - d);
    }
  }
  function press(el, t, lo, origin) {
    var o = origin ? { transformOrigin: origin } : {};
    tl.fromTo(el, Object.assign({ scale: 1 }, o), Object.assign({ scale: lo, duration: 0.08, ease: 'power2.in', immediateRender: false }, o), t - 0.08);
    tl.fromTo(el, Object.assign({ scale: lo }, o), Object.assign({ scale: 1, duration: 0.3, ease: 'back.out(3)', immediateRender: false }, o), t);
  }
  function click(cur, rip, t, target) {
    press(cur, t, 0.86, '6px 4px');
    if (target) press(typeof target === 'string' ? $(target) : target, t, 0.93);
    if (rip) {
      tl.fromTo(rip, { scale: 0.3, opacity: 0 }, { scale: 0.3, opacity: 0.9, duration: 0.01, immediateRender: false }, t);
      tl.fromTo(rip, { scale: 0.3, opacity: 0.9 }, { scale: 1.3, opacity: 0, duration: 0.5, ease: 'power2.out', immediateRender: false }, t + 0.01);
    }
  }
"""

FINISH = r"""
  var drv = { t: 0 };
  tl.to(drv, { t: DUR, duration: DUR, ease: 'none', onUpdate: function () {
    for (var i = 0; i < ups.length; i++) ups[i](drv.t);
  } }, 0);
  for (var i = 0; i < ups.length; i++) ups[i](0);
  window.__timelines[ID] = tl;
"""

CURSOR_SVG = (
    '<svg viewBox="0 0 34 48" aria-hidden="true"><path d="M4 3 L4 38 L12.5 30 L18.5 44 L24 41.6 '
    'L18 28 L29.5 28 Z" fill="#1E1D19" stroke="#FFFFFF" stroke-width="2.6" stroke-linejoin="round"/></svg>'
)


def cursor(prefix):
    return (f'<div class="ripple {prefix}-rip"></div>'
            f'<div class="cursor {prefix}-cur">{CURSOR_SVG}</div>')


def page(fid, dur, css, body, js, extra_head=""):
    names = iter(["ground", "stage", "layer3", "layer4"])
    body = re.sub(r'<div class="clip ', lambda m: f'<div id="f{fid}-{next(names)}" class="clip ', body)
    return f"""<template>
  <style>
{UI_CSS}
    #root {{ position: absolute; inset: 0; overflow: hidden; background: transparent; }}
{css}
  </style>
  <script src="{GSAP}"></script>
  <div id="root" data-composition-id="{fid}" data-start="0" data-duration="{dur}" data-width="1920" data-height="1080">
{body}
  </div>
  <script>
(function () {{
  var ID = "{fid}", DUR = {dur};
{RUNTIME}
{js}
{FINISH}
}})();
  </script>
</template>
"""


def write(fid, content):
    out = os.path.join(PROJECT, "compositions", "frames", f"{fid}.html")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(content)
    return out


# ---------- app window pieces ----------

def chrome():
    return (f'<span class="a-menu">{icon("h-menu01", "z24")}</span>'
            f'<span class="a-rail"><span>{icon("h-pencil-edit02", "z24")}</span>'
            f'<span>{icon("h-image01", "z24")}</span></span>')


def composer(field_html='Ask me anything !', pill_html=None, extra="", foot_extra=""):
    pill = pill_html or f'{icon("h-flash", "z15")}<b>Fast</b>{icon("h-arrow-down01", "z12 a-dn")}'
    return f"""<div class="a-foot">
      <div class="a-composer">{extra}
        <div class="a-field">{field_html}</div>
        <div class="a-row">
          <span class="a-btn a-plus">{icon("h-plus-sign", "z24")}</span>
          <span class="a-grow"></span>
          <span class="a-pill">{pill}</span>
          <span class="a-btn a-mic">{icon("h-mic02", "z22")}</span>
          <span class="a-send">{icon("h-send-horizontal", "z26")}</span>
        </div>
      </div>
      <p class="a-disc">You're chatting with an AI/LLM — it can be wrong. Check key info.</p>{foot_extra}
    </div>"""


def acts():
    return (f'<div class="a-acts"><span class="a-act"><span>{icon("h-copy01", "z18")}</span>'
            f'<span>{icon("h-refresh", "z18")}</span><span>{icon("h-alt-route", "i18")}</span></span></div>')


def tl_head(running, meta, cls):
    """Timeline head that swaps from a running label (spinner) to the meta line."""
    return (f'<p class="a-tl-head {cls}-head">'
            f'<span class="sw {cls}-run"><i class="spin {cls}-spin"></i>{esc(running)}{icon("h-arrow-down01", "z16")}</span>'
            f'<span class="sw {cls}-done">{esc(meta)}{icon("h-arrow-right01", "z16")}</span></p>')


def step(kind, name=None, detail=None, cls=""):
    ic = icon("h-search01" if kind == "search" else "h-flash", "z14")
    label = "Searched" if kind == "search" else f"Ran {esc(name)}"
    det = f"<b>{esc(detail)}</b>" if detail else ""
    return f'<div class="a-step {cls}"><span class="a-badge">{ic}</span><span class="a-step-t">{label}{det}</span></div>'


def art_card(ic, title, sub, cls=""):
    return (f'<div class="a-art {cls}"><span class="a-art-tile">{icon(ic, "i20")}</span>'
            f'<span class="a-art-txt"><b>{esc(title)}</b><small>{esc(sub)}</small></span>'
            f'<span class="a-art-btn">Download</span><span class="a-art-btn">Open</span></div>')


def panel_head(ic, title, typ):
    return f"""<div class="a-ph">
          {icon(ic, "i18 a-ph-doc")}
          <span class="a-ph-title"><span class="a-ph-tt">{esc(title)}</span></span>
          <span class="a-type">{esc(typ)}</span>
          <span class="a-seg"><span class="on">{icon("h-eye", "i14")}Preview</span><span>{icon("h-source-code", "z14")}Code</span></span>
          <span class="a-ph-ic"><span>{icon("h-history", "i18")}</span><span>{icon("h-copy01", "z18")}</span><span>{icon("h-download01", "z18")}</span><span>{icon("h-cancel01", "z18")}</span></span>
        </div>"""


def panel_foot():
    return f'<div class="a-pf"><b>Version</b><span class="a-ver">v1{icon("h-arrow-down01", "z16")}</span></div>'


def headband(eyebrow, title, extra_cls=""):
    """Headline card. A "|" in the title forces a line break (each line is a block)."""
    lines = []
    for ln in title.split("|"):
        wds = " ".join(f'<span class="wd">{esc(w)}</span>' for w in ln.split())
        lines.append(f'<span class="hb-ln">{wds}</span>' if "|" in title else wds)
    return (f'<div class="hb {extra_cls}"><p class="hb-eyebrow">{esc(eyebrow)}</p>'
            f'<h2 class="hb-title">{"".join(lines) if "|" in title else lines[0]}</h2></div>')
