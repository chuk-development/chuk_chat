#!/usr/bin/env node
// Generates compositions/frames/*.html for "2 a.m." from shared snippets.
//   node tools/build-frames.mjs
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { GSAP, FONTS_CSS, skyCSS, skyHTML, skyJS, ENGINE_SRC, ICON, FRAMES, rng } from "./lib.mjs";
import { TAPES, CLOCKS } from "./tapes.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "compositions/frames");
mkdirSync(OUT, { recursive: true });
const F = Object.fromEntries(FRAMES.map((f) => [f.id, f]));

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function frameFile({ id, css, html, js }) {
  return `<template>
  ${GSAP}
  <style>
${FONTS_CSS}
    #root { position: absolute; inset: 0; overflow: hidden; }
${css}
  </style>
  <div id="root" data-composition-id="${id}" data-width="1920" data-height="1080">
      ${html}
  </div>
  <script>
    (function () {
${js}
    })();
  </script>
</template>
`;
}

// ------------------------------------------------------------------ night field
// Global push on the clock + field group: 1.000 -> 1.035 over 0..28.6 s (global).
const PUSH_END = F["03-who-reads"].start;
function groupPushJS(p) {
  return `
      function ${p}Push(G) {
        var x = Math.max(0, Math.min(1, G / ${PUSH_END}));
        var e = x * x * (3 - 2 * x);
        return 1 + 0.035 * e;
      }`;
}

function fieldCSS(p) {
  return `
.${p}-layer { position: absolute; inset: 0; }
.${p}-group { position: absolute; inset: 0; transform-origin: 960px 540px; }
.${p}-clock { position: absolute; left: 0; right: 0; top: 318px; height: 90px; }
.${p}-ck { position: absolute; left: 0; right: 0; top: 0; text-align: center;
  font-family: "Chuk Chat Mono"; font-weight: 300; font-size: 66px; line-height: 90px; letter-spacing: 0.04em;
  color: #AEB6CE; }
.${p}-field { position: absolute; left: 150px; top: 524px; width: 1620px; min-height: 160px; box-sizing: border-box;
  padding: 40px 150px 40px 64px; border-radius: 48px; border: 2px solid rgba(232, 228, 216, 0.2);
  background: rgba(8, 12, 26, 0.5); }
.${p}-line { font-family: "Chuk Chat Mono"; font-weight: 400; font-size: 60px; line-height: 79px; color: #F6F3EC;
  white-space: pre-wrap; overflow-wrap: break-word; min-height: 79px; }
.${p}-text { }
.${p}-sel { background: rgba(217, 119, 87, 0.42); border-radius: 6px; }
.${p}-caret { display: inline-block; width: 5px; height: 64px; margin-left: 3px; vertical-align: -12px;
  border-radius: 2px; background: #D97757; }
.${p}-send { position: absolute; right: 36px; top: 38px; width: 80px; height: 80px; border-radius: 50%;
  display: flex; align-items: center; justify-content: center; background: rgba(232, 228, 216, 0.07);
  color: rgba(232, 228, 216, 0.28); }
.${p}-send svg { width: 36px; height: 36px; }`;
}

function fieldHTML(p, clockValues, dur) {
  const cks = clockValues
    .map((v, i) => `<div class="${p}-ck" id="${p}-ck${i}" data-layout-allow-overlap${i === 0 ? "" : ' style="opacity:0"'}>${v}</div>`)
    .join("");
  return `<div class="clip ${p}-layer" id="${p}-content" data-start="0" data-duration="${dur}" data-track-index="1">
        <div class="${p}-group" id="${p}-group">
          <div class="${p}-clock">${cks}</div>
          <div class="${p}-field" id="${p}-field">
            <div class="${p}-line"><span class="${p}-text" id="${p}-text"></span><span class="${p}-caret" id="${p}-caret"></span></div>
            <div class="${p}-send" id="${p}-send">${ICON.send}</div>
          </div>
        </div>
      </div>`;
}

function clockJS(p, rolls) {
  // rolls: [[t, value], ...]; span i enters at rolls[i][0]
  let s = "";
  for (let i = 0; i < rolls.length; i++) {
    s += `
      tl.set("#${p}-ck${i}", { y: ${i === 0 ? 0 : 30}, opacity: ${i === 0 ? 1 : 0} }, 0);`;
  }
  for (let i = 1; i < rolls.length; i++) {
    const t = rolls[i][0];
    s += `
      tl.to("#${p}-ck${i - 1}", { y: -30, opacity: 0, duration: 0.42, ease: "power2.in" }, ${t.toFixed(3)});
      tl.fromTo("#${p}-ck${i}", { y: 30, opacity: 0 }, { y: 0, opacity: 1, duration: 0.5, ease: "power2.out", immediateRender: false }, ${(t + 0.1).toFixed(3)});`;
  }
  return s;
}

