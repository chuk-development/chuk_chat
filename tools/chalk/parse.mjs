// Chalk line format: indentation tree, `cmd positional key=value`.
// The parser never throws. Bad lines become errors and the rest still renders,
// so a stream can be drawn line by line and a model gets exact feedback.

const TOKEN = /[A-Za-z_][A-Za-z_0-9]*="(?:[^"\\]|\\.)*"|"(?:[^"\\]|\\.)*"|\S+/g;
const NUMLIST = /^-?[\d.]+(,-?[\d.]+)+$/;

const unquote = (s) => s.slice(1, -1).replace(/\\n/g, '\n').replace(/\\"/g, '"');

export function parseLine(text, line) {
  const tokens = text.match(TOKEN) ?? [];
  const node = { cmd: tokens[0], args: [], kv: {}, kids: [], line };
  let listKey = null;
  for (const t of tokens.slice(1)) {
    const m = t.match(/^([A-Za-z_][A-Za-z_0-9]*)=(.*)$/s);
    if (m) {
      const v = m[2];
      node.kv[m[1]] = v.startsWith('"') ? unquote(v) : v;
      listKey = NUMLIST.test(v) || /^-?[\d.]+$/.test(v) ? m[1] : null;
    } else if (listKey && NUMLIST.test(t)) {
      node.kv[listKey] += ' ' + t; // `pts=0,0 1,2 3,4`
    } else {
      node.args.push(t.startsWith('"') ? unquote(t) : t);
      listKey = null;
    }
  }
  return node;
}

export function parse(src) {
  const root = { cmd: 'root', args: [], kv: {}, kids: [], line: 0 };
  const stack = [{ node: root, indent: -1 }];
  const errors = [];
  src.split('\n').forEach((raw, i) => {
    const line = i + 1;
    const expanded = raw.replace(/\t/g, '  ').replace(/\s+$/, '');
    const body = expanded.trimStart();
    if (!body || body.startsWith('#') || body.startsWith('```')) return;
    const indent = expanded.length - body.length;
    const node = parseLine(body, line);
    while (stack.at(-1).indent >= indent) stack.pop();
    stack.at(-1).node.kids.push(node);
    stack.push({ node, indent });
  });
  return { root, errors };
}

function findNode(n, id) {
  for (let i = 0; i < n.kids.length; i++) {
    const k = n.kids[i];
    if (nodeId(k) === id) return { parent: n, index: i, node: k };
    const r = findNode(k, id);
    if (r) return r;
  }
  return null;
}

// The id is the first positional word, unless the command takes text first.
export function nodeId(n) {
  if (n.kv.id) return n.kv.id;
  if (['title', 'h2', 'text', 'note', 'row', 'col', 'canvas', 'arrow'].includes(n.cmd)) return null;
  return n.args[0] ?? null;
}

// Edits: `set id k=v`, `del id`, `replace id` + block, `add id` + block
// (appends into a container). Returns errors for ids that do not exist.
export function applyEdits(root, src) {
  const edits = parse(src).root.kids;
  const errors = [];
  for (const e of edits) {
    const id = e.args[0];
    if (!['set', 'del', 'replace', 'add'].includes(e.cmd)) {
      root.kids.push(e); // A plain line appends to the scene.
      continue;
    }
    const hit = findNode(root, id);
    if (!hit) {
      errors.push(`line ${e.line}: ${e.cmd}: no element "${id}"`);
    } else if (e.cmd === 'set') {
      Object.assign(hit.node.kv, e.kv);
      if (e.args[1] !== undefined) hit.node.args[1] = e.args[1];
    } else if (e.cmd === 'del') {
      hit.parent.kids.splice(hit.index, 1);
    } else if (e.cmd === 'replace') {
      // `replace sketch` with only strokes below means: new content, same frame.
      const keepFrame = ['sketch', 'model'].includes(hit.node.cmd) && !e.kids.some((k) => k.cmd === hit.node.cmd);
      if (keepFrame) hit.node.kids = e.kids;
      else hit.parent.kids.splice(hit.index, 1, ...e.kids);
    } else {
      hit.node.kids.push(...e.kids);
    }
  }
  return errors;
}

export function nums(v, fallback = []) {
  if (v === undefined || v === null) return fallback;
  return String(v).split(',').map(Number);
}

export function points(v) {
  if (!v) return [];
  return String(v).trim().split(/[\s;]+/).map((p) => p.split(',').map(Number));
}
