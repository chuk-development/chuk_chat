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
  const { root } = parse('model m 300 200 explode=0.01\n  box a size=1,1,1\n  box b size=1,1,1 at=9,0,0');
  const r = render(root);
  const m = r.ctx.models[0];
  const s = m.res.stats.find((p) => p.id === 'a');
  const [x, y] = [s.x + m.node.x, s.y + m.node.y];
  assert.match(describeStroke(r, [[x - 9, y], [x + 9, y], [x, y + 9], [x - 9, y]]), /circled a/);
});

test('on= places a part flush on its parent', () => {
  const { root } = parse('model m 300 200\n  box a size=2,2,2\n  box b size=1,1,1 on=a+y sink=0');
  const r = render(root);
  const [a, b] = r.ctx.models[0].parts;
  const ys = (p) => { const v = []; for (let i = 1; i < p.tris.length; i += 3) v.push(p.tris[i]); return v; };
  assert.ok(Math.abs(Math.max(...ys(a)) - Math.min(...ys(b))) < 1e-4);
});

test('a loose part is pulled to the body', () => {
  const { root } = parse('model m 300 200\n  box a size=4,4,4\n  box b size=1,1,1 at=9,0,0');
  const r = render(root);
  assert.equal(r.ctx.models[0].parts.repaired[0], 'b');
});