function typingFrame(id, p, extraCSS = "", extraHTML = "", extraJS = "") {
  const f = F[id];
  const tape = TAPES[id];
  const rolls = CLOCKS[id];
  const css = skyCSS(p) + fieldCSS(p) + extraCSS;
  const html = skyHTML(p, f.dur) + "\n      " + fieldHTML(p, rolls.map((r) => r[1]), f.dur) + extraHTML;
  const js = `
${ENGINE_SRC}
${skyJS(p, f.start)}
${groupPushJS(p)}
      var TAPE = ${JSON.stringify(tape)};
      var ev = hfTape(TAPE.ops, TAPE.seed);
      var textEl = document.getElementById("${p}-text");
      var caretEl = document.getElementById("${p}-caret");
      var sendEl = document.getElementById("${p}-send");
      var groupEl = document.getElementById("${p}-group");
      function render(t) {
        var G = ${f.start} + t;
        ${p}Sky(t);
        groupEl.style.transform = "scale(" + ${p}Push(G).toFixed(5) + ")";
        var e = hfAt(ev, t);
        if (textEl.textContent !== e.text) textEl.textContent = e.text;
        textEl.className = e.k === "sel" ? "${p}-text ${p}-sel" : "${p}-text";
        caretEl.style.opacity = hfCaret(ev, t, G) ? "1" : "0";
        var on = e.text.length > 0;
        sendEl.style.background = on ? "rgba(232, 228, 216, 0.15)" : "rgba(232, 228, 216, 0.07)";
        sendEl.style.color = on ? "rgba(232, 228, 216, 0.72)" : "rgba(232, 228, 216, 0.28)";
      }
      var tl = gsap.timeline({ paused: true });
      var drv = { t: 0 };
      tl.to(drv, { t: ${f.dur}, duration: ${f.dur}, ease: "none", onUpdate: function () { render(drv.t); } }, 0);
${clockJS(p, rolls)}
${extraJS}
      render(0);
      window.__timelines["${id}"] = tl;`;
  return frameFile({ id, css, html, js });
}

// ------------------------------------------------------------------ 01 hook
function frame01() {
  return typingFrame("01-hook", "f1");
}

// ------------------------------------------------------------------ 02 questions
function frame02() {
  return typingFrame("02-questions", "f2");
}

// ------------------------------------------------------------------ 03 who reads
function frame03() {
  const id = "03-who-reads";
  const p = "f3";
  const f = F[id];
  const rolls = CLOCKS[id];
  const css =
    skyCSS(p) +
    fieldCSS(p) +
    `
.${p}-say { position: absolute; left: 0; right: 0; top: 0; bottom: 0; }
.${p}-lines { position: absolute; left: 160px; right: 160px; top: 430px; text-align: center;
  font-family: "Chuk Sans"; font-weight: 300; font-size: 88px; line-height: 104px; letter-spacing: -0.028em; color: #F6F3EC; }
.${p}-l { display: block; }
.${p}-q { position: absolute; left: 160px; right: 160px; top: 474px; text-align: center;
  font-family: "Chuk Sans"; font-weight: 300; font-size: 104px; line-height: 120px; letter-spacing: -0.03em; color: #F6F3EC; }`;
  const html =
    skyHTML(p, f.dur) +
    "\n      " +
    fieldHTML(p, rolls.map((r) => r[1]), f.dur) +
    `
      <div class="clip ${p}-say" id="${p}-say" data-start="0" data-duration="${f.dur}" data-track-index="2">
        <div class="${p}-lines" id="${p}-lines">
          <span class="${p}-l" id="${p}-l1">The questions you would not</span>
          <span class="${p}-l" id="${p}-l2">ask anyone else.</span>
        </div>
        <div class="${p}-q" id="${p}-q">Who else reads them?</div>
      </div>`;
  const js = `
${ENGINE_SRC}
${skyJS(p, f.start)}
${groupPushJS(p)}
      var ev = [{ t: 0, text: "", k: "idle", c: 0 }];
      var caretEl = document.getElementById("${p}-caret");
      var groupEl = document.getElementById("${p}-group");
      function render(t) {
        var G = ${f.start} + t;
        ${p}Sky(t);
        groupEl.style.transform = "scale(" + ${p}Push(G).toFixed(5) + ")";
        caretEl.style.opacity = hfCaret(ev, t, G) ? "1" : "0";
      }
      var tl = gsap.timeline({ paused: true });
      var drv = { t: 0 };
      tl.to(drv, { t: ${f.dur}, duration: ${f.dur}, ease: "none", onUpdate: function () { render(drv.t); } }, 0);
      // the field and the clock let go
      tl.fromTo(groupEl, { opacity: 1, filter: "blur(0px)" }, { opacity: 0, filter: "blur(10px)", duration: 0.9, ease: "power2.in" }, 0.05);
      // statement 1, two word groups
      tl.fromTo("#${p}-l1", { y: 28, opacity: 0, filter: "blur(8px)" }, { y: 0, opacity: 1, filter: "blur(0px)", duration: 0.85, ease: "power2.out" }, 0.15);
      tl.fromTo("#${p}-l2", { y: 28, opacity: 0, filter: "blur(8px)" }, { y: 0, opacity: 1, filter: "blur(0px)", duration: 0.85, ease: "power2.out" }, 0.45);
      // bar 31.0: it gives way to the question
      tl.to("#${p}-lines", { y: -26, opacity: 0, filter: "blur(6px)", duration: 0.5, ease: "power2.in" }, 2.3);
      tl.fromTo("#${p}-q", { y: 30, opacity: 0, filter: "blur(8px)" }, { y: 0, opacity: 1, filter: "blur(0px)", duration: 1.0, ease: "power2.out" }, 2.5);
      // it dissolves into the breath before the swell, so the window rises into an empty sky
      tl.to("#${p}-q", { opacity: 0, filter: "blur(10px)", y: -8, duration: 0.6, ease: "power2.in" }, 4.1);
      render(0);
      window.__timelines["${id}"] = tl;`;
  return frameFile({ id, css, html, js });
}

