#!/usr/bin/env node
// step <dir> <tag> <r0.chalk> [edits...]: renders a scene with its edits.
// Writes <tag>.svg, <tag>.blind.svg (no text) and <tag>.ids.svg (parts by id).
import { readFileSync, writeFileSync } from 'node:fs';
import { parse, render, feedback } from './scene.mjs';
import { applyEdits } from './parse.mjs';

const [, , dir, tag, first, ...edits] = process.argv;
const build = () => {
  let { root } = parse(readFileSync(first, 'utf8'));
  const errors = [];
  for (const f of edits) {
    const text = readFileSync(f, 'utf8');
    if (/^\s*canvas\b/.test(text)) root = parse(text).root;
    else errors.push(...applyEdits(root, text));
  }
  return { root, errors };
};
const a = build();
const res = render(a.root);
res.ctx.errors.push(...a.errors);
writeFileSync(`${dir}/${tag}.svg`, res.svg);
writeFileSync(`${dir}/${tag}.blind.svg`, render(build().root, { notext: true }).svg);
writeFileSync(`${dir}/${tag}.ids.svg`, render(build().root, { flat: true }).svg);
// Three clean views, parts painted by id: placement errors show at once.
[['side', [0, 0]], ['top', [0, 89.9]], ['front', [90, 0]]].forEach(([name, view]) => {
  writeFileSync(`${dir}/${tag}.${name}.svg`, render(build().root, { flat: true, forceView: view }).svg);
});
console.log(feedback(a.root, res));
