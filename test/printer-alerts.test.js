'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { computePrinterAlerts, isErrorState, isFailedPoll, isPrinting } = require('../lib/printer-alerts');

const MIN = 60 * 1000;
const T0 = 1_700_000_000_000;

// All toggles on, generous defaults so we can exercise each rule deterministically.
function fullSettings(over) {
  return {
    telegram: {
      botToken: 'x',
      chatId: 'y',
      notifyPrinterError: true,
      notifyPrinterOffline: true,
      notifyPrinterStall: true,
    },
    printerAlerts: {
      offlineThreshold: 3,
      stallMinutes: 15,
      cooldownMinutes: 30,
      ...(over && over.printerAlerts),
    },
    ...over,
  };
}

function types(res) {
  return res.alerts.map((a) => a.type).sort();
}

/* ── predicate helpers ───────────────────────────────────────── */

test('isPrinting / isErrorState / isFailedPoll predicates', () => {
  assert.equal(isPrinting('Printing'), true);
  assert.equal(isPrinting('printing'), true);
  assert.equal(isPrinting('Idle'), false);
  assert.equal(isErrorState({ state: 'Error' }), true);
  assert.equal(isErrorState({ state: 'Operational' }), false);
  assert.equal(isErrorState({ error: 'HTTP 500' }), true);
  assert.equal(isFailedPoll({ error: 'unreachable' }), true);
  assert.equal(isFailedPoll({ state: 'Printing' }), false);
});

/* ── error transitions ───────────────────────────────────────── */

test('error fires on transition into error state', () => {
  const prev = { m1: { state: 'Printing', progress: 40 } };
  const curr = { m1: { state: 'Error', progress: 40 } };
  const res = computePrinterAlerts(prev, curr, fullSettings(), T0);
  assert.deepEqual(types(res), ['error']);
  assert.match(res.alerts[0].message, /Printer error/);
});

test('error does NOT fire when already in error (no transition)', () => {
  const prev = { m1: { state: 'Error' } };
  const curr = { m1: { state: 'Error' } };
  const res = computePrinterAlerts(prev, curr, fullSettings(), T0);
  assert.deepEqual(types(res), []);
});

test('error does not fire when toggle off', () => {
  const s = fullSettings();
  s.telegram.notifyPrinterError = false;
  const prev = { m1: { state: 'Idle' } };
  const curr = { m1: { state: 'Error' } };
  const res = computePrinterAlerts(prev, curr, s, T0);
  assert.deepEqual(types(res), []);
});

test('a failed poll is reported as offline, not error (no double fire)', () => {
  // failCount reaches threshold in one shot via seeded state
  const state = { m1: { failCount: 2, cooldowns: {} } };
  const curr = { m1: { error: 'fetch failed' } };
  const res = computePrinterAlerts({}, curr, fullSettings(), T0, { alertState: state });
  assert.deepEqual(types(res), ['offline']);
});

/* ── offline threshold ───────────────────────────────────────── */

test('offline fires only after N consecutive failed polls', () => {
  const s = fullSettings();
  let st = {};
  const curr = { m1: { error: 'unreachable' } };

  let res = computePrinterAlerts({}, curr, s, T0, { alertState: st });
  assert.deepEqual(types(res), [], 'poll 1: no alert');
  st = res.state;

  res = computePrinterAlerts({}, curr, s, T0 + MIN, { alertState: st });
  assert.deepEqual(types(res), [], 'poll 2: no alert');
  st = res.state;

  res = computePrinterAlerts({}, curr, s, T0 + 2 * MIN, { alertState: st });
  assert.deepEqual(types(res), ['offline'], 'poll 3: offline fires');
});

test('failCount resets when a poll succeeds', () => {
  const s = fullSettings();
  let st = { m1: { failCount: 2, cooldowns: {} } };
  // success poll
  let res = computePrinterAlerts({}, { m1: { state: 'Idle' } }, s, T0, { alertState: st });
  assert.equal(res.state.m1.failCount, 0);
  st = res.state;
  // one fail is not enough now
  res = computePrinterAlerts({}, { m1: { error: 'x' } }, s, T0 + MIN, { alertState: st });
  assert.deepEqual(types(res), []);
});

