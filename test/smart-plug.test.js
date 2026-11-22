'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const SP = require('../lib/smart-plug');

// No plug on the bench: the vendors' documented answers are the fixture.
const M = (smartPlug) => ({ id: 'M1', name: 'CORE One', smartPlug });

test('each kind reads and switches the way its maker documents', () => {
  const shelly = M({ type: 'shelly', host: '192.168.1.40' });
  assert.equal(SP.request(shelly, 'status').url, 'http://192.168.1.40/relay/0');
  assert.equal(SP.request(shelly, 'off').url, 'http://192.168.1.40/relay/0?turn=off');

  const plus = M({ type: 'shelly-rpc', host: 'http://plug.local/' });
  assert.equal(SP.request(plus, 'status').url, 'http://plug.local/rpc/Switch.GetStatus?id=0');
  assert.equal(SP.request(plus, 'on').url, 'http://plug.local/rpc/Switch.Set?id=0&on=true');

  const tas = M({ type: 'tasmota', host: '10.0.0.7', user: 'admin', password: 'p w' });
  assert.equal(SP.request(tas, 'off').url, 'http://10.0.0.7/cm?cmnd=Power%20Off&user=admin&password=p%20w');

  const ha = M({ type: 'homeassistant', host: 'http://ha.local:8123', entity: 'switch.core_one', token: 'T' });
  const off = SP.request(ha, 'off');
  assert.equal(off.method, 'POST');
  assert.equal(off.url, 'http://ha.local:8123/api/services/switch/turn_off');
  assert.equal(off.headers.Authorization, 'Bearer T');
  assert.deepEqual(JSON.parse(off.body), { entity_id: 'switch.core_one' });
  // A plug entity in the `light` domain switches through `light`, not `switch`.
  const lamp = M({ type: 'homeassistant', host: 'ha', entity: 'light.enclosure', token: 'T' });
  assert.equal(SP.request(lamp, 'on').url, 'http://ha/api/services/light/turn_on');
});

test('an unusable plug builds nothing', () => {
  assert.equal(SP.request(M(null), 'off'), null);
  assert.equal(SP.request(M({ type: 'x10', host: 'a' }), 'off'), null);
  assert.equal(SP.request(M({ type: 'shelly', host: '' }), 'off'), null);
  assert.equal(SP.request(M({ type: 'homeassistant', host: 'ha', entity: 'switch.a' }), 'off'), null, 'no token');
  assert.equal(SP.request(M({ type: 'shelly', host: 'a' }), 'explode'), null);
});

test('answers read as on, off or unknown, with the draw where the plug measures it', () => {
  assert.deepEqual(SP.readAnswer(M({ type: 'shelly', host: 'a' }),
    { ison: false, has_timer: false, overpower: false, source: 'http' }), { on: false, watts: null });
  assert.deepEqual(SP.readAnswer(M({ type: 'shelly-rpc', host: 'a' }),
    { id: 0, source: 'init', output: true, apower: 87.4, voltage: 233.6 }), { on: true, watts: 87.4 });
  assert.deepEqual(SP.readAnswer(M({ type: 'tasmota', host: 'a' }), { POWER: 'OFF' }), { on: false, watts: null });
  const ha = M({ type: 'homeassistant', host: 'h', entity: 'switch.core_one', token: 'T' });
  assert.deepEqual(SP.readAnswer(ha, { entity_id: 'switch.core_one', state: 'on',
    attributes: { current_power_w: 25.3 } }), { on: true, watts: 25.3 });
  // A service call answers with the states it changed.
  assert.deepEqual(SP.readAnswer(ha, [{ entity_id: 'switch.core_one', state: 'off', attributes: {} }]),
    { on: false, watts: null });
  assert.deepEqual(SP.readAnswer(ha, { state: 'unavailable' }), { on: null, watts: null });
});

test('power is never cut while printing, paused, silent, or hot', () => {
  assert.equal(SP.canTurnOff({ state: 'printing', tempNozzle: 215 }).reason, 'plug.printing');
  assert.equal(SP.canTurnOff({ state: 'Paused', tempNozzle: 30 }).reason, 'plug.printing');
  // A failed poll keeps the last state: it may be printing on a bad link.
  assert.equal(SP.canTurnOff({ state: 'idle', error: 'ECONNREFUSED' }).reason, 'plug.not_answering');
  assert.equal(SP.canTurnOff(null).reason, 'plug.no_reading');
  assert.equal(SP.canTurnOff({ state: 'standby', tempNozzle: 120 }).reason, 'plug.hot');
  assert.deepEqual(SP.canTurnOff({ state: 'standby', tempNozzle: 32 }), { ok: true });
  assert.deepEqual(SP.canTurnOff({ state: 'idle' }), { ok: true }, 'no temperature reported is not a reason to refuse');
});

test('switching off after a print waits for the delay and for the rule', () => {
  const m = M({ type: 'shelly', host: 'a', autoOff: true, delayMin: 10 });
  const done = 1_000_000;
  const cool = { state: 'standby', tempNozzle: 30 };
  assert.equal(SP.autoOffDue(m, cool, done, done + 9 * 60000), false, 'too soon');
  assert.equal(SP.autoOffDue(m, cool, done, done + 10 * 60000), true);
  assert.equal(SP.autoOffDue(m, { state: 'printing', tempNozzle: 210 }, done, done + 60 * 60000), false,
    'a new print started in the meantime');
  assert.equal(SP.autoOffDue(M({ type: 'shelly', host: 'a' }), cool, done, done + 60 * 60000), false,
    'auto-off is opt-in');
  assert.equal(SP.autoOffDue(m, cool, null, done), false, 'no print seen ending');
});

test('the shared machine edit keeps a plug token unless it is cleared, and refuses an unknown kind', () => {
  const ME = require('../lib/machine-edit');
  const m = { id: 'M1', name: 'CORE One' };
  ME.applyEdit(m, { smartPlug: { type: 'homeassistant', host: 'ha.local:8123', entity: 'switch.core', token: 'T', autoOff: true, delayMin: 15 } });
  assert.equal(m.smartPlug.token, 'T');
  assert.equal(m.smartPlug.delayMin, 15);
  // A form that never showed the token keeps it.
  ME.applyEdit(m, { smartPlug: { type: 'homeassistant', host: 'ha2.local', entity: 'switch.core' } });
  assert.equal(m.smartPlug.token, 'T');
  assert.equal(m.smartPlug.host, 'ha2.local');
  // An empty string clears it.
  ME.applyEdit(m, { smartPlug: { type: 'homeassistant', host: 'ha2.local', entity: 'switch.core', token: '' } });
  assert.equal(m.smartPlug.token, '');
  ME.applyEdit(m, { smartPlug: { type: 'x10', host: 'a' } });
  assert.equal(m.smartPlug.type, 'none');
});

test('a plug token is a registered secret, and masked on export', () => {
  const paths = require('../lib/store-secret-paths');
  const all = JSON.stringify(paths);
  assert.ok(all.includes('machines[].smartPlug.token'));
  assert.ok(all.includes('machines[].smartPlug.password'));
});
