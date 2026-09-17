'use strict';
/**
 * A figure measured AGAINST A TARGET is never capped at its target.
 *
 * ── THE NARROW RULE, AND WHY IT IS NARROW ─────────────────────────────────
 *
 * Most percentages in Khayt cannot exceed 100 by their nature: a print's
 * progress, a discount, a share of a total. Clamping those is harmless and
 * often just defensive. This is NOT about those, and a test that flagged them
 * would be thirty-nine entries of noise that nobody reads.
 *
 * It is about the one shape that broke three separate times: hours run against
 * hours WANTED. A printer can run half as much again as it is meant to, and
 * that excess is the entire reason the figure exists — it is how a shop finds
 * the machine worth buying a second of. `Math.min(100, …)` draws it
 * identically to a machine that hit its target exactly, and the capped number
 * looks completely plausible, which is why it survived three rewrites of the
 * screens around it.
 *
 * The rule is: CLAMP THE BAR, NEVER THE NUMBER. A bar cannot be wider than its
 * track, so a width is clamped as geometry. The figure beside it stays true.
 *
 * This is the grep, committed, in the pattern [[sweep-with-a-ratchet]]
 * describes: an allow-list entry has to carry a reason.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');

/** Lines that clamp a utilisation figure for a good reason. Empty on purpose. */
const ALLOWED = new Map();

/** What makes a line one of THESE percentages rather than any other. */
const ABOUT_A_TARGET = /utili[sz]|targetHours|overbooked|loadPct/i;

function sourceFiles() {
  return execFileSync('git', ['ls-files', 'renderer/*.js', 'renderer/**/*.js', 'lib/*.js'],
                      { cwd: ROOT }).toString().split('\n').filter(Boolean);
}

test('a utilisation figure is never capped at its target', () => {
  const offenders = [];
  for (const rel of sourceFiles()) {
    fs.readFileSync(path.join(ROOT, rel), 'utf8').split('\n').forEach((line, i) => {
      if (/^\s*(\/\/|\*|\/\*)/.test(line)) return;           // documentation, incl. this rule
      if (!/Math\.min\(\s*100\s*,/.test(line)) return;
      if (!ABOUT_A_TARGET.test(line)) return;
      if (ALLOWED.has(line.trim())) return;
      offenders.push(`${rel}:${i + 1}  ${line.trim()}`);
    });
  }
  assert.deepEqual(offenders, [],
    'a figure measured against a target is capped at it. Clamp the BAR WIDTH instead '
    + 'and print the true number, or add the line to ALLOWED with its reason:\n  '
    + offenders.join('\n  '));
});

test('the rule that computes it does not cap it either', () => {
  // The source scan above only sees the screens. This is the rule they all
  // read now, so it is the one place the cap could come back invisibly.
  const { machineProfit } = require('../lib/machine-pl.js');
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1', targetHoursPerDay: 4 }],
    completed: [{ id: 'a', machineId: 'M1', price: 1, printTime: 80 }],
    days: 10,
  }, { revenueOf: (o) => +o.price || 0, partCostOf: () => 0 });
  assert.equal(rows[0].utilisationPct, 200, 'the rule capped a machine at its target');
});

test('the allow-list has no dead entries', () => {
  // An allow-list that outlives the line it excused quietly permits the next
  // one that happens to match it.
  const everyLine = new Set();
  for (const rel of sourceFiles()) {
    for (const line of fs.readFileSync(path.join(ROOT, rel), 'utf8').split('\n')) {
      everyLine.add(line.trim());
    }
  }
  for (const excused of ALLOWED.keys()) {
    assert.ok(everyLine.has(excused), `ALLOWED excuses a line nothing has: ${excused}`);
  }
});
