import test from 'node:test';
import assert from 'node:assert/strict';
import { parse } from './parse.mjs';
import { buildParts } from './raster.mjs';
import { readMech, solve } from './mech.mjs';

const SCENE = `model m 800 400 keep=1
  template pis
    cyl pb r=0.4 h=0.6 axis=y
  template con
    cyl big r=0.2 h=0.2 axis=x
    tube beam pts=0,0,0 0,1.6,0 r=0.08
  mech
    crankshaft crank at=0,0,0 axis=x r=0.4 throws=0:0
    cylinder a crank=crank x=0 throw=30 angle=0 rod=1.6 piston=pis conrod=con
`;
const load = (src) => {
  const model = parse(src).root.kids[0], errors = [];
  const parts = buildParts(model, errors);
  return { mech: readMech(model, parts, errors), errors };
};
const point = (M, p) => [0, 1, 2].map((c) => M[c] * p[0] + M[c + 3] * p[1] + M[c + 6] * p[2] + M[c + 9]);

test('rod stays joined to crank pin and piston over a full turn', () => {
  const { mech } = load(SCENE);
  const rod = mech.joints.get('r_a'), piston = mech.joints.get('p_a');
  for (let k = 0; k < 72; k++) {
    const S = solve(mech, k * Math.PI / 36);
    const a = point(S.get('r_a'), rod.pin), b = point(S.get('crank'), rod.pin);
    const c = point(S.get('r_a'), piston.wrist), d = point(S.get('p_a'), piston.wrist);
    assert.ok(Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]) < 1e-9);
    assert.ok(Math.hypot(c[0] - d[0], c[1] - d[1], c[2] - d[2]) < 1e-9);
  }
});

test('a ring has an open hole', () => {
  const model = parse('model m 800 400 keep=1\n  cyl r r=1 hole=0.5 h=0.2 axis=y\n').root.kids[0];
  const [p] = buildParts(model, []);
  for (let i = 0; i < p.tris.length; i += 3) assert.ok(Math.hypot(p.tris[i], p.tris[i + 2]) > 0.49);
});

test('a rotor across its true axis is reported', () => {
  const { errors } = load('model m 800 400 keep=1\n  group fan\n    cyl d r=1 h=0.1 axis=z\n  mech\n    rotor fan axis=x\n');
  assert.ok(errors.some((e) => e.includes('wrong axis')));
});