test('offline respects configurable threshold', () => {
  const s = fullSettings({ printerAlerts: { offlineThreshold: 1 } });
  const res = computePrinterAlerts({}, { m1: { error: 'x' } }, s, T0);
  assert.deepEqual(types(res), ['offline']);
});

test('offline does not fire when toggle off', () => {
  const s = fullSettings({ printerAlerts: { offlineThreshold: 1 } });
  s.telegram.notifyPrinterOffline = false;
  const res = computePrinterAlerts({}, { m1: { error: 'x' } }, s, T0);
  assert.deepEqual(types(res), []);
});

/* ── stall detection ─────────────────────────────────────────── */

test('stall fires after progress stuck > X minutes while printing', () => {
  const s = fullSettings();
  let st = {};
  // first sighting at 50%
  let res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 50 } }, s, T0, { alertState: st });
  assert.deepEqual(types(res), []);
  st = res.state;
  // 16 minutes later, still 50%
  res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 50 } }, s, T0 + 16 * MIN, { alertState: st });
  assert.deepEqual(types(res), ['stall']);
  assert.match(res.alerts[0].message, /stalled/i);
});

test('stall does NOT fire while progress keeps advancing', () => {
  const s = fullSettings();
  let st = {};
  let res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 10 } }, s, T0, { alertState: st });
  st = res.state;
  res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 30 } }, s, T0 + 16 * MIN, { alertState: st });
  assert.deepEqual(types(res), []);
  // progress clock was reset
  assert.equal(res.state.m1.lastProgress, 30);
});

test('stall clock resets when printer leaves printing state', () => {
  const s = fullSettings();
  let st = {};
  let res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 50 } }, s, T0, { alertState: st });
  st = res.state;
  // goes idle
  res = computePrinterAlerts({}, { m1: { state: 'Idle', progress: 50 } }, s, T0 + 16 * MIN, { alertState: st });
  assert.equal(res.state.m1.lastProgressAt, null);
  assert.deepEqual(types(res), []);
});

test('stall does not fire when toggle off (default off)', () => {
  const s = fullSettings();
  s.telegram.notifyPrinterStall = false;
  let st = {};
  let res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 50 } }, s, T0, { alertState: st });
  st = res.state;
  res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 50 } }, s, T0 + 30 * MIN, { alertState: st });
  assert.deepEqual(types(res), []);
});

test('stall respects configurable stallMinutes', () => {
  const s = fullSettings({ printerAlerts: { stallMinutes: 5 } });
  let st = {};
  let res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 50 } }, s, T0, { alertState: st });
  st = res.state;
  res = computePrinterAlerts({}, { m1: { state: 'Printing', progress: 50 } }, s, T0 + 6 * MIN, { alertState: st });
  assert.deepEqual(types(res), ['stall']);
});

/* ── cooldown ─────────────────────────────────────────────────── */

test('cooldown prevents the same alert re-firing every poll', () => {
  const s = fullSettings({ printerAlerts: { offlineThreshold: 1, cooldownMinutes: 30 } });
  const curr = { m1: { error: 'x' } };
  let st = {};

  let res = computePrinterAlerts({}, curr, s, T0, { alertState: st });
  assert.deepEqual(types(res), ['offline'], 'first fires');
  st = res.state;

  // 10 min later — still within cooldown
  res = computePrinterAlerts({}, curr, s, T0 + 10 * MIN, { alertState: st });
  assert.deepEqual(types(res), [], 'suppressed by cooldown');
  st = res.state;

  // 31 min after the first — cooldown elapsed, fires again
  res = computePrinterAlerts({}, curr, s, T0 + 31 * MIN, { alertState: st });
  assert.deepEqual(types(res), ['offline'], 'fires again after cooldown');
});

test('cooldown is per-type (error vs offline independent)', () => {
  const s = fullSettings({ printerAlerts: { offlineThreshold: 1 } });
  // error fired recently, offline has never fired
  const st = { m1: { failCount: 0, cooldowns: { error: T0 } } };
  const prev = { m1: { state: 'Idle' } };
  const curr = { m1: { state: 'Error', error: 'unreachable' } };
  // failed poll => offline path; error cooldown irrelevant to offline
  const res = computePrinterAlerts(prev, curr, s, T0 + MIN, { alertState: st });
  assert.deepEqual(types(res), ['offline']);
});