// ------------------------------------------------------------------ 04 sent
// Rebuilt from chuk.chat usecases.css (.app, .a-chat, .a-composer, .a-bubble, .a-ai,
// .a-tl, .a-acts, .vault) at the real 1000 px logical width; line heights fixed in px so
// every row height is exact (no measuring, synchronous timeline).
const ASK = "How do I tell my boss that I am burned out?";
const LEAD = "Start with facts, not with blame.";
const BULLETS = [
  "Ask for 20 minutes at a calm moment.",
  "Say what changed: sleep, focus, sick days.",
  "Bring one clear request, like fewer projects for a month.",
];

function cipherOf(text, seed) {
  const R = rng(seed);
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let out = "";
  for (const ch of text) out += ch === " " ? " " : A[Math.floor(R() * A.length)];
  return out;
}
function words(text, cls) {
  return text
    .split(/(\s+)/)
    .map((w) => (/^\s+$/.test(w) ? w : `<span class="${cls}">${esc(w)}</span>`))
    .join("");
}

function frame04() {
  const id = "04-sent";
  const p = "f4";
  const f = F[id];
  const tape = TAPES[id];
  const texts = [ASK, LEAD, ...BULLETS];
  const ciphers = texts.map((t, i) => cipherOf(t, 7000 + i * 13));
  const css =
    skyCSS(p) +
    `
.${p}-layer { position: absolute; inset: 0; }
#${p}-cam { position: absolute; left: 0; top: 0; width: 1000px; height: 680px; transform-origin: 0 0; }
#${p}-win { position: absolute; inset: 0; }
.${p}-app { --fg: #E8E4D8; --fg85: rgba(232,228,216,.85); --fg70: rgba(232,228,216,.7); --fg55: rgba(232,228,216,.55);
  --fg30: rgba(232,228,216,.3); --fg15: rgba(232,228,216,.15); --bg: #262624; --lift: #333330; --acc: #D97757; --bubble: #B6674D;
  position: absolute; inset: 0; display: flex; overflow: hidden; border-radius: 18px; background: var(--bg); color: var(--fg);
  font-family: "Ubuntu"; font-size: 14px; line-height: 1.4; text-align: left;
  box-shadow: 0 50px 110px -30px rgba(12, 10, 6, 0.6), 0 0 0 1px rgba(255, 255, 255, 0.07); }
.${p}-app svg { flex: none; }
.${p}-app p { margin: 0; }
.${p}-menu { position: absolute; left: 7px; top: 20px; z-index: 3; width: 48px; height: 40px; display: flex; align-items: center; justify-content: center; color: var(--fg); }
.${p}-menu svg, .${p}-rail svg { width: 20.6px; height: 20.6px; }
.${p}-rail { position: absolute; left: 16px; top: 70px; z-index: 3; display: flex; flex-direction: column; gap: 15px; color: var(--acc); }
.${p}-rail > span { width: 30px; height: 30px; display: flex; align-items: center; justify-content: center; }
.${p}-chat { position: relative; flex: 1 1 0; min-width: 0; display: flex; flex-direction: column; margin-left: 48px; }
.${p}-thread { flex: 1; min-height: 0; display: flex; flex-direction: column; justify-content: flex-end; overflow: hidden;
  -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 70px); mask-image: linear-gradient(180deg, transparent 0, #000 70px); }
.${p}-col { width: 760px; margin: 0 auto; padding: 20px 16px 22px; box-sizing: border-box; }
.${p}-r { overflow: hidden; height: 0px; }
.${p}-user { display: flex; justify-content: flex-end; padding-top: 10px; }
.${p}-bubble { max-width: 80%; padding: 10px 14px; border: 1px solid var(--fg30); border-radius: 16px 16px 5px 16px;
  background: var(--bubble); color: var(--fg); font-family: "Chuk Chat Mono"; font-size: 16px; font-weight: 400; line-height: 22px; white-space: pre; }
.${p}-tlh { display: flex; width: max-content; align-items: center; gap: 4px; margin: 0; padding: 12px 2px 4px; font-family: "Ubuntu";
  font-size: 16px; line-height: 22px; font-weight: 500; color: rgba(232, 228, 216, 0.62); }
.${p}-tlh svg { width: 16px; height: 16px; }
.${p}-ai { font-family: "Chuk Chat Mono"; font-size: 16px; font-weight: 400; line-height: 23px; color: var(--fg); white-space: pre; }
.${p}-lead { padding-top: 8px; padding-bottom: 6px; font-weight: 700; }
.${p}-li { position: relative; padding-left: 32px; padding-bottom: 4px; }
.${p}-li::before { content: ""; position: absolute; left: 14px; top: 9px; width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
.${p}-acts { display: flex; align-items: center; gap: 6px; padding-top: 6px; padding-bottom: 2px; }
.${p}-act { display: inline-flex; align-items: center; padding: 4px 8px; border: 1px solid var(--fg15); border-radius: 100px; background: var(--lift); }
.${p}-act > span { width: 34px; height: 22px; display: inline-flex; align-items: center; justify-content: center; color: var(--fg); }
.${p}-act svg { width: 15.5px; height: 15.5px; }
.${p}-cipher { display: none; }
.${p}-foot { position: relative; z-index: 2; flex: none; display: flex; flex-direction: column; align-items: center; padding: 0 0 16px; }
.${p}-composer { position: relative; display: flex; flex-direction: column; justify-content: space-between; width: 760px; box-sizing: border-box;
  min-height: 135px; padding: 14px; border: 2px solid #615F5A; border-radius: 30px; background: var(--bg); font-family: "Ubuntu"; }
.${p}-field { min-height: 40px; padding: 2px 58px 0 4px; font-size: 16px; line-height: 22px; font-weight: 500; color: #E8E4D8; white-space: pre-wrap; }
.${p}-ph { font-weight: 600; color: rgba(232, 228, 216, 0.8); }
.${p}-caret { display: inline-block; width: 2px; height: 19px; margin-left: 1px; vertical-align: -4px; background: #D97757; }
.${p}-send { position: absolute; top: 14px; right: 14px; width: 44px; height: 36px; border-radius: 20px; background: var(--acc); color: #fff;
  display: flex; align-items: center; justify-content: center; }
.${p}-send svg { width: 22.4px; height: 22.4px; }
.${p}-row { display: flex; align-items: center; gap: 8px; }
.${p}-grow { flex: 1; order: 2; }
.${p}-btn { width: 44px; height: 36px; box-sizing: border-box; border: 2px solid #615F5A; border-radius: 18px; display: inline-flex; align-items: center; justify-content: center; color: var(--fg); }
.${p}-btn svg { width: 20.6px; height: 20.6px; }
.${p}-plus { order: 1; }
.${p}-pill { order: 3; height: 36px; box-sizing: border-box; padding: 0 9px; border: 2px solid #615F5A; border-radius: 18px; display: inline-flex; align-items: center; gap: 5px;
  font-size: 12px; font-weight: 600; color: var(--fg); white-space: nowrap; }
.${p}-pill svg { width: 13px; height: 13px; }
.${p}-pill .${p}-dn { width: 10.4px; height: 10.4px; margin-left: -3px; color: var(--fg70); }
.${p}-mic { order: 4; }
.${p}-mic svg { width: 18.9px; height: 18.9px; }
.${p}-disc { margin: 8px 0 0; font-size: 11px; color: var(--fg70); text-align: center; }
.${p}-vault { position: absolute; inset: 0; z-index: 5; display: flex; flex-direction: column; align-items: center; padding-top: 104px;
  background: linear-gradient(180deg, rgba(18, 22, 40, 0.55), transparent 45%); border-radius: 18px; }
.${p}-badge { display: inline-flex; align-items: center; gap: 10px; padding: 11px 20px; border: 1px solid rgba(160, 180, 255, 0.32);
  border-radius: 999px; background: rgba(14, 17, 30, 0.92); color: #DDE4FF; font-family: "Ubuntu"; font-size: 21px; font-weight: 600; }
.${p}-badge svg { width: 22px; height: 22px; }
.${p}-note { margin-top: 10px; font-family: "Chuk Chat Mono"; font-size: 17px; color: #AEB8DB; }
.${p}-lock { position: absolute; left: 0; right: 0; top: 392px; text-align: center; font-family: "Chuk Sans"; font-weight: 300;
  font-size: 92px; line-height: 112px; letter-spacing: -0.03em; color: #F6F3EC; }
.${p}-ll { display: block; }
.${p}-brand { position: absolute; left: 0; right: 0; top: 858px; display: flex; align-items: center; justify-content: center; gap: 22px;
  font-family: "Chuk Chat Mono"; font-weight: 600; font-size: 76px; line-height: 92px; color: #F6F3EC; }
.${p}-brand img { width: 80px; height: 80px; }
.${p}-ll svg { display: inline-block; width: 70px; height: 70px; margin-right: 26px; vertical-align: -6px; color: #F2C56B; }`;

  const html =
    skyHTML(p, f.dur) +
    `
      <div class="clip ${p}-layer" id="${p}-content" data-start="0" data-duration="${f.dur}" data-track-index="1">
        <div id="${p}-cam">
          <div id="${p}-win">
            <div class="${p}-app" data-layout-allow-overflow>
              <span class="${p}-menu">${ICON.menu}</span>
              <span class="${p}-rail"><span>${ICON.pencil}</span><span>${ICON.image}</span></span>
              <div class="${p}-chat">
                <div class="${p}-thread"><div class="${p}-col">
                  <div class="${p}-r" id="${p}-r1"><div class="${p}-user" id="${p}-user"><p class="${p}-bubble" id="${p}-bubble"><span class="${p}-plain" id="${p}-p0">${esc(ASK)}</span><span class="${p}-cipher" id="${p}-c0"></span></p></div></div>
                  <div class="${p}-r" id="${p}-r2"><p class="${p}-tlh" id="${p}-tlh"><span>Thought for 4s</span>${ICON.right}</p></div>
                  <div class="${p}-r" id="${p}-r3"><div class="${p}-ai ${p}-lead" id="${p}-lead"><span class="${p}-plain" id="${p}-p1">${words(LEAD, `${p}-w ${p}-w1`)}</span><span class="${p}-cipher" id="${p}-c1"></span></div></div>
                  ${BULLETS.map(
                    (b, i) =>
                      `<div class="${p}-r" id="${p}-r${4 + i}"><div class="${p}-ai ${p}-li" id="${p}-li${i}"><span class="${p}-plain" id="${p}-p${2 + i}">${words(b, `${p}-w ${p}-w${2 + i}`)}</span><span class="${p}-cipher" id="${p}-c${2 + i}"></span></div></div>`,
                  ).join("\n                  ")}
                  <div class="${p}-r" id="${p}-r7"><div class="${p}-acts"><span class="${p}-act"><span>${ICON.copy}</span><span>${ICON.refresh}</span><span>${ICON.route}</span></span></div></div>
                </div></div>
                <div class="${p}-foot">
                  <div class="${p}-composer" id="${p}-composer">
                    <div class="${p}-field" id="${p}-field"><span class="${p}-ph" id="${p}-ph">Ask me anything !</span><span id="${p}-typed"></span><span class="${p}-caret" id="${p}-caret"></span></div>
                    <div class="${p}-row">
                      <span class="${p}-btn ${p}-plus">${ICON.plus}</span>
                      <span class="${p}-grow"></span>
                      <span class="${p}-pill">${ICON.flash}<b>Fast</b><span class="${p}-dn">${ICON.down}</span></span>
                      <span class="${p}-btn ${p}-mic">${ICON.mic}</span>
                    </div>
                    <span class="${p}-send" id="${p}-send">${ICON.send}</span>
                  </div>
                  <p class="${p}-disc">You're chatting with an AI/LLM — it can be wrong. Check key info.</p>
                </div>
              </div>
              <div class="${p}-vault" id="${p}-vault">
                <span class="${p}-badge">${ICON.lock}What our server stores</span>
                <span class="${p}-note">AES-256-GCM · the key stays on your device</span>
              </div>
            </div>
          </div>
        </div>
        <div class="${p}-brand" id="${p}-brand"><img src="assets/logo-light.svg" alt="" /><span>Chuk Chat</span></div>
        <div class="${p}-lock" id="${p}-lock">
          <span class="${p}-ll" id="${p}-ll1">${ICON.lock}Encrypted on your device.</span>
          <span class="${p}-ll" id="${p}-ll2">We keep only ciphertext.</span>
        </div>
      </div>`;

  // camera keys (window-logical focus -> screen)
  const cam = (fx, fy, s, sx, sy) => ({ x: +(sx - fx * s).toFixed(2), y: +(sy - fy * s).toFixed(2), scale: s });
  // Phone rule: chat text >= 28 px on screen -> scale 1.75 for every UI shot.
  const K0 = cam(524, 573, 1.75, 960, 572); // composer
  const K2 = cam(524, 362, 1.75, 960, 522); // thread (window bottom meets the frame bottom)
  const K3 = { x: K2.x + 140, y: K2.y + 380, scale: 1.5 }; // recede: drops away

  const ROWS = { r1: 54, r2: 38, r3: 37, r4: 27, r5: 27, r6: 27, r7: 40 };
  const T_SEND = 5.25; // hit 38.65
  const T_TL = 6.44; // hit 39.84
  const T_LEAD = 7.05;
  const T_B = [7.85, 8.55, 9.25];
  const T_ACTS = 10.15;
  const T_SCR = 11.65; // hit 45.05
  const T_OUT = 12.9; // after the 46.25 hit
  const T_LOCK1 = 13.4; // only once the window is gone: no headline over UI
  const T_LOCK2 = 13.85;

  const js = `
${ENGINE_SRC}
${skyJS(p, f.start)}
      var TAPE = ${JSON.stringify(tape)};
      var ev = hfTape(TAPE.ops, TAPE.seed);
      var PLAIN = ${JSON.stringify(texts)};
      var CIPH = ${JSON.stringify(ciphers)};
      var SCR = [${[0, 1, 2, 3, 4].map((i) => (T_SCR + i * 0.09).toFixed(2)).join(", ")}];
      var GLY = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
      var typedEl = document.getElementById("${p}-typed");
      var phEl = document.getElementById("${p}-ph");
      var caretEl = document.getElementById("${p}-caret");
      var pEls = [0, 1, 2, 3, 4].map(function (i) { return document.getElementById("${p}-p" + i); });
      var cEls = [0, 1, 2, 3, 4].map(function (i) { return document.getElementById("${p}-c" + i); });
      function mix(i, t) {
        var u = (t - SCR[i]) / 0.6;
        var plain = PLAIN[i], ci = CIPH[i], n = plain.length;
        if (u >= 1) return ci;
        var m = Math.floor(Math.max(0, u) * n);
        var tick = Math.floor(t * 30);
        var out = ci.slice(0, m);
        for (var k = m; k < n; k++) {
          var ch = plain[k];
          if (k < m + 3 && ch !== " ") out += GLY[(k * 7 + tick * 13 + i * 5) % GLY.length];
          else out += ch;
        }
        return out;
      }
      function render(t) {
        var G = ${f.start} + t;
        ${p}Sky(t);
        var e = hfAt(ev, t);
        var txt = e.text;
        if (typedEl.textContent !== txt) typedEl.textContent = txt;
        phEl.style.display = txt.length ? "none" : "inline";
        caretEl.style.display = txt.length ? "inline-block" : "none";
        caretEl.style.opacity = hfCaret(ev, t, G) ? "1" : "0";
        for (var i = 0; i < 5; i++) {
          if (t < SCR[i]) { pEls[i].style.display = "inline"; cEls[i].style.display = "none"; }
          else {
            pEls[i].style.display = "none"; cEls[i].style.display = "inline";
            var s = mix(i, t);
            if (cEls[i].textContent !== s) cEls[i].textContent = s;
          }
        }
      }
      var tl = gsap.timeline({ paused: true });
      var drv = { t: 0 };
      tl.to(drv, { t: ${f.dur}, duration: ${f.dur}, ease: "none", onUpdate: function () { render(drv.t); } }, 0);

      // the window rises into the night on the swell
      tl.set("#${p}-cam", Object.assign(${JSON.stringify(K0)}, { transformOrigin: "0% 0%" }), 0);
      tl.fromTo("#${p}-win", { opacity: 0, y: 150, filter: "blur(8px)" }, { opacity: 1, y: 0, filter: "blur(0px)", duration: 1.0, ease: "power2.out" }, 0);
      // the name, in the sky under the window, while the question is typed
      tl.fromTo("#${p}-brand", { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.7, ease: "power2.out" }, 0.55);
      tl.to("#${p}-brand", { opacity: 0, y: 10, duration: 0.4, ease: "power2.in" }, 4.55);
      // send (enter) — the pill presses
      tl.fromTo("#${p}-send", { scale: 1 }, { scale: 0.86, duration: 0.08, ease: "power2.in" }, ${T_SEND - 0.02});
      tl.to("#${p}-send", { scale: 1, duration: 0.3, ease: "power2.out" }, ${(T_SEND + 0.08).toFixed(2)});
      // the message enters the thread
      tl.fromTo("#${p}-r1", { height: 0 }, { height: ${ROWS.r1}, duration: 0.42, ease: "power2.out" }, ${T_SEND});
      tl.fromTo("#${p}-user", { y: 18, opacity: 0 }, { y: 0, opacity: 1, duration: 0.45, ease: "power2.out" }, ${T_SEND + 0.02});
      tl.to("#${p}-cam", Object.assign(${JSON.stringify(K2)}, { duration: 1.1, ease: "power2.inOut" }), ${T_SEND + 0.1});
      // Thought for 4s
      tl.fromTo("#${p}-r2", { height: 0 }, { height: ${ROWS.r2}, duration: 0.32, ease: "power2.out" }, ${T_TL});
      tl.fromTo("#${p}-tlh", { opacity: 0 }, { opacity: 1, duration: 0.4, ease: "power1.out" }, ${T_TL + 0.05});
      // the answer streams
      tl.fromTo("#${p}-r3", { height: 0 }, { height: ${ROWS.r3}, duration: 0.25, ease: "power2.out" }, ${T_LEAD});
      tl.fromTo(".${p}-w1", { opacity: 0 }, { opacity: 1, duration: 0.14, ease: "none", stagger: 0.1 }, ${T_LEAD + 0.05});
      ${T_B.map(
        (tb, i) => `tl.fromTo("#${p}-r${4 + i}", { height: 0 }, { height: ${ROWS["r" + (4 + i)]}, duration: 0.22, ease: "power2.out" }, ${tb});
      tl.fromTo(".${p}-w${2 + i}", { opacity: 0 }, { opacity: 1, duration: 0.12, ease: "none", stagger: 0.075 }, ${(tb + 0.04).toFixed(2)});`,
      ).join("\n      ")}
      tl.fromTo("#${p}-r7", { height: 0 }, { height: ${ROWS.r7}, duration: 0.3, ease: "power2.out" }, ${T_ACTS});
      // ciphertext
      tl.to("#${p}-bubble", { backgroundColor: "#33343C", color: "#9DA6C8", duration: 0.6, ease: "power1.inOut" }, ${T_SCR});
      tl.to(".${p}-ai", { color: "#8791B5", duration: 0.6, ease: "power1.inOut" }, ${T_SCR + 0.1});
      tl.fromTo("#${p}-vault", { opacity: 0 }, { opacity: 1, duration: 0.6, ease: "power2.out" }, ${T_SCR + 0.15});
      tl.fromTo(".${p}-badge", { y: -12 }, { y: 0, duration: 0.7, ease: "power2.out" }, ${T_SCR + 0.15});
      // the window drops away (never small in an empty sky), the lock line takes the sky
      tl.to("#${p}-cam", Object.assign(${JSON.stringify(K3)}, { opacity: 0, duration: 0.45, ease: "power2.in" }), ${T_OUT});
      tl.fromTo("#${p}-ll1", { y: 30, opacity: 0, filter: "blur(8px)" }, { y: 0, opacity: 1, filter: "blur(0px)", duration: 0.85, ease: "power2.out" }, ${T_LOCK1});
      tl.fromTo("#${p}-ll2", { y: 30, opacity: 0, filter: "blur(8px)" }, { y: 0, opacity: 1, filter: "blur(0px)", duration: 0.85, ease: "power2.out" }, ${T_LOCK2});
      // clear the sky before the claim lands on the 49.44 hit
      tl.to("#${p}-lock", { opacity: 0, filter: "blur(6px)", duration: 0.34, ease: "power2.in" }, ${(f.dur - 0.36).toFixed(2)});
      render(0);
      window.__timelines["${id}"] = tl;`;
  return frameFile({ id, css, html, js });
}

