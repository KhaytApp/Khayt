'use strict';
/**
 * U1 idea 5: a Snapmaker U1's exception_manager and power_loss_check as a
 * closed list, toward batch 2's C3 catalogue (lib/moonraker-problems.js).
 * The 523 row is the shape the shop's U1 reported (Nov 19); the rest synthetic.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/moonraker-problems.js');

test('523 is a filament runout on the head the printer names (e1 = the second head)', () => {
  assert.deepEqual(M.problems({ exception_manager: { exceptions: [{ id: 523, index: null, code: 0, level: 2, message: 'e1_filament runout' }] } }),
    [{ kind: 'exception', code: 'filament-runout', severity: 'serious', head: 1, id: 523 }]);
  assert.equal(M.problems({ exception_manager: { exceptions: [{ id: 523, index: 3, level: 2, message: 'e1_filament runout' }] } })[0].head, 1, '`index` is not read as a head');
  assert.equal(M.problems({ exception_manager: { exceptions: [{ id: 523, index: 3, level: 2, message: 'filament runout' }] } })[0].head, null, 'no eN_: no head guessed');
});

test('an id Khayt has no words for shows the printer\'s message, its level as the severity', () => {
  assert.deepEqual(M.problems({ exception_manager: { exceptions: [{ id: 901, level: 3, message: 'e0_heater fault' }] } }),
    [{ kind: 'exception', code: 'printer-exception', severity: 'fatal', head: 0, id: 901, message: 'e0_heater fault' }]);
  assert.equal(M.problems({ exception_manager: { exceptions: [{ id: 902, level: 7, message: 'x' }] } })[0].severity, 'fatal');
  assert.equal(M.problems({ exception_manager: { exceptions: [{ id: 903, level: 'x', message: 'y' }] } })[0].severity, 'info', 'an unknown level is info, never dropped');
});

test('power lost mid-print is information only', () => {
  assert.deepEqual(M.problems({ power_loss_check: { power_loss_flag: true, initialized: true } }), [{ kind: 'power-loss', code: 'power-lost', severity: 'info' }]);
  assert.deepEqual(M.problems({ power_loss_check: { power_loss_flag: false } }), []);
  assert.deepEqual(M.problems({ power_loss_check: { power_loss_flag: 'true' } }), [], 'only true counts');
});

test('worst first, then by head; the same exception twice is one row', () => {
  const r = M.problems({
    power_loss_check: { power_loss_flag: true },
    exception_manager: { exceptions: [
      { id: 523, level: 2, message: 'e2_filament runout' },
      { id: 901, level: 3, message: 'e0_x' },
      { id: 523, level: 2, message: 'e0_filament runout' },
      { id: 523, level: 2, message: 'e0_filament runout' },
    ] },
  });
  assert.deepEqual(r.map((x) => [x.code, x.head ?? null]), [['printer-exception', 0], ['filament-runout', 0], ['filament-runout', 2], ['power-lost', null]]);
});

test('closed sets, and junk in, nothing thrown', () => {
  for (const s of [null, 'x', [], {}, { exception_manager: 'x' }, { exception_manager: { exceptions: [null, 'x', { id: 'a' }, {}] } }]) {
    assert.deepEqual(M.problems(s), [], JSON.stringify(s));
  }
  const many = M.problems({ exception_manager: { exceptions: Array.from({ length: 100 }, (_, i) => ({ id: 1000 + i, level: 1, message: 'm' })) } });
  assert.equal(many.length, 32, 'at most 32 read');
  const ctl = M.problems({ exception_manager: { exceptions: [{ id: 904, level: 1, message: 'a\u0000b' + 'z'.repeat(500) }] } })[0];
  assert.ok(!/\u0000/.test(ctl.message) && ctl.message.length <= 200);
  for (const f of many) { assert.ok(M.CODES.includes(f.code)); assert.ok(M.SEVERITIES.includes(f.severity)); }
});
