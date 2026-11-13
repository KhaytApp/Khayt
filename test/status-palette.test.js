'use strict';
/**
 * One status palette, shared by every theme (decided Nov 11 2026): steel
 * waiting, amber printing, green done and paid, red late only. The colours
 * live once, as --st-* tokens in renderer/styles.css. The e2e
 * (scripts/e2e-status-palette-smoke.mjs) measures the chips on screen; this
 * guards the rule that keeps them single: no design theme may define a
 * --st-* token or colour a status selector of its own. Before this, UNPAID
 * was red in seven themes and amber in two, and PRINTING was green, blue,
 * indigo or invisible depending on the theme.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const THEMES = path.join(ROOT, 'renderer', 'themes');

function themeCssFiles() {
  const out = [];
  for (const d of fs.readdirSync(THEMES, { withFileTypes: true })) {
    if (!d.isDirectory() || d.name.startsWith('_')) continue;
    for (const f of fs.readdirSync(path.join(THEMES, d.name))) {
      if (f.endsWith('.css')) out.push(path.join(THEMES, d.name, f));
    }
  }
  for (const f of fs.readdirSync(THEMES)) if (f.endsWith('.css')) out.push(path.join(THEMES, f));
  return out;
}

const STATUS = '(?:pending|quote|on_hold|cancelled|printing|post|qc|completed|delivered|shipped|overdue|late|failed|pay-paid|pay-unpaid|pay-partial|pay-voided)';
const STATUS_SELECTORS = [
  new RegExp(`\\.badge\\.${STATUS}\\b`),
  /\.kanban-col\[data-status/,
  /\.due-badge\.(?:overdue|due-today|due-soon|due-ok)\b/,
  /\.part-status-(?:badge|dot)\.(?:pending|printing|done|failed)\b/,
];

/** [selector, body] pairs of a stylesheet, comments stripped. */
function rules(css) {
  const clean = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const out = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m;
  while ((m = re.exec(clean))) out.push([m[1].trim(), m[2]]);
  return out;
}

test('styles.css defines every status token for light and dark', () => {
  const css = fs.readFileSync(path.join(ROOT, 'renderer', 'styles.css'), 'utf8');
  const blocks = rules(css);
  const light = blocks.find(([sel, body]) => sel === ':root' && body.includes('--st-move-bg'));
  const dark = blocks.find(([sel, body]) => sel === 'html[data-theme="dark"]' && body.includes('--st-move-bg'));
  assert.ok(light, 'a :root block defines the status tokens');
  assert.ok(dark, 'an html[data-theme="dark"] block redefines them');
  for (const tone of ['wait', 'move', 'done', 'late', 'unpaid']) {
    for (const part of ['bg', 'ink', 'dot']) {
      const name = `--st-${tone}-${part}`;
      assert.match(light[1], new RegExp(`${name}\\s*:`), `${name} (light)`);
      assert.match(dark[1], new RegExp(`${name}\\s*:`), `${name} (dark)`);
    }
  }
  // The decided values.
  assert.match(light[1], /--st-move-bg:\s*#fdf1de/i);
  assert.match(light[1], /--st-move-ink:\s*#9a5b00/i);
  assert.match(light[1], /--st-move-dot:\s*#f2a541/i);
  assert.match(light[1], /--st-wait-bg:\s*#edf0f4/i);
  assert.match(light[1], /--st-wait-ink:\s*#5e6c84/i);
  assert.match(light[1], /--st-done-dot:\s*#1bb55c/i);
  assert.match(dark[1], /--st-move-bg:\s*#3a2c14/i);
  assert.match(dark[1], /--st-wait-bg:\s*#3a4658/i);
  assert.match(dark[1], /--st-wait-ink:\s*#a9b8cf/i);
  assert.match(dark[1], /--st-done-dot:\s*#34d27a/i);
});

test('no design theme defines or overrides a status token', () => {
  const offenders = [];
  for (const file of themeCssFiles()) {
    const css = fs.readFileSync(file, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    const re = /(--st-[a-z-]+)\s*:/g;
    let m;
    while ((m = re.exec(css))) offenders.push(`${path.relative(ROOT, file)}: ${m[1]}`);
  }
  assert.deepStrictEqual(offenders, []);
});

test('no design theme colours a status selector itself', () => {
  const offenders = [];
  for (const file of themeCssFiles()) {
    for (const [sel, body] of rules(fs.readFileSync(file, 'utf8'))) {
      if (!STATUS_SELECTORS.some((re) => re.test(sel))) continue;
      if (/(?:^|;)\s*(?:color|background(?:-color)?|--badge-dot)\s*:/.test(body)) {
        offenders.push(`${path.relative(ROOT, file)}: ${sel.replace(/\s+/g, ' ')}`);
      }
    }
  }
  assert.deepStrictEqual(offenders, []);
});

test('statusToneOf: printing amber, done/delivered green, waiting steel, late red', () => {
  const { statusToneOf } = require('../renderer/app-helpers.js');
  assert.strictEqual(statusToneOf('printing'), 'move');
  assert.strictEqual(statusToneOf('post'), 'move');
  assert.strictEqual(statusToneOf('qc'), 'move');
  for (const s of ['completed', 'delivered', 'shipped']) assert.strictEqual(statusToneOf(s), 'done', s);
  for (const s of ['pending', 'quote', 'on_hold', 'cancelled', undefined]) assert.strictEqual(statusToneOf(s), 'wait', String(s));
  assert.strictEqual(statusToneOf('overdue'), 'late');
});

test('marginToneOf: red only for a loss, amber when thin, steel otherwise', () => {
  const { marginToneOf } = require('../renderer/app-helpers.js');
  assert.strictEqual(marginToneOf(23, 0), 'ok', 'an ordinary 23% margin is not an error');
  assert.strictEqual(marginToneOf(45, 0), 'ok');
  assert.strictEqual(marginToneOf(12, 0), 'thin', 'under 20% with no shop minimum');
  assert.strictEqual(marginToneOf(25, 30), 'thin', 'under the shop minimum');
  assert.strictEqual(marginToneOf(0, 0), 'thin');
  assert.strictEqual(marginToneOf(-5, 0), 'loss');
  assert.strictEqual(marginToneOf(NaN, 0), 'ok');
});
