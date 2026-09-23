// Content script: turn the visible page into something small enough to put in a
// prompt, and hand back geometry so the service worker can aim real input at it.
//
// Runs in every frame at document_start. It stays passive until the service
// worker asks; nothing is sent anywhere on its own.

(() => {
  const REF_ATTR = "data-cowork-ref";
  const MAX_NODES = 400;
  const MAX_TEXT = 120;

  let counter = 0;
  const byRef = new Map(); // ref -> Element
  let previous = new Map(); // ref -> serialised node, for diffing

  const INTERACTIVE = new Set([
    "a", "button", "input", "select", "textarea", "summary", "option", "label",
  ]);

  function isVisible(el) {
    const rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) return false;
    if (rect.bottom < 0 || rect.right < 0) return false;
    if (rect.top > innerHeight || rect.left > innerWidth) return false;
    const style = getComputedStyle(el);
    if (style.visibility === "hidden" || style.display === "none") return false;
    return style.opacity !== "0";
  }

  function role(el) {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit;
    const tag = el.tagName.toLowerCase();
    if (tag === "a") return el.hasAttribute("href") ? "link" : "generic";
    if (tag === "input") return (el.type || "text") === "submit" ? "button" : `input:${el.type || "text"}`;
    if (INTERACTIVE.has(tag)) return tag;
    if (/^h[1-6]$/.test(tag)) return "heading";
    return tag;
  }

  function name(el) {
    const label =
      el.getAttribute("aria-label") ||
      el.getAttribute("alt") ||
      el.getAttribute("title") ||
      (el.labels && el.labels[0] && el.labels[0].textContent) ||
      el.textContent ||
      "";
    return label.replace(/\s+/g, " ").trim().slice(0, MAX_TEXT);
  }

  function interactive(el) {
    if (INTERACTIVE.has(el.tagName.toLowerCase())) return true;
    if (el.hasAttribute("onclick") || el.hasAttribute("tabindex")) return true;
    const r = el.getAttribute("role");
    return r === "button" || r === "link" || r === "menuitem" || r === "tab" || r === "checkbox";
  }

  function build(full) {
    counter = 0;
    byRef.clear();
    const nodes = [];
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT);
    while (walker.nextNode() && nodes.length < MAX_NODES) {
      const el = walker.currentNode;
      const act = interactive(el);
      const label = name(el);
      // Keep what a reader needs: anything clickable, and text-bearing landmarks.
      if (!act && !(label && /^(h[1-6]|heading|p|li|td|th)$/.test(role(el)))) continue;
      if (!isVisible(el)) continue;
      const ref = `e${++counter}`;
      el.setAttribute(REF_ATTR, ref);
      byRef.set(ref, el);
      const box = el.getBoundingClientRect();
      const node = { ref, role: role(el), name: label };
      if (el.value) node.value = String(el.value).slice(0, MAX_TEXT);
      if (el.placeholder) node.placeholder = el.placeholder.slice(0, MAX_TEXT);
      if (act) node.interactive = true;
      node.box = [Math.round(box.x), Math.round(box.y), Math.round(box.width), Math.round(box.height)];
      nodes.push(node);
    }
    const frame = {
      url: location.href,
      title: document.title,
      viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio },
      scroll: { x: Math.round(scrollX), y: Math.round(scrollY) },
      truncated: nodes.length >= MAX_NODES,
    };

    // Diffing, the way OpenAI's extension does it: a second look at a page that
    // barely moved should not cost a second full page of tokens. `full` asks
    // for everything anyway, and a navigation resets the baseline by itself.
    const current = new Map(nodes.map((n) => [n.ref, JSON.stringify(n)]));
    if (!full && previous.size && previous.get("__url__") === location.href) {
      const changed = [];
      for (const [ref, json] of current) {
        if (previous.get(ref) !== json) changed.push(JSON.parse(json));
      }
      const gone = [...previous.keys()].filter((ref) => ref !== "__url__" && !current.has(ref));
      previous = current;
      previous.set("__url__", location.href);
      return { ...frame, diff: true, nodes: changed, removed: gone, total: current.size - 1 };
    }
    previous = current;
    previous.set("__url__", location.href);
    return { ...frame, diff: false, nodes };
  }

  function resolve(address) {
    if (!address || address.kind === "focus") return document.activeElement;
    if (address.kind === "selector") return document.querySelector(address.selector);
    if (address.kind === "point") return document.elementFromPoint(address.point[0], address.point[1]);
    const ref = address.ref;
    const el = byRef.get(ref);
    if (el && el.isConnected) return el;
    return document.querySelector(`[${REF_ATTR}="${CSS.escape(ref)}"]`);
  }

  function locate(address) {
    const el = resolve(address);
    if (!el) return null;
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    const box = el.getBoundingClientRect();
    return {
      x: box.x + box.width / 2,
      y: box.y + box.height / 2,
      box: [box.x, box.y, box.width, box.height],
      tag: el.tagName.toLowerCase(),
      editable: el.isContentEditable || /^(input|textarea)$/.test(el.tagName.toLowerCase()),
    };
  }

  function readable() {
    // What the user's own chat about this page gets: text, not markup.
    const source = document.querySelector("main, article") || document.body;
    const text = (source ? source.innerText : "").replace(/\n{3,}/g, "\n\n").trim();
    return { url: location.href, title: document.title, text: text.slice(0, 40000) };
  }

  const runtime = (globalThis.browser ?? globalThis.chrome).runtime;
  runtime.onMessage.addListener((msg, _sender, reply) => {
    if (!msg || msg.channel !== "agents") return;
    try {
      if (msg.op === "snapshot") reply({ ok: true, data: build(Boolean(msg.full)) });
      else if (msg.op === "locate") reply({ ok: true, data: locate(msg.address) });
      else if (msg.op === "readable") reply({ ok: true, data: readable() });
      else if (msg.op === "selection") reply({ ok: true, data: { text: String(getSelection() || "") } });
      else if (msg.op === "scroll") {
        scrollBy({ top: msg.dy || 0, left: msg.dx || 0, behavior: "instant" });
        reply({ ok: true, data: { x: Math.round(scrollX), y: Math.round(scrollY) } });
      } else reply({ ok: false, error: `content script: unknown op ${msg.op}` });
    } catch (err) {
      reply({ ok: false, error: String(err && err.message ? err.message : err) });
    }
    return true;
  });
})();
