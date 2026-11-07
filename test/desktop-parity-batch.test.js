'use strict';
/**
 * Desktop parity with the Mac: the Bambu fault reason, the automatic portal
 * check, and the Spoolman fetch's address guard.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');

// ── Bambu fault ─────────────────────────────────────────────────────────────

test('a Bambu status carries the decoded fault, in `fault` and never in `error`', () => {
  const { statusWithFault } = require('../lib/bambu.js');
  const paused = statusWithFault(JSON.stringify({ print: { gcode_state: 'PAUSE', print_error: 0x03008004, hms: [] } }));
  assert.equal(paused.state, 'Paused');
  assert.match(paused.fault, /Filament ran out/);
  assert.match(paused.fault, /0300_8004/);
  assert.equal(paused.error, undefined, 'a fault is not a failed poll');
  const fine = statusWithFault(JSON.stringify({ print: { gcode_state: 'RUNNING', mc_percent: 40 } }));
  assert.equal(fine.fault, null);
  assert.equal(statusWithFault('{"info":{}}'), null);
});

test('the printer error alert says the printer\'s own reason when there is one', () => {
  const { computePrinterAlerts } = require('../lib/printer-alerts.js');
  const settings = { telegram: { botToken: '1:a', chatId: '5' } };
  const r = computePrinterAlerts({ M1: { state: 'Printing' } },
    { M1: { state: 'Error', fault: 'Nozzle temperature malfunction. (HMS_0300_0100_0001_0007)' } },
    settings, Date.now(), { machines: [{ id: 'M1', name: 'X1C' }] });
  const err = r.alerts.find((a) => a.type === 'error');
  assert.ok(err);
  assert.match(err.message, /Error — Nozzle temperature malfunction/);
});

test('a paused print\'s notice carries the fault to Telegram and ntfy', () => {
  const sent = { telegram: [], ntfy: [] };
  const ctx = {
    settings: { notifyPrintDone: false,
      telegram: { botToken: '1:a', chatId: '5', notifyPrintPaused: true },
      ntfy: { enabled: true, topic: 'k', events: { paused: true } } },
    machines: [{ id: 'M1', name: 'X1C' }], console,
    KhaytAlertRoutes: require('../lib/alert-routes.js'),
    t: (k, f) => (k.startsWith('alerts.notice_') ? `${f.machine} ${k.slice(14)}` : k),
    window: { hubAPI: {
      sendTelegram: (o) => { sent.telegram.push(o.message); return Promise.resolve({ ok: true }); },
      sendNtfy: (o) => { sent.ntfy.push(o); return Promise.resolve({ ok: true }); },
    } },
  };
  vm.createContext(ctx);
  const src = read('renderer/integrations.js');
  vm.runInContext(src.slice(src.indexOf('let _printPhase = {};'), src.indexOf('function _firePrintNotification('))
    + '; this.notifyPrintTransitions = notifyPrintTransitions;', ctx);
  ctx.notifyPrintTransitions({ M1: { state: 'Printing' } });
  ctx.notifyPrintTransitions({ M1: { state: 'Paused', fault: 'Filament ran out. (0300_8004)' } });
  assert.deepEqual(sent.telegram, ['⏸ X1C paused\nFilament ran out. (0300_8004)']);
  assert.equal(sent.ntfy[0].body, 'Filament ran out. (0300_8004)');
});

test('the machine card draws the fault line', () => {
  const src = read('renderer/machines.js');
  const fn = src.slice(src.indexOf('function machineLiveDetailHtml('), src.indexOf('/* ── JOB CONTROL'));
  const ctx = {
    machineStatusCache: { M1: { state: 'Paused', fault: 'Filament ran out. (0300_8004)', lastUpdated: Date.now() } },
    t: (k) => k, escapeHtml: (s) => String(s).replace(/</g, '&lt;'), MACHINE_LIVE_STALE_MS: 90000,
  };
  vm.createContext(ctx);
  vm.runInContext(fn + '; this.machineLiveDetailHtml = machineLiveDetailHtml;', ctx);
  const html = ctx.machineLiveDetailHtml({ id: 'M1', printerApi: { type: 'bambu' } });
  assert.match(html, /machine-fault/);
  assert.match(html, /Filament ran out/);
});

// ── Portal watch ────────────────────────────────────────────────────────────

test('portalJobsToWatch: quotes and unpaid deposits, published, not void or coming down', () => {
  const { portalJobsToWatch } = require('../renderer/portal-watch.js');
  const jobs = [
    { id: 'q', status: 'quote', cloudPublished: true, trackingToken: 'tq' },
    { id: 'd', status: 'pending', cloudPublished: true, trackingToken: 'td', cloudDeposit: 50 },
    { id: 'paid', status: 'pending', cloudPublished: true, trackingToken: 'tp', cloudDeposit: 50, portalPayments: [{ key: 'x' }] },
    { id: 'unpub', status: 'quote', cloudPublished: false, trackingToken: 'tu' },
    { id: 'void', status: 'quote', cloudPublished: true, trackingToken: 'tv', voidedAt: '2026-01-01' },
    { id: 'down', status: 'quote', cloudPublished: true, trackingToken: 'tx', portalTakedownPending: true },
    { id: 'notoken', status: 'quote', cloudPublished: true },
    { id: 'plain', status: 'printing', cloudPublished: true, trackingToken: 'tz' },
  ];
  assert.deepEqual(portalJobsToWatch(jobs), [{ id: 'q', token: 'tq' }, { id: 'd', token: 'td' }]);
});

function portalHarness({ cloud, items, printLog }) {
  const calls = { list: 0, applied: [], toasts: [] };
  const ctx = {
    console, Date, setTimeout, setInterval,
    settings: { cloud },
    printLog,
    KhaytPortalOwner: {},
    operatorCan: () => true,
    applyPortalResponse: (order, its, token, opts) => { calls.applied.push([order.id, token, opts.quiet]); },
    window: { hubAPI: { cloudPublishedList: async () => { calls.list += 1; return { ok: true, items }; } } },
  };
  vm.createContext(ctx);
  vm.runInContext(read('renderer/portal-watch.js') + '; this.checkPortalNow = checkPortalNow;', ctx);
  return { ctx, calls };
}

test('one look asks the cloud once for every waiting job, and never overlaps', async () => {
  const printLog = [
    { id: 'a', status: 'quote', cloudPublished: true, trackingToken: 'ta' },
    { id: 'b', status: 'quote', cloudPublished: true, trackingToken: 'tb' },
  ];
  const { ctx, calls } = portalHarness({ cloud: { enabled: true, shopId: 's', url: 'u' }, items: [], printLog });
  await Promise.all([ctx.checkPortalNow(), ctx.checkPortalNow()]);
  assert.equal(calls.list, 1);
  assert.deepEqual(calls.applied, [['a', 'ta', true], ['b', 'tb', true]]);
  // Coming to the front again within the minute does not ask again.
  await ctx.checkPortalNow();
  assert.equal(calls.list, 1);
});

test('nothing is asked when the cloud is not connected or nothing is waiting', async () => {
  const off = portalHarness({ cloud: { enabled: false }, items: [],
    printLog: [{ id: 'a', status: 'quote', cloudPublished: true, trackingToken: 'ta' }] });
  await off.ctx.checkPortalNow();
  assert.equal(off.calls.list, 0);
  const idle = portalHarness({ cloud: { enabled: true, shopId: 's' }, items: [], printLog: [] });
  await idle.ctx.checkPortalNow();
  assert.equal(idle.calls.list, 0);
});

test('a deposit seen twice is recorded once (recordPortalPayment is keyed)', () => {
  const PO = require('../lib/portal-owner.js');
  require('../lib/order-payment.js');
  require('../lib/order-money.js');
  const order = { id: 'o1', status: 'pending', price: 100, total: 100, paidAmount: 0, trackingToken: 'tk', cloudDeposit: 30 };
  const items = [{ token: 'tk', payment: { status: 'paid', amount: 30, ref: 'pay_1', at: '2026-11-01T10:00:00Z' } }];
  const first = PO.recordPortalPayment(items, 'tk', order, { today: '2026-11-01', settings: {}, clients: [] });
  assert.notEqual(first.outcome, 'none');
  const again = PO.recordPortalPayment(items, 'tk', order, { today: '2026-11-01', settings: {}, clients: [] });
  assert.equal(again.outcome, 'already');
});

// ── Spoolman fetch ──────────────────────────────────────────────────────────

test('the Spoolman fetch refuses an address off the shop\'s network', async () => {
  const { fetchSpoolman, spoolmanBase } = require('../lib/main/spoolman-fetch.js');
  let fetched = 0;
  const fetchImpl = async () => { fetched += 1; return { ok: true, status: 200, headers: { get: () => null }, json: async () => [] }; };
  const r = await fetchSpoolman('8.8.8.8:7912', { fetchImpl });
  assert.equal(r.ok, false);
  assert.equal(fetched, 0);
  assert.equal((await fetchSpoolman('', { fetchImpl })).ok, false);
  assert.equal((await fetchSpoolman('file:///etc/passwd', { fetchImpl })).ok, false);
  const b = await spoolmanBase('192.168.1.20');
  assert.equal(b.ok, true);
  assert.equal(b.base, 'http://192.168.1.20:7912');
});

test('the Spoolman fetch reads every page, without following redirects', async () => {
  const { fetchSpoolman } = require('../lib/main/spoolman-fetch.js');
  const seen = [];
  const pages = [Array.from({ length: 500 }, (_, i) => ({ id: i })), [{ id: 500 }]];
  const fetchImpl = async (url, init) => {
    seen.push([url, init.redirect]);
    return { ok: true, status: 200, headers: { get: () => null }, json: async () => pages.shift() };
  };
  const r = await fetchSpoolman('http://192.168.1.20:7912/', { fetchImpl });
  assert.equal(r.ok, true);
  assert.equal(r.spools.length, 501);
  assert.equal(seen.length, 2);
  assert.match(seen[1][0], /^http:\/\/192\.168\.1\.20:7912\/api\/v1\/spool\?allow_archived=false&limit=500&offset=500$/);
  assert.equal(seen[0][1], 'manual');
  const notSm = await fetchSpoolman('192.168.1.20', { fetchImpl: async () => ({ ok: true, status: 200, headers: { get: () => null }, json: async () => ({ hello: 1 }) }) });
  assert.equal(notSm.ok, false);
  assert.equal(notSm.code, 'not_spoolman');
});
