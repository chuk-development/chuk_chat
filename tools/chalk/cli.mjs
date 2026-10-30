#!/usr/bin/env node
// chalk <file> <out.svg>: render a scene and print model feedback.
import { readFileSync, writeFileSync } from 'node:fs';
import { parse, render, feedback } from './scene.mjs';
const [, , file, out] = process.argv;
const { root } = parse(readFileSync(file, 'utf8'));
const t = Date.now();
const r = render(root);
writeFileSync(out, r.svg);
console.log(feedback(root, r));
console.log(`render ${Date.now() - t} ms`);
