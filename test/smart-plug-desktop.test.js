'use strict';
/**
 * A printer's smart plug on Windows/Linux (lib/main/smart-plug.js).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { registerSmartPlug } = require('../lib/main/smart-plug.js');

function setup({ cache = {}, machines = [], reply = { ison: true, power: 12.5 } } = {}) {
  const handlers = {}; const seen = []; const told = [];
  globalThis.fetch = async (url, init) => { seen.push({ url, method: init.method, headers: init.headers }); return new Response(JSON.stringify(reply), { status: 200 }); };
  const plug = registerSmartPlug({
    ipcMain: { handle: (n, f) => { handlers[n] = f; } },
    fill: (m) => (m.smartPlug && m.smartPlug.token === 'MASK' ? { ...m, smartPlug: { ...m.smartPlug, token: 'REAL' } } : m),
    resolveTarget: async (host) => (host === 'plug.local' ? { ok: true, urlHost: '192.168.1.40' } : host.startsWith('192.168.') ? { ok: true, urlHost: host } : { ok: false, error: 'Invalid printer host' }),
    statusCache: () => cache, readMachines: () => machines, notify: (m) => told.push(m.id), log: { warn() {} },
  });
  return { handlers, seen, told, plug };
}
const shelly = { id: 'M1', name: 'X1C', smartPlug: { type: 'shelly', host: 'plug.local' } };

test('reads a plug at the LAN address its name resolved to', async () => {
  const { handlers, seen } = setup();
  const r = await handlers['hub:smart-plug'](null, { machine: shelly, action: 'status' });
  assert.deepEqual(r, { ok: true, on: true, watts: 12.5 });
  assert.equal(seen[0].url, 'http://192.168.1.40/relay/0');
});

test('a public address is refused before anything is sent', async () => {
  const { handlers, seen } = setup();
  const r = await handlers['hub:smart-plug'](null, { machine: { id: 'M2', smartPlug: { type: 'shelly', host: '8.8.8.8' } }, action: 'on' });
  assert.equal(r.ok, false);
  assert.equal(seen.length, 0);
});

test('Turn off is refused while printing, not answering, unheard, or hot — checked here, not only in the window', async () => {
  for (const [live, reason] of [
    [{ state: 'printing' }, 'splug.printing'], [{ state: 'paused' }, 'splug.printing'],
    [{ state: 'idle', error: 'ECONNREFUSED' }, 'splug.not_answering'], [undefined, 'splug.no_reading'],
    [{ state: 'idle', tempNozzle: 180 }, 'splug.hot'],
  ]) {
    const { handlers, seen } = setup({ cache: live ? { M1: live } : {} });
    const r = await handlers['hub:smart-plug'](null, { machine: shelly, action: 'off' });
    assert.equal(r.reason, reason, JSON.stringify(live));
    assert.equal(seen.length, 0);
  }
  const { handlers, seen } = setup({ cache: { M1: { state: 'idle', tempNozzle: 30 } } });
  assert.equal((await handlers['hub:smart-plug'](null, { machine: shelly, action: 'off' })).ok, true);
  assert.equal(seen[0].url, 'http://192.168.1.40/relay/0?turn=off');
});

test("the window's masked Home Assistant token is replaced by the real one before sending", async () => {
  const { handlers, seen } = setup({ reply: { state: 'on' } });
  const ha = { id: 'M3', smartPlug: { type: 'homeassistant', host: '192.168.1.9:8123', entity: 'switch.p', token: 'MASK' } };
  await handlers['hub:smart-plug'](null, { machine: ha, action: 'status' });
  assert.equal(seen[0].headers.Authorization, 'Bearer REAL');
  assert.equal(seen[0].url, 'http://192.168.1.9:8123/api/states/switch.p');
});

test('auto-off fires once per finished print, after the delay and once cool', async () => {
  const m = { ...shelly, smartPlug: { ...shelly.smartPlug, autoOff: true, delayMin: 0 } };
  const cache = { M1: { state: 'printing' } };
  const { plug, seen, told } = setup({ cache, machines: [m] });
  await plug.tick();                                  // printing: nothing
  cache.M1 = { state: 'idle', tempNozzle: 120 };
  await plug.tick();                                  // finished but hot
  assert.equal(seen.length, 0);
  cache.M1 = { state: 'idle', tempNozzle: 35 };
  await plug.tick();
  await plug.tick();                                  // and not twice
  assert.deepEqual(seen.map((x) => x.url), ['http://192.168.1.40/relay/0?turn=off']);
  assert.deepEqual(told, ['M1']);
  plug.stop();
});