/* ── multi-machine + general ─────────────────────────────────── */

test('handles multiple machines independently', () => {
  const s = fullSettings({ printerAlerts: { offlineThreshold: 1 } });
  const prev = { a: { state: 'Idle' }, b: { state: 'Printing' } };
  const curr = { a: { state: 'Error' }, b: { error: 'down' } };
  const res = computePrinterAlerts(prev, curr, s, T0);
  const byId = {};
  res.alerts.forEach((al) => (byId[al.machineId] = al.type));
  assert.equal(byId.a, 'error');
  assert.equal(byId.b, 'offline');
});

test('uses machine name from machines list when provided', () => {
  const s = fullSettings({ printerAlerts: { offlineThreshold: 1 } });
  const res = computePrinterAlerts({}, { m1: { error: 'x' } }, s, T0, {
    machines: [{ id: 'm1', name: 'Bambu X1C' }],
  });
  assert.match(res.alerts[0].message, /Bambu X1C/);
});

test('does not mutate the input alertState', () => {
  const s = fullSettings({ printerAlerts: { offlineThreshold: 1 } });
  const st = { m1: { failCount: 0, cooldowns: {} } };
  const snapshot = JSON.stringify(st);
  computePrinterAlerts({}, { m1: { error: 'x' } }, s, T0, { alertState: st });
  assert.equal(JSON.stringify(st), snapshot, 'input state unchanged');
});

test('empty caches produce no alerts', () => {
  const res = computePrinterAlerts({}, {}, fullSettings(), T0);
  assert.deepEqual(res.alerts, []);
  assert.deepEqual(res.state, {});
});

test('missing settings (undefined) → all toggles off, no alerts', () => {
  const res = computePrinterAlerts({}, { m1: { error: 'x' } }, undefined, T0, {
    alertState: { m1: { failCount: 9, cooldowns: {} } },
  });
  assert.deepEqual(types(res), []);
});

test('carries forward state for machines absent this poll', () => {
  const res = computePrinterAlerts({}, {}, fullSettings(), T0, {
    alertState: { gone: { failCount: 2, cooldowns: { offline: T0 } } },
  });
  assert.ok(res.state.gone, 'state preserved for vanished machine');
  assert.equal(res.state.gone.failCount, 2);
});

test('an install that configured Telegram before these keys existed still gets alerts', () => {
  // The old ternary was a no-op — both branches reduced to !!tg.notifyPrinterX — so the
  // toggles defaulted OFF while the settings UI rendered them CHECKED (`?? true`).
  // settings.js only seeds the keys when settings.telegram is entirely absent, so anyone
  // who set up Telegram earlier kept an object without them and never saw a single alert.
  const upgraded = { telegram: { botToken: 'b', chatId: 'c' } };
  const res = computePrinterAlerts({}, { m1: { error: 'x' } }, upgraded, T0, {
    alertState: { m1: { failCount: 9, cooldowns: {} } },
  });
  assert.ok(types(res).length > 0, 'an upgraded install must still receive printer alerts');
});

test('an explicit false still turns the toggle off', () => {
  const off = { telegram: { botToken: 'b', chatId: 'c', notifyPrinterOffline: false, notifyPrinterError: false } };
  const res = computePrinterAlerts({}, { m1: { error: 'x' } }, off, T0, {
    alertState: { m1: { failCount: 9, cooldowns: {} } },
  });
  assert.deepEqual(types(res), [], 'defaulting ON must not override an explicit opt-out');
});

/* ------------------------------------------------------------------
 * A caller whose transport is not Telegram.
 *
 * `resolveSettings` gates every alert on `settings.telegram` existing, which is
 * right when Telegram is the transport and wrong when it is not. The native Mac
 * app raises a notification on the machine the shop is sitting at; a shop with
 * no bot would otherwise have been told nothing at all — including that its
 * printer had gone offline mid-print at two in the morning.
 * ------------------------------------------------------------------ */

