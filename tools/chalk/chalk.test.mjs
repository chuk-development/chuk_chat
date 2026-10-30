import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, render, feedback, describeStroke } from './scene.mjs';
import { applyEdits } from './parse.mjs';

test('a bad line reports an error and the rest still renders', () => {
  const { root } = parse('title "x"\nbogus y\nbox a "A"');
  const r = render(root);
  assert.match(feedback(root, r), /unknown element "bogus"/);
  assert.ok(r.ctx.ids.has('a'));
});

test('a row that is too wide wraps', () => {
  const kids = Array.from({ length: 9 }, (_, i) => `  box b${i} "x" w=300`).join('\n');
  const r = render(parse(`row\n${kids}`).root);
  assert.ok(r.W <= 1400);
});

test('replace on a sketch keeps the frame', () => {
  const { root } = parse('sketch s 100 100\n  curve pts=0,0 5,5\nbox a "A"');
  applyEdits(root, 'replace s\n  dot 5,5 r=3');
  assert.equal(root.kids[0].cmd, 'sketch');
  assert.equal(root.kids[0].kids[0].cmd, 'dot');
});

test('floating parts and stroke hits are reported by id', () => {
  const { root } = parse('model m 300 200\n  box a size=1,1,1\n  box b size=1,1,1 at=9,0,0');
  const r = render(root);
  assert.match(feedback(root, r), /not connected/);
  const m = r.ctx.models[0];
  const s = m.res.stats.find((p) => p.id === 'a');
  const [x, y] = [s.x + m.node.x, s.y + m.node.y];
  assert.match(describeStroke(r, [[x - 9, y], [x + 9, y], [x, y + 9], [x - 9, y]]), /circled a/);
});
