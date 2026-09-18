/**
 * Capture what the LAN server ACTUALLY sends to the iOS companion.
 *
 * The phone decodes these responses with Swift `Codable`, which throws on a
 * missing required field — so a desktop change that drops or renames a key is
 * not a degraded screen on the phone, it is an empty one. Nothing here reads
 * the server's source: it boots the real `registerLanServer` and records the
 * bytes that go over the wire, which is the only thing the phone sees.
 *
 * The fixture is deliberately hostile. Every collection carries a "sparse"
 * record holding nothing but the fields the desktop truly guarantees, because
 * a fully-populated fixture proves only that the happy path decodes.
 *
 * Pair with `ios-contract-decode.swift`, which feeds the captures to the real
 * structs from `KhaytModels.swift`.
 */
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const OUT = process.argv[2] || path.join(ROOT, '.ios-contract');

/** Today, in the shop's own calendar day — the server stamps completions this way. */
function localDay(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * The desktop's canonical order statuses, read from the source of truth rather
 * than copied here.
 *
 * A hand-copied list is a guard that silently stops guarding: the day someone
 * adds a status to the desktop, a frozen fixture keeps testing the old set and
 * reports green while the phone has no case for the new one. Reading the literal
 * means the fixture widens by itself, and the Swift side fails until OrderStatus
 * catches up.
 */
function desktopStatuses() {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/analytics.js'), 'utf8');
  const m = src.match(/const\s+STATUSES\s*=\s*\[([^\]]+)\]/);
  if (!m) throw new Error('could not find STATUSES in renderer/analytics.js — the fixture would silently narrow');
  const list = m[1].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
  if (list.length < 2) throw new Error(`STATUSES parsed implausibly small: ${JSON.stringify(list)}`);
  return list;
}

// ── The store the server will serve ──────────────────────────────────────────
// Statuses cover the DESKTOP's full vocabulary, not the subset the phone happens
// to know about, so the capture shows the phone everything it can really be sent.
const store = {
  printLog: [
    { id: 'o-full', project: 'Bracket v2', client: 'Acme', status: 'printing',
      material: 'PLA', price: 120, dueDate: '2026-08-01', date: '2026-07-20',
      paymentStatus: 'paid', machine: 'Prusa CORE One', machineId: 'm-1',
      // A BOOLEAN, because that is what the desktop writes: `order-new.js`
      // sets `priority: false` on every order and `order-edit.js` sets
      // `priority: wanted !== 'normal'`, with the word kept in `priorityLevel`.
      // This fixture said `'high'` — a shape nothing in the product produces —
      // so this guard certified a wire contract that held only inside the
      // guard, while the phone's queue screen could not decode a single real
      // shop. A fixture that does not match what the app writes is not a
      // fixture, it is a second opinion.
      priority: true, priorityLevel: 'high', completedAt: null },
    // One order per status the desktop can write, carrying only what the desktop
    // guarantees — an id and a status. A fully-populated record would prove only
    // that the happy path decodes.
    ...desktopStatuses().map((status) => ({ id: `o-${status}`, status })),
    { id: 'o-done', status: 'completed', completedAt: `${localDay()}T09:00:00.000Z` },
  ],
  machines: [
    { id: 'm-1', name: 'Prusa CORE One', type: 'fdm', status: 'idle',
      printerApi: { type: 'prusalink', host: '10.0.0.5' } },
    { id: 'm-sparse' },
  ],
  inventory: [
    { id: 's-full', material: 'PLA', brand: 'Prusament', color: 'Galaxy Black',
      weight: 1000, remaining: 640, cost: 29.9, purchasedAt: '2026-06-01',
      materialType: 'PLA', lot: 'L-99', sku: 'SKU-1', printTemp: 215, bedTemp: 60 },
    { id: 's-sparse' },
  ],
  clients: [
    { id: 'c-full', nameEn: 'Acme Co', nameAr: 'شركة أكمي', phone: '+966500000000', email: 'a@b.com' },
    { id: 'c-sparse' },
  ],
  waitingList: [
    { id: 'w-full', project: 'Vase', clientName: 'Sara', notes: 'rush', email: 'x@y.com',
      phone: '+966511111111', material: 'PETG', priority: 'high', status: 'active',
      estValue: 300, reminderDate: '2026-08-05', source: 'walk-in', submittedAt: '2026-07-25' },
    { id: 'w-sparse' },
    { id: 'w-declined', status: 'declined' }, // must be filtered out by the server
  ],
  settings: {},
};