// ------------------------------------------------------------------ 05 claim
function frame05() {
  const id = "05-claim";
  const p = "f5";
  const f = F[id];
  const css =
    skyCSS(p) +
    `
.${p}-layer { position: absolute; inset: 0; }
.${p}-lines { position: absolute; left: 120px; right: 120px; top: 404px; text-align: center; font-family: "Chuk Sans"; font-weight: 300;
  font-size: 100px; line-height: 124px; letter-spacing: -0.03em; color: #F6F3EC; }
.${p}-l { display: block; }`;
  const html =
    skyHTML(p, f.dur) +
    `
      <div class="clip ${p}-layer" id="${p}-content" data-start="0" data-duration="${f.dur}" data-track-index="1">
        <div class="${p}-lines" id="${p}-lines">
          <span class="${p}-l" id="${p}-l1" data-layout-allow-overlap>Never used for training.</span>
          <span class="${p}-l" id="${p}-l2" data-layout-allow-overlap>No tracking.</span>
        </div>
      </div>`;
  const js = `
${skyJS(p, f.start)}
      var tl = gsap.timeline({ paused: true });
      var drv = { t: 0 };
      tl.to(drv, { t: ${f.dur}, duration: ${f.dur}, ease: "none", onUpdate: function () { ${p}Sky(drv.t); } }, 0);
      tl.fromTo("#${p}-l1", { y: 30, opacity: 0, filter: "blur(8px)" }, { y: 0, opacity: 1, filter: "blur(0px)", duration: 0.9, ease: "power2.out" }, 0.1);
      tl.fromTo("#${p}-l2", { y: 30, opacity: 0, filter: "blur(8px)" }, { y: 0, opacity: 1, filter: "blur(0px)", duration: 0.9, ease: "power2.out" }, 1.0);
      // clear the sky before the end card lands on the 51.44 hit
      tl.to("#${p}-lines", { opacity: 0, filter: "blur(6px)", duration: 0.4, ease: "power2.in" }, ${(f.dur - 0.42).toFixed(2)});
      ${p}Sky(0);
      window.__timelines["${id}"] = tl;`;
  return frameFile({ id, css, html, js });
}

