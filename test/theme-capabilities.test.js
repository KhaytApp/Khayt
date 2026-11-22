const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {
  CAPABILITIES, THEMES, manifestFor, shows, differenceBetween, unexplainedOmissions,
} = require('../lib/theme-capabilities.js');

const THEMES_DIR = path.join(__dirname, '..', 'renderer', 'themes');
const src = (theme) => {
  const f = theme === 'base'
    ? path.join(__dirname, '..', 'renderer', 'dashboard.js')
    : path.join(THEMES_DIR, theme, 'screens.js');
  return fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '';
};

test('every shipped theme has a manifest', () => {
  // A theme without one is a theme whose omissions are invisible again, which is
  // the whole thing this file exists to stop.
  const shipped = fs.readdirSync(THEMES_DIR)
    .filter((d) => fs.existsSync(path.join(THEMES_DIR, d, 'tokens.css')))
    .filter((d) => d !== '_template');
  const missing = shipped.filter((t) => !THEMES[t]);
  assert.deepEqual(missing, [], `no capability manifest: ${missing.join(', ')}`);
});

test('every capability is answered — shown or omitted, never silent', () => {
  const caps = Object.keys(CAPABILITIES);
  const gaps = [];
  for (const [id, t] of Object.entries(THEMES)) {
    if (t.layout === 'base') continue;
    for (const c of caps) {
      const answered = (t.shows || []).includes(c) || Object.prototype.hasOwnProperty.call(t.omits || {}, c);
      if (!answered) gaps.push(`${id}: ${c}`);
    }
  }
  assert.deepEqual(gaps, [], `unanswered — declare it shown or omitted:\n  ${gaps.join('\n  ')}`);
});

test('a theme cannot both show and omit the same thing', () => {
  for (const [id, t] of Object.entries(THEMES)) {
    if (t.layout === 'base') continue;
    for (const c of t.shows || []) {
      assert.ok(!Object.prototype.hasOwnProperty.call(t.omits || {}, c), `${id} both shows and omits ${c}`);
    }
  }
});

test('no manifest names a capability that does not exist', () => {
  const caps = new Set(Object.keys(CAPABILITIES));
  for (const [id, t] of Object.entries(THEMES)) {
    if (t.layout === 'base') continue;
    for (const c of [...(t.shows || []), ...Object.keys(t.omits || {})]) {
      assert.ok(caps.has(c), `${id} names unknown capability "${c}"`);
    }
  }
});

/*
 * The manifest is a claim about what a layout renders, and a claim nothing
 * checks is a comment. These are the labels each layout actually prints, so a
 * theme that stops showing revenue but keeps saying it does will fail here.
 */
const LABEL_EVIDENCE = {
  revenue: /Revenue[ (—]|revenue_today|'Revenue/i,
  margin: /Avg margin|avg_margin|'Margin/i,
  receivables: /Unpaid|unpaid|Owed|owed|outstanding/,
  fleetUtilisation: /utilisation|utilization/i,
};

test('every "shows" claim is visible in the layout that makes it', () => {
  const liars = [];
  for (const [id, t] of Object.entries(THEMES)) {
    if (t.layout === 'base') continue;
    const code = src(id);
    if (!code) continue;
    for (const c of t.shows || []) {
      if (!LABEL_EVIDENCE[c].test(code)) liars.push(`${id} claims ${c}, no label for it in screens.js`);
    }
  }
  assert.deepEqual(liars, [], liars.join('\n'));
});

test('the base layout really does answer everything it is credited with', () => {
  // nocturne and blueprint inherit this, so an error here mislabels two themes.
  const code = src('base') + fs.readFileSync(path.join(__dirname, '..', 'renderer', 'locales', 'en.js'), 'utf8');
  for (const c of manifestFor('nocturne').shows) {
    assert.ok(LABEL_EVIDENCE[c].test(code), `base layout credited with ${c} but renders no label for it`);
  }
});

test('switching theme has a stateable cost', () => {
  // The user-facing payoff: the picker can warn BEFORE the switch instead of
  // leaving someone to notice months later that a number went away.
  const wbFromNocturne = differenceBetween('nocturne', 'workbench');
  assert.deepEqual(wbFromNocturne.lost.sort(), ['fleetUtilisation', 'margin', 'revenue']);
  assert.deepEqual(wbFromNocturne.gained, []);

  // Command is the only custom layout that keeps margin.
  assert.equal(shows('command', 'margin'), true);
  assert.equal(shows('vivid', 'margin'), false);
  assert.equal(shows('workbench', 'margin'), false);

  // Meridian is a schedule and answers none of the money questions — which is a
  // legitimate design, and now a declared one rather than a surprise.
  assert.deepEqual(manifestFor('meridian').shows, []);
  assert.deepEqual(differenceBetween('meridian', 'nocturne').gained.sort(),
    ['fleetUtilisation', 'margin', 'receivables', 'revenue']);

  // Same theme, no change.
  assert.deepEqual(differenceBetween('flow', 'flow'), { gained: [], lost: [] });
  // Unknown themes must not throw at a picker.
  assert.deepEqual(differenceBetween('nope', 'flow'), { gained: [], lost: [] });
  assert.equal(manifestFor('nope'), null);
});

test('unexplained omissions are reported, not invented (informational)', () => {
  // Four of six custom layouts never wrote down WHY they omit what they omit.
  // Putting words in their author's mouth would defeat the point of recording
  // reasoning at all, so they are counted and left. This does not fail — same
  // shape as the locale orphan report — but it stops the gap being invisible.
  const gaps = unexplainedOmissions();
  const byTheme = {};
  for (const g of gaps) (byTheme[g.theme] ||= []).push(g.capability);
  process.stdout.write(`\n  omissions with no recorded reason: ${gaps.length}\n`);
  for (const [t, caps] of Object.entries(byTheme)) process.stdout.write(`    ${t}: ${caps.join(', ')}\n`);

  // Workbench wrote its reason down, and it is the model for the rest.
  const wb = THEMES.workbench.omits.revenue;
  assert.equal(typeof wb, 'string');
  assert.ok(wb.length > 80, 'a reason worth recording says where the thing went');
  assert.ok(/Analytics/.test(wb), 'and names where to find it now');
  assert.ok(true);
});
