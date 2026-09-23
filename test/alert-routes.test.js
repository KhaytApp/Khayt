/**
 * `lib/alert-routes.js` — which channels a printer alert goes to.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/alert-routes.js');

const tg = (extra) => ({ telegram: { botToken: '__enc__x', chatId: '-100', ...extra } });

test('Telegram follows the switches the settings screens draw', () => {
  assert.deepEqual(R.TYPES.map((t) => R.telegramWants(t, tg())), [true, true, false, true],
    'error/offline/runout default on, stall default off');
  assert.equal(R.telegramWants('error', tg({ notifyPrinterError: false })), false);
  assert.equal(R.telegramWants('stall', tg({ notifyPrinterStall: true })), true);
  assert.equal(R.telegramWants('error', { telegram: { botToken: '', chatId: '-1' } }), false, 'no bot, no send');
  assert.equal(R.telegramWants('error', {}), false);
});

test('ntfy needs switching on and a real topic, and then follows its own events', () => {
  const on = { ntfy: { enabled: true, topic: 'athar-printers' } };
  assert.deepEqual(R.TYPES.map((t) => R.ntfyWants(t, on)), [true, true, false, true]);
  assert.equal(R.ntfyWants('error', { ntfy: { enabled: false, topic: 'x' } }), false);
  assert.equal(R.ntfyWants('error', { ntfy: { enabled: true, topic: 'has space' } }), false, 'not an ntfy topic');
  assert.equal(R.ntfyWants('stall', { ntfy: { enabled: true, topic: 'x', events: { stall: true } } }), true);
  assert.equal(R.ntfyWants('error', { ntfy: { enabled: true, topic: 'x', server: 'ftp://nope' } }), false);
  assert.equal(R.ntfyWants('done', on), false, 'an alert type this does not know is not sent');
});

test('what to compute: the local notification, plus anything a channel asked for', () => {
  assert.deepEqual(R.enable({}), { error: true, offline: true, stall: false, runout: true },
    'runout was missing from the Mac — a spool running out raised nothing');
  assert.equal(R.enable(tg({ notifyPrinterStall: true })).stall, true);
  assert.equal(R.enable({ ntfy: { enabled: true, topic: 'x', events: { stall: true } } }).stall, true);
});

test('the ntfy request: server/topic, one-line headers, priority by kind', () => {
  const req = R.ntfyRequest({ type: 'error', title: 'U1 — printer error', body: 'Dragon.gcode · 47%' },
    { ntfy: { enabled: true, topic: 'athar-printers', server: 'https://ntfy.example.com/' } });
  assert.deepEqual(req, {
    url: 'https://ntfy.example.com/athar-printers',
    headers: { Title: 'U1 — printer error', Priority: 'high', Tags: 'rotating_light' },
    body: 'Dragon.gcode · 47%',
  });
  const blank = R.ntfyRequest({ type: 'stall', title: 'Stalled', body: '' }, { ntfy: { topic: 'x' } });
  assert.equal(blank.url, 'https://ntfy.sh/x', 'ntfy.sh when no server is set');
  assert.equal(blank.headers.Priority, 'low');
  assert.equal(blank.body, 'Stalled', 'an empty body sends the title rather than nothing');
  const sneaky = R.ntfyRequest({ type: 'error', title: 'a\r\nX-Evil: 1', body: 'x' }, { ntfy: { topic: 'x' } });
  assert.equal(sneaky.headers.Title.includes('\n'), false, 'a newline in a title became a second header');
  assert.equal(R.ntfyRequest({ type: 'error', title: 't' }, { ntfy: { topic: '' } }), null);
});

test('it loads without require, as JavaScriptCore loads it', () => {
  const vm = require('node:vm');
  const fs = require('node:fs');
  const path = require('node:path');
  const c = {};
  vm.createContext(c);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', 'alert-routes.js'), 'utf8'), c);
  assert.equal(vm.runInContext("KhaytAlertRoutes.enable({}).runout", c), true);
});