// ------------------------------------------------------------------ 06 end card
function frame06() {
  const id = "06-endcard";
  const p = "f6";
  const f = F[id];
  const css =
    skyCSS(p) +
    `
.${p}-layer { position: absolute; inset: 0; }
.${p}-stack { position: absolute; left: 0; right: 0; top: 196px; display: flex; flex-direction: column; align-items: center; }
.${p}-lockup { display: flex; align-items: center; gap: 34px; }
.${p}-logo { display: block; width: 132px; height: 132px; }
.${p}-name { font-family: "Chuk Chat Mono"; font-weight: 600; font-size: 118px; line-height: 136px; letter-spacing: -0.02em; color: #F6F3EC; }
.${p}-slogan { margin-top: 40px; font-family: "Chuk Sans"; font-weight: 300; font-size: 64px; line-height: 78px; letter-spacing: -0.022em; color: #DCDFEA; }
.${p}-url { margin-top: 52px; padding: 14px 40px; border: 2px solid rgba(242, 197, 107, 0.55); border-radius: 999px; background: rgba(242, 197, 107, 0.08);
  font-family: "Chuk Chat Mono"; font-weight: 500; font-size: 44px; line-height: 56px; letter-spacing: 0.01em; color: #F2C56B; }`;
  const html =
    skyHTML(p, f.dur) +
    `
      <div class="clip ${p}-layer" id="${p}-content" data-start="0" data-duration="${f.dur}" data-track-index="1">
        <div class="${p}-stack">
          <div class="${p}-lockup">
            <img class="${p}-logo" id="${p}-logo" src="assets/logo-light.svg" alt="Chuk Chat logo" />
            <div class="${p}-name" id="${p}-name">Chuk Chat</div>
          </div>
          <div class="${p}-slogan" id="${p}-slogan">Private and Secure. Always.</div>
          <div class="${p}-url" id="${p}-url">chuk.chat</div>
        </div>
      </div>`;
  const js = `
${skyJS(p, f.start)}
      var tl = gsap.timeline({ paused: true });
      var drv = { t: 0 };
      tl.to(drv, { t: ${f.dur}, duration: ${f.dur}, ease: "none", onUpdate: function () { ${p}Sky(drv.t); } }, 0);
      tl.fromTo("#${p}-logo", { opacity: 0, scale: 0.9 }, { opacity: 1, scale: 1, duration: 0.9, ease: "power2.out" }, 0.1);
      tl.fromTo("#${p}-name", { opacity: 0, x: -16 }, { opacity: 1, x: 0, duration: 0.8, ease: "power2.out" }, 0.3);
      tl.fromTo("#${p}-slogan", { opacity: 0, y: 18 }, { opacity: 1, y: 0, duration: 0.8, ease: "power2.out" }, 0.62);
      tl.fromTo("#${p}-url", { opacity: 0, y: 12 }, { opacity: 1, y: 0, duration: 0.7, ease: "power2.out" }, 0.95);
      ${p}Sky(0);
      window.__timelines["${id}"] = tl;`;
  return frameFile({ id, css, html, js });
}

const out = {
  "01-hook": frame01(),
  "02-questions": frame02(),
  "03-who-reads": frame03(),
  "04-sent": frame04(),
  "05-claim": frame05(),
  "06-endcard": frame06(),
};
for (const [id, src] of Object.entries(out)) {
  writeFileSync(join(OUT, `${id}.html`), src);
  console.log(`wrote compositions/frames/${id}.html (${src.length} bytes)`);
}