// ── Minimal Electron-shaped fakes ────────────────────────────────────────────
const handlers = new Map();
const noop = () => {};
let current = store;

const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

registerLanServer({
  fs,
  ipcMain: { handle: (name, fn) => handlers.set(name, fn) },
  BrowserWindow: class { static getAllWindows() { return []; } },
  safeJsonParse: (s, fallback) => { try { return JSON.parse(s); } catch { return fallback; } },
  syncLanServerStoreFromDisk: noop,
  resolveStoreSecret: (v) => v,
  isStoreSecretMasked: () => false,
  migrateLanApiSecrets: noop,
  ensureLanIntakeToken: () => ({ token: 'tok', generated: false }),
  ensureLanIntakePin: () => ({ pin: '1234', generated: false }),
  ensureLanCalendarToken: () => ({ token: 'cal', generated: false }),
  writeStoreToDisk: async () => {},
  persistLanStoreUpdate: async () => {},
  getLanServerStore: () => current,
  setLanServerStore: (s) => { current = s; },
  getMainWindow: () => null,
  statusPagesDir: path.join(ROOT, 'status-pages'),
  appRoot: ROOT,
  getPrinterStatusCache: () => ({
    'm-1': { state: 'printing', progress: 42.7, filename: 'bracket.gcode',
             timeRemaining: 900.4, tempNozzle: 214.6, tempBed: 59.8 },
  }),
});

const start = handlers.get('hub:start-lan-server');
if (!start) throw new Error('hub:start-lan-server was never registered');

const PORT = 3987;
// The owner PIN gates every route carrying shop data — which is all of them bar
// /api/status. The phone sends it as `x-khayt-pin`; so does this capture.
const PIN = '4321';
const res = await start(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
if (!res?.ok) throw new Error(`server did not start: ${JSON.stringify(res)}`);

// The endpoints the iOS app calls, grepped from ios/ and pinned here.
const ENDPOINTS = {
  status: '/api/status?format=json',
  orders: '/api/orders',
  queue: '/api/queue',
  machines: '/api/machines',
  machinesLive: '/api/machines/live',
  inventory: '/api/inventory',
  clients: '/api/clients',
  waitingList: '/api/waiting-list',
};

fs.mkdirSync(OUT, { recursive: true });
const summary = {};

// POST /api/quote is the one read-shaped endpoint that is not a GET, and the
// companion decodes its reply into QuoteResult. Captured here so the same
// decode check covers it: a renamed key in the price block would otherwise
// empty the quote screen with nothing to catch it.
{
  const r = await fetch(`http://127.0.0.1:${PORT}/api/quote`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-khayt-pin': PIN },
    body: JSON.stringify({
      printWeight: 50, printTime: 2, qty: 2, margin: 40,
      spoolCost: 100, spoolWeight: 1000, laborRate: 20,
      prepTime: 0.25, postTime: 0.5, rush: true,
      priceTiers: [{ minQty: 2, pricePerUnit: 55 }],
    }),
  });
  const body = await r.text();
  if (r.status !== 200) throw new Error(`/api/quote → HTTP ${r.status}: ${body.slice(0, 200)}`);
  fs.writeFileSync(path.join(OUT, 'quote.json'), body);
  summary.quote = body.length;
}

for (const [name, ep] of Object.entries(ENDPOINTS)) {
  const r = await fetch(`http://127.0.0.1:${PORT}${ep}`, {
    headers: { Accept: 'application/json', 'x-khayt-pin': PIN },
  });
  const body = await r.text();
  if (r.status !== 200) throw new Error(`${ep} → HTTP ${r.status}: ${body.slice(0, 200)}`);
  fs.writeFileSync(path.join(OUT, `${name}.json`), body);
  summary[name] = body.length;
}

console.log(JSON.stringify(summary, null, 2));
const stop = handlers.get('hub:stop-lan-server');
if (stop) await stop(null, {});
process.exit(0);
