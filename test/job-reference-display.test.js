'use strict';

/**
 * A person reads a job's NUMBER, never the random tag on its id.
 *
 * Since ids became unique across computers (lib/order-new.js `mintOrderId`),
 * a new job's id is `INV-2026-0042-k7qx`. The tag exists only so two
 * computers can never key two jobs alike; what a shop, a customer or a
 * courier reads is the number, `jobNumber` — through `jobRef(order)` on the
 * desktop and `Order.reference` / `JobReference.of` on the Mac and phone.
 * The id stays the key for lookups, `data-` attributes, links and file paths.
 *
 * This is a source check, because the failure is a screen nobody tests: a
 * new list that prints `escapeHtml(o.id)` compiles, runs, and quietly shows
 * the tag. It looks for the shapes a display of the id takes and fails on
 * any of them. If a match really is a key and not text a person reads, add
 * it to ALLOWED with the reason.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
// The names a job goes by in these files.
const V = '(?:o|order|job|q|quote|log|sub|parent|e\\.order)';

function walk(dir, ext, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, ext, out);
    else if (e.name.endsWith(ext)) out.push(p);
  }
  return out;
}

/** `file:line: text` for every line matching one of `patterns`. */
function hits(files, patterns, allowed) {
  const out = [];
  for (const f of files) {
    const rel = path.relative(ROOT, f);
    fs.readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      for (const re of patterns) {
        if (!re.test(line)) continue;
        const key = `${rel}: ${line.trim()}`;
        if (!allowed.some((a) => key.includes(a))) out.push(`${rel}:${i + 1}: ${line.trim().slice(0, 160)}`);
      }
    });
  }
  return out;
}

const ALLOWED = [
  // A file on disk, named by the id the app reads it back by.
  'userData/status-pages/${escapeHtml(order.id)}.html',
];

test('the desktop never shows a job id where a person reads it', () => {
  const files = walk(path.join(ROOT, 'renderer'), '.js')
    .filter((f) => !path.basename(f).startsWith('bedready'));
  const found = hits(files, [
    // ${escapeHtml(o.id)} as text — not as the value of an attribute.
    new RegExp(`(?<![a-z-]="\\$\\{)(?:escapeHtml|esc)\\(${V}\\.id\\)(?!\\}")`),
    // "the project, or failing that the id".
    new RegExp(`\\b(${V})\\.project \\|\\| \\1\\.id\\b`),
  ], ALLOWED);
  assert.deepEqual(found, [], 'show jobRef(order), not order.id:\n' + found.join('\n'));
});

test('lib pages and messages name a job by its number', () => {
  const files = walk(path.join(ROOT, 'lib'), '.js').filter((f) => !path.basename(f).startsWith('bedready'));
  const found = hits(files, [new RegExp(`\\b(${V})\\.project \\|\\| \\1\\.id\\b`)], ALLOWED);
  assert.deepEqual(found, [], 'use `o.jobNumber || o.id`:\n' + found.join('\n'));
});

test('the Mac and the phone show Order.reference, not the id', () => {
  const files = [
    ...walk(path.join(ROOT, 'mac/KhaytCore/Sources/KhaytApp'), '.swift'),
    ...walk(path.join(ROOT, 'ios/KhaytCompanion'), '.swift'),
  ].filter((f) => !f.includes('Tests'));
  const found = hits(files, [
    /Text\((?:job|order|quote)\.id\)/,
    /Text\("#\\\((?:job|order|quote)\.id\)/,
    /(?:job|order|o)\.project\.isEmpty \? (?:job|order|o)\.id :/,
  ], ALLOWED);
  assert.deepEqual(found, [], 'show `.reference`:\n' + found.join('\n'));
});

test('jobRef: the number when there is one, else the id', () => {
  global.printLog = [{ id: 'INV-2026-0042-k7qx', jobNumber: 'INV-2026-0042' }];
  const { jobRef } = require('../renderer/util.js');
  assert.equal(jobRef({ id: 'INV-2026-0042-k7qx', jobNumber: 'INV-2026-0042' }), 'INV-2026-0042');
  assert.equal(jobRef({ id: 'INV-2026-0007' }), 'INV-2026-0007', 'an older job is its id');
  assert.equal(jobRef('INV-2026-0042-k7qx'), 'INV-2026-0042', 'an id is looked up in the book');
  assert.equal(jobRef('GONE-1'), 'GONE-1', 'an id the book does not hold is shown as it is');
  assert.equal(jobRef(null), '');
  const N = require('../lib/order-new.js');
  assert.equal(N.jobRef({ id: 'a-b', jobNumber: 'a' }), 'a');
  assert.equal(N.jobRef({ id: 'a' }), 'a');
  delete global.printLog;
});
