"""Scene builders every episode shares: the serif card and the end card."""
from .core import esc, logo, wordmark


def card(ep, cid, start, end, lines, bg=None, size=None, t0=0.1, color="@INK@", push=1.035):
    """Serif card: one to three lines, words rise in, slow push. bg: None (canvas) or a colour.
    In 9:16 pass shorter lines (about 3 words each); the block centres in the safe band."""
    fmt = ep.fmt
    size = size or fmt.pick(112, 120)
    n = len(lines)
    lh = round(size * 1.12)
    top = round(fmt.cy - n * lh / 2)
    divs = "".join(
        f'<div class="card-line serif" id="{cid}-l{i}" style="top:{top + i * lh}px;font-size:{size}px;'
        f'line-height:{lh}px;color:{color}">{esc(t)}</div>' for i, t in enumerate(lines))
    bgdiv = f'<div id="{cid}-bg" class="fill" style="background:{bg}"></div>' if bg else ""
    js = "".join(f"  hfReveal(tl, '#{cid}-l{i}', {t0 + i * 0.45:.2f});\n" for i in range(n))
    js += (f"  tl.fromTo('#{cid}-txt', {{ scale: 1 }}, {{ scale: {push}, duration: {end - start:.2f}, "
           f"ease: 'none' }}, 0);\n")
    css = f"#{cid}-txt {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}"
    ep.add(cid, start, end, css, f'    {bgdiv}<div id="{cid}-txt" class="fill">{divs}</div>', js)


def end_card(ep, cid, start, end, bg="@TAN@"):
    """Official lockup only: repo assets/logo.svg + assets/wordmark.svg (recoloured to ink,
    slogan keeps its own fill-opacity), chuk.chat in Liberation Mono. Never re-typed."""
    fmt = ep.fmt
    mark_h = fmt.pick(440, 420)
    wm_w = fmt.pick(900, 900)
    wm_svg, wm_h = wordmark(f"{cid}-wm", "@INK@", wm_w)
    gap1, gap2, url_h = 40, 58, 40
    url_size = fmt.pick(30, 36)
    total = mark_h + gap1 + wm_h + gap2 + url_h
    top = round(fmt.cy - total / 2)
    css = f"""
#{cid}-bg {{ background: {bg}; }}
#{cid}-lock {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
#{cid}-mark {{ position: absolute; left: {(fmt.W - mark_h) / 2:.1f}px; top: {top}px; width: {mark_h}px; height: {mark_h}px; color: @INK@; }}
#{cid}-wm {{ position: absolute; display: block; left: {(fmt.W - wm_w) / 2:.1f}px; top: {top + mark_h + gap1}px; width: {wm_w}px; height: {wm_h}px; }}
#{cid}-url {{ top: {top + mark_h + gap1 + wm_h + gap2:.1f}px; font-family: 'LiberationMono', monospace; font-size: {url_size}px; line-height: {url_h}px; color: @SOFT@; }}
"""
    body = f"""
    <div id="{cid}-bg" class="fill"></div>
    <div id="{cid}-lock" class="fill">
      {logo(id_=f'{cid}-mark')}
      {wm_svg}
      <div class="card-line" id="{cid}-url">chuk.chat</div>
    </div>
"""
    js = f"""
  tl.fromTo('#{cid}-mark', {{ clipPath: 'inset(100% 0 0 0)', y: 30 }}, {{ clipPath: 'inset(0% 0 0 0)', y: 0, duration: 0.7, ease: 'power3.out' }}, 0.05);
  tl.fromTo('#{cid}-wm', {{ clipPath: 'inset(0 100% 0 0)' }}, {{ clipPath: 'inset(0 0% 0 0)', duration: 0.8, ease: 'power3.inOut' }}, 0.6);
  tl.fromTo('#{cid}-url', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.5 }}, 1.7);
  tl.fromTo('#{cid}-lock', {{ scale: 1 }}, {{ scale: 1.015, duration: {end - start:.2f}, ease: 'none' }}, 0);
"""
    ep.add(cid, start, end, css, body, js)