test('enable overrides the Telegram toggles for another transport', () => {
  const curr = { 'M-1': { error: 'unreachable' } };
  const noBot = {};   // a shop with no Telegram at all

  // Today's behaviour, unchanged: no transport, no alerts.
  const silent = computePrinterAlerts({}, curr, noBot, T0, {
    alertState: { 'M-1': { failCount: 5 } },
  });
  assert.deepEqual(silent.alerts, []);

  // …and with a transport of its own, the same poll fires.
  const spoken = computePrinterAlerts({}, curr, noBot, T0, {
    alertState: { 'M-1': { failCount: 5 } },
    enable: { error: true, offline: true, stall: false },
  });
  assert.equal(spoken.alerts.length, 1);
  assert.equal(spoken.alerts[0].type, 'offline');
});

test('enable can also turn one off', () => {
  // It replaces all three rather than adding to them, so a caller that wants
  // only errors gets only errors — a stall it did not ask for is a notification
  // at 3am about a printer that is fine.
  const curr = { 'M-1': { error: 'unreachable' } };
  const out = computePrinterAlerts({}, curr, { telegram: {} }, T0, {
    alertState: { 'M-1': { failCount: 9 } },
    enable: { error: true, offline: false, stall: false },
  });
  assert.deepEqual(out.alerts, []);
});

test('an absent enable leaves the Telegram behaviour exactly as it was', () => {
  const curr = { 'M-1': { error: 'unreachable' } };
  const withBot = { telegram: { botToken: 'x' } };
  const a = computePrinterAlerts({}, curr, withBot, T0, { alertState: { 'M-1': { failCount: 5 } } });
  const b = computePrinterAlerts({}, curr, withBot, T0,
    { alertState: { 'M-1': { failCount: 5 } }, enable: undefined });
  assert.deepEqual(a.alerts, b.alerts);
  assert.equal(a.alerts.length, 1);
});

/* ── runout: the machine said it itself ──────────────────────── */

const M = 'MACH-1';
const printing = (over) => ({ [M]: { state: 'Printing', progress: 47, filename: 'a.gcode', ...over } });

test('a runout on the printing head raises a runout, not a stall', () => {
  // The stall clock has been running for an hour: without the runout rule this
  // machine reports 'stall', which is true and the wrong errand.
  const st = { [M]: { lastProgress: 47, lastProgressAt: T0 - 60 * MIN, cooldowns: {} } };
  const res = computePrinterAlerts(printing({ filamentOut: false }), printing({ filamentOut: true }),
    fullSettings(), T0, { alertState: st });
  assert.deepEqual(types(res), ['runout'],
    'the shop was told twice about one thing, once uselessly');
  assert.match(res.alerts[0].message, /Out of filament/);
});

test('refilled and still not moving stalls on schedule', () => {
  // The clock kept running while the machine was out, so a print that is fed
  // and still stuck does not get a fresh fifteen minutes of silence.
  const st = { [M]: { lastProgress: 47, lastProgressAt: T0 - 60 * MIN, cooldowns: {} } };
  const res = computePrinterAlerts(printing({ filamentOut: true }), printing({ filamentOut: false }),
    fullSettings(), T0, { alertState: st });
  assert.deepEqual(types(res), ['stall']);
});

test('a loaded machine and a machine with no sensor both stay quiet', () => {
  const prev = printing({ filamentOut: false });
  assert.deepEqual(types(computePrinterAlerts(prev, printing({ filamentOut: false }), fullSettings(), T0)), []);
  // null is "cannot tell", which is not "needs you".
  assert.deepEqual(types(computePrinterAlerts(prev, printing({ filamentOut: null }), fullSettings(), T0)), []);
  assert.deepEqual(types(computePrinterAlerts(prev, printing({}), fullSettings(), T0)), []);
});

test('a runout fires on the edge, not on every poll while it lasts', () => {
  const s = fullSettings();
  const out = printing({ filamentOut: true });
  let st = {};

  let res = computePrinterAlerts(printing({ filamentOut: false }), out, s, T0, { alertState: st });
  assert.deepEqual(types(res), ['runout'], 'first fires');
  st = res.state;

  // Still out one poll later, and the shop already knows.
  res = computePrinterAlerts(out, out, s, T0 + MIN, { alertState: st });
  assert.deepEqual(types(res), [], 'it shouted every poll until somebody noticed');
});

test('the runout alert can be switched off like the others', () => {
  const res = computePrinterAlerts(printing({ filamentOut: false }), printing({ filamentOut: true }),
    fullSettings(), T0, { enable: { error: true, offline: true, stall: true, runout: false } });
  assert.deepEqual(types(res), []);
});
