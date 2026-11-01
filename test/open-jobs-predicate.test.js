'use strict';
// "Is this job open work?" is lib/order-status.js's isOpen: not finished, not a
// quote, not cancelled. The desktop wrote `!isFinished(o) && o.status !==
// 'quote'` by hand in 26 places, and every one counted a cancelled job as open
// (filament reserved, dashboard counts, due-date reminders). This refuses the
// hand-written form anywhere in the renderer, in either order.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const S = require('../lib/order-status.js');

test('isOpen: open statuses are open; finished, quote and cancelled are not', () => {
  for (const st of ['pending', 'queued', 'printing', 'post', 'qc', 'on_hold']) {
    assert.strictEqual(S.isOpen({ status: st }), true, st);
  }
  for (const st of ['completed', 'delivered', 'quote', 'cancelled']) {
    assert.strictEqual(S.isOpen({ status: st }), false, st);
  }
  assert.strictEqual(S.isOpen(null), false);
  assert.strictEqual(S.isOpen(undefined), false);
});

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (/\.(js|html)$/.test(e.name)) out.push(p);
  }
  return out;
}

test('the renderer never hand-writes "not finished and not a quote"', () => {
  const root = path.join(__dirname, '..', 'renderer');
  const forms = [
    /isFinished\(\s*(\w+)\s*\)\s*&&\s*\1\.status\s*!==?\s*'quote'/,
    /(\w+)\.status\s*!==?\s*'quote'\s*&&\s*!\s*(?:KhaytOrderStatus\.)?isFinished\(\s*\1\s*\)/,
  ];
  const hits = [];
  for (const f of walk(root, [])) {
    fs.readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      if (forms.some(re => re.test(line))) hits.push(`${path.relative(root, f)}:${i + 1}`);
    });
  }
  assert.deepStrictEqual(hits, [], 'use KhaytOrderStatus.isOpen(o), which also leaves out cancelled jobs:\n' + hits.join('\n'));
});

test('the spool reservation and over-commit check leave a cancelled job out', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'inventory.js'), 'utf8');
  const body = (name) => src.slice(src.indexOf(`function ${name}(`), src.indexOf('\n}\n', src.indexOf(`function ${name}(`)));
  for (const fn of ['getSpoolReservedGrams', 'checkSpoolOvercommit', 'renderPipelineDemand']) {
    assert.match(body(fn), /KhaytOrderStatus\.isOpen\(o\)/, fn);
  }
});
