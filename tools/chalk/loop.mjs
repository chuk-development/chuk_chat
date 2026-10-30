#!/usr/bin/env node
// loop <dir> <round>: round 0 is a full scene, later rounds are edits on it.
// Writes r<round>.svg and prints the feedback for the model.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { parse, render, feedback } from './scene.mjs';
import { applyEdits } from './parse.mjs';

const [, , dir, roundArg] = process.argv;
const round = Number(roundArg);
let src = readFileSync(`${dir}/scene.chalk`.replace('scene', 'r0'), 'utf8');
let { root } = parse(src);
const editErrors = [];
for (let r = 1; r <= round; r++) {
  const f = `${dir}/r${r}.chalk`;
  if (!existsSync(f)) continue;
  const text = readFileSync(f, 'utf8');
  // A model may send a whole new scene instead of edits. That replaces it.
  if (/^\s*canvas\b/.test(text)) root = parse(text).root;
  else editErrors.push(...applyEdits(root, text));
}
const res = render(root);
res.ctx.errors.push(...editErrors);
writeFileSync(`${dir}/r${round}.svg`, res.svg);
console.log(feedback(root, res));
