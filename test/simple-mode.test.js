'use strict';
/**
 * renderer/simple-mode.js — the desktop's reader of SIMPLE_MAP (S4).
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const SM = require('../renderer/simple-mode.js');
const { SIMPLE_MAP } = require('../lib/feature-tiers.js');

test('Professional shows every row', () => {
  for (const r of SIMPLE_MAP) assert.strictEqual(SM.shows(r.key, 'professional'), true, r.key);
  assert.strictEqual(SM.shows('schedule', undefined), true, 'no mode = Professional');
});

test("Simple hides exactly the 'pro' rows, plus what waits for its design", () => {
  for (const r of SIMPLE_MAP) {
    const want = r.simple !== 'pro' && !(r.key in SM.UNTIL_DESIGNED);
    assert.strictEqual(SM.shows(r.key, 'simple'), want, r.key);
  }
  for (const k of ['schedule', 'kiosk', 'campaigns', 'team', 'staffPins', 'sites', 'ai', 'developer', 'zatca', 'machineUpkeep', 'proforma', 'paymentPlans']) {
    assert.strictEqual(SM.shows(k, 'simple'), false, k);
  }
  for (const k of ['loyalty', 'connectors', 'messages', 'money', 'endOfDay']) assert.strictEqual(SM.shows(k, 'simple'), true, k);
  assert.strictEqual(SM.shows('not-a-row', 'simple'), true, 'an unknown key is shown');
});

test('Expenses is the short list in Simple, not the "Part of Professional" panel (S4 card 4)', () => {
  assert.strictEqual(SIMPLE_MAP.find((r) => r.key === 'expenses').simple, 'reduced');
  assert.strictEqual(SM.decision('expenses'), 'reduced');
  assert.strictEqual(SM.shows('expenses', 'simple'), true);
  assert.strictEqual(SM.tabGate('expenses-tab', 'simple'), null);
});

test('only Simple gates tabs and panes; enthusiast keeps its redirects', () => {
  for (const mode of ['professional', 'enthusiast']) {
    assert.strictEqual(SM.tabGate('expenses-tab', mode), null, mode);
    assert.strictEqual(SM.paneGate('team', mode), null, mode);
  }
  assert.strictEqual(SM.paneGate('team', 'simple'), 'team');
  assert.strictEqual(SM.paneGate('ai', 'simple'), 'ai');
  assert.strictEqual(SM.paneGate('notify', 'simple'), null, 'Messages is reduced in Simple, not gated');
  assert.strictEqual(SM.paneGate('connections', 'simple'), null);
  assert.strictEqual(SM.tabGate('analytics-tab', 'simple'), null, 'Money keeps its Simple view');
});

test('every gated tab and pane names a row that hides in Simple', () => {
  for (const key of [...Object.values(SM.TAB_KEYS), ...Object.values(SM.PANE_KEYS)]) {
    assert.ok(SIMPLE_MAP.some((r) => r.key === key), key);
    assert.strictEqual(SM.shows(key, 'simple'), false, key);
  }
});

test('the gated panel follows S4 card 2: names the screen, says Simple, offers the switch', () => {
  global.t = (k, v) => ({
    'sm.gated_title': `${v && v.feature} is part of Professional`,
    'sm.gated_body': 'This shop is set to Simple.',
    'sm.gated_open': `Open ${v && v.screen}`,
    'sm.eq_test': 'The Money page has what is owed.',
    'tab.money': 'Money',
  }[k] || k);
  global.escapeHtml = (s) => String(s).replace(/</g, '&lt;');
  try {
    const html = SM.gatedHtml('<Team>', 'team');
    assert.match(html, /&lt;Team> is part of Professional/);
    assert.match(html, /This shop is set to Simple\.<\/p>/);
    assert.match(html, /data-act="sm-switch-pro"/);
    assert.doesNotMatch(html, /sm-open-simple/, 'no "Open …" without a Simple equivalent');
    // With an equivalent: its line, and a secondary button before the switch.
    SM.EQUIVALENTS.team = { line: 'sm.eq_test', name: 'tab.money', tab: 'analytics-tab' };
    const withEq = SM.gatedHtml('Team', 'team');
    assert.match(withEq, /This shop is set to Simple\. The Money page has what is owed\./);
    assert.ok(withEq.indexOf('sm-open-simple') > 0 && withEq.indexOf('sm-open-simple') < withEq.indexOf('sm-switch-pro'));
    assert.match(withEq, />Open Money</);
  } finally { delete SM.EQUIVALENTS.team; delete global.t; delete global.escapeHtml; }
});

test('switchToProfessional switches the mode the way the General cards do', () => {
  const calls = [];
  global.settings = { mode: 'simple' };
  global.saveAll = () => calls.push('save');
  global.applyMode = () => calls.push('apply:' + global.settings.mode);
  try {
    SM.switchToProfessional();
    assert.strictEqual(global.settings.mode, 'professional');
    assert.deepStrictEqual(calls, ['save', 'apply:professional']);
    assert.strictEqual(SM.simpleShows('kiosk'), true);
    global.settings.mode = 'simple';
    assert.strictEqual(SM.simpleShows('kiosk'), false);
  } finally { delete global.settings; delete global.saveAll; delete global.applyMode; }
});

test('every data-simple-pro marker names a row Simple trims', () => {
  const dir = path.join(__dirname, '..', 'renderer');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js') || f === 'index.html');
  let seen = 0;
  for (const f of files) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const m of src.matchAll(/data-simple-pro="([A-Za-z]+)"/g)) {
      seen++;
      const row = SIMPLE_MAP.find((r) => r.key === m[1]);
      assert.ok(row, `${f}: data-simple-pro="${m[1]}" is not a SIMPLE_MAP row`);
      assert.ok(row.simple === 'pro' || row.simple === 'reduced', `${f}: ${m[1]} is '${row.simple}' — nothing to trim`);
    }
  }
  assert.ok(seen >= 10, `found ${seen} markers`);
});
