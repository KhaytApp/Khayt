'use strict';
/**
 * "Finished" has two spellings, and the renderer has to know that everywhere.
 *
 * A job a shop has finished is `status: 'completed'`. A job finished in an
 * older book — or one advanced through the delivery step — is
 * `status: 'delivered'`. `KhaytOrderStatus.isFinished` is the one place that
 * knows both, and `FINISHED_STATUSES` is the list.
 *
 * Asking `o.status === 'completed'` therefore answers a narrower question than
 * the code around it means, and it fails in both directions:
 *
 *   - Counting finished work drops every delivered job. Revenue, month totals,
 *     the client's lifetime spend, loyalty points, the VAT return, the
 *     accounting export.
 *   - Counting UNfinished work (`!== 'completed'`) picks every delivered job
 *     up. Active orders, the queue, WIP limits, overdue badges.
 *
 * A first sweep fixed 22 of these. It missed about 45 more, including the
 * revenue bar chart and the accounting journal — because it was done by
 * reading, and reading is how the next one gets missed too.
 *
 * So this is a ratchet rather than a review. Any `=== 'completed'` or
 * `!== 'completed'` in the renderer fails unless the same line also names
 * `'delivered'`, or the site is listed below with a reason it is genuinely
 * asking about that one status.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RENDERER = path.join(ROOT, 'renderer');

/**
 * Sites that mean `completed` and only `completed`.
 *
 * Each is matched by a distinctive piece of the line, so the list survives the
 * file moving around. Adding to it should take a sentence explaining why the
 * other spelling does not belong — if that sentence is hard to write, the site
 * is a bug rather than an exception.
 */
const ALLOWED = [
  {
    file: 'invoicing.js',
    snippet: "order.status = order.status === 'completed' ? 'completed' : order.status;",
    why: 'Writes the status back unchanged. Reads nothing about the job.',
  },
  {
    file: 'kanban.js',
    snippet: "if (status === 'completed') {",
    why: 'Offers the "Mark delivered" button, which a delivered job must not be offered.',
  },
  {
    file: 'logs.js',
    snippet: "{ danger: status === 'completed' || status === 'on_hold' }",
    why: 'The status a bulk move is heading TO, not the state of a job.',
  },
  {
    file: 'bedready-queue.js',
    snippet: "if (newStatus === 'completed' && typeof brOfferActuals === 'function') {",
    why: 'The status a card is being moved TO, which is what decides whether to offer actuals.',
  },
  {
    file: 'logs.js',
    snippet: "if (status === 'completed') {",
    why: 'The status a bulk move is heading TO: it stamps completedAt and deducts stock.',
  },
];

/** Every renderer script, themes included; translations are data, not logic. */
function rendererFiles(dir = RENDERER, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'locales' || entry.name === 'node_modules') continue;
      rendererFiles(full, out);
    } else if (entry.name.endsWith('.js')) {
      out.push(full);
    }
  }
  return out;
}

/** A line that is only a comment cannot ask a question about a job. */
function isComment(line) {
  const t = line.trim();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
}

test('the renderer asks whether a job is finished, not whether it says "completed"', () => {
  const offences = [];
  for (const file of rendererFiles()) {
    const rel = path.relative(ROOT, file);
    const base = path.basename(file);
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, i) => {
      // The left operand has to be a job's status: `o.status`, or a local
      // holding one. `s.key === 'completed'` is a bucket label in a breakdown,
      // not a question about a job, and matching it would only teach people to
      // pad the exception list.
      if (!/(?:\w+\.status|\b(?:status|newStatus|newState|nextStatus))\s*[!=]==\s*'completed'/.test(line)) return;
      if (isComment(line)) return;
      // The line names both spellings itself, so it already knows.
      if (line.includes("'delivered'")) return;
      const allowed = ALLOWED.some(a => a.file === base && line.includes(a.snippet));
      if (allowed) return;
      offences.push(`${rel}:${i + 1}  ${line.trim().slice(0, 100)}`);
    });
  }
  assert.deepEqual(offences, [],
    'use KhaytOrderStatus.isFinished(order) — or add the site to ALLOWED with a reason:\n'
    + offences.join('\n'));
});

test('every allowed exception still exists, so the list cannot rot', () => {
  for (const a of ALLOWED) {
    const matches = rendererFiles()
      .filter(f => path.basename(f) === a.file)
      .filter(f => fs.readFileSync(f, 'utf8').includes(a.snippet));
    assert.ok(matches.length > 0,
      `ALLOWED entry for ${a.file} matches nothing any more — delete it: ${a.snippet}`);
  }
});

test('every exception says why', () => {
  for (const a of ALLOWED) {
    assert.ok(a.why && a.why.length > 20, `${a.file}: ${a.snippet}`);
  }
});

/* ------------------------------------------------------------------
   The rule itself, so the ratchet is pointing at something true.
   ------------------------------------------------------------------ */

test('both spellings are finished and nothing else is', () => {
  const OS = require('../lib/order-status.js');
  assert.deepEqual(OS.FINISHED_STATUSES, ['completed', 'delivered']);
  assert.equal(OS.isFinished({ status: 'completed' }), true);
  assert.equal(OS.isFinished({ status: 'delivered' }), true);
  for (const st of ['quote', 'pending', 'printing', 'post', 'qc', 'on_hold', 'cancelled']) {
    assert.equal(OS.isFinished({ status: st }), false, st);
  }
  assert.equal(OS.isFinished({}), false);
  assert.equal(OS.isFinished(null), false);
  assert.equal(OS.isFinished(undefined), false);
});
