import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compileMini } from './mini.mjs';
import { exportScene } from './export3d.mjs';

test('kit machine compiles and passes the sweep check', () => {
  const r = compileMini('gear a teeth=20 at=0,0\ngear b teeth=40 to=a dir=30\npiston p to=b dir=90\nwheel c r=0.8 to=a by=belt dir=200 dist=3\nblock s size=4,1 on=p side=right\n');
  assert.deepEqual(r.errors, []);
  assert.deepEqual(exportScene(r.chalk).errors, []);
});

test('errors name the fix', () => {
  assert.match(compileMini('gear a teeth=20 at=0,0\ngear b teeth=20 to=x dir=0\n').errors[0], /to= must name/);
  assert.match(compileMini('gear a teeth=20 at=0,0\ngear b teeth=20 to=a dir=0\ngear c teeth=20 to=b dir=180\n').errors[0], /overlaps/);
  assert.match(compileMini('block s size=1,1\n').errors[0], /nothing moves/);
});
