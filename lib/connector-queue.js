'use strict';
(function () {

/**
 * The queue a paired slicer plugin (Khayt for OrcaSlicer) may see — pure.
 *
 * ── THE TAB NEVER SHOWS CUSTOMER DATA ────────────────────────────────────
 *
 * Turki's rule for the plugin's "Khayt" tab. A job's TITLE is not safe either:
 * shops name jobs after the person ("Fatima's keychains"), so no title, no
 * project, no notes leave here. Each job carries exactly four things: its
 * number, its stage, the machine's name, and `file` — the name of the file
 * THIS connector itself sent for it (`order.fromSlicer`), which the plugin
 * already knows. Showing titles may come later, only if Turki asks.
 *
 * ── AN ALLOWLIST, NOT A DENYLIST ─────────────────────────────────────────
 *
 * Every value below is copied by name from the record into a fresh object.
 * Nothing is deleted from a copy of the book, so a field the book gains next
 * year cannot ride along. `test/connector-queue.test.js` fails on any key
 * outside `JOB_KEYS` / `MACHINE_KEYS` / `TOP_KEYS`.
 *
 * Open jobs only (`order-status.js isOpen`, and never a split parent). The
 * shop's name is handed in: the caller's own rule (`lan-pages.js shopNameOf`,
 * the Mac's `lanQuoteShopName`), so one shop is one name on every page.
 */

const TOP_KEYS = ['v', 'at', 'shop', 'jobs', 'machines', 'inbox'];
const JOB_KEYS = ['id', 'number', 'stage', 'machine', 'file'];
const MACHINE_KEYS = ['id', 'name', 'state'];
/** The queue shows at most this many jobs; a shop with more is told so by `more`. */
const MAX_JOBS = 200;
const MAX_MACHINES = 64;
/** Every string that leaves is cut to this, with control characters removed. */
const MAX_TEXT = 120;

/** The order the plugin lists stages in: what is running first. */
const STAGE_ORDER = ['printing', 'post', 'qc', 'pending', 'on_hold'];

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const arr = (v) => (Array.isArray(v) ? v : []);

function text(v) {
  if (typeof v !== 'string') return null;
  // eslint-disable-next-line no-control-regex
  const clean = v.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, '').trim();
  if (!clean) return null;
  return clean.length > MAX_TEXT ? clean.slice(0, MAX_TEXT) : clean;
}

function statusApi() {
  if (typeof globalThis !== 'undefined' && globalThis.KhaytOrderStatus) return globalThis.KhaytOrderStatus;
  if (typeof require === 'function') { try { return require('./order-status.js'); } catch (_) { /* bundle */ } }
  return null;
}

function machineStateApi() {
  if (typeof globalThis !== 'undefined' && globalThis.KhaytMachineStatus) return globalThis.KhaytMachineStatus;
  if (typeof require === 'function') { try { return require('./machine-status.js'); } catch (_) { /* bundle */ } }
  return null;
}

/** Open work, as every other screen counts it; a split parent is not work. */
function isQueued(order) {
  if (!isObj(order) || order.deletedAt) return false;
  if (order.status === 'split') return false;
  const S = statusApi();
  if (S && typeof S.isOpen === 'function') return S.isOpen(order);
  const st = order.status;
  return st !== 'completed' && st !== 'delivered' && st !== 'quote' && st !== 'cancelled';
}

/** The reference a person reads (`order-new.js jobRef`): `jobNumber`, else the id. */
function numberOf(order) {
  return text((typeof order.jobNumber === 'string' && order.jobNumber) || (typeof order.id === 'string' ? order.id : ''));
}

/** The file this connector sent for the job; null for any other job or connector. */
function fileOf(order, connectorId) {
  const from = order.fromSlicer;
  if (!isObj(from) || typeof connectorId !== 'string' || !connectorId) return null;
  if (from.connectorId !== connectorId) return null;
  return text(from.name);
}

function rank(stage) {
  const i = STAGE_ORDER.indexOf(stage);
  return i < 0 ? STAGE_ORDER.length : i;
}

/**
 * The snapshot. `opts`: `{ connectorId, now (ms or Date), shopName, inboxWaiting }`.
 * Returns a plain object ready for JSON; the caller seals it.
 */
function snapshot(book, opts) {
  const o = isObj(opts) ? opts : {};
  const b = isObj(book) ? book : {};
  const machines = arr(b.machines).filter(isObj);
  const names = new Map();
  for (const m of machines) {
    if (typeof m.id === 'string' && m.id) names.set(m.id, text(m.name));
  }
  const M = machineStateApi();

  const open = arr(b.orders).filter(isQueued)
    .map((order, index) => ({ order, index }))
    .sort((a, z) => (rank(a.order.status) - rank(z.order.status))
      || ((+a.order.queuePos || 0) - (+z.order.queuePos || 0))
      || (a.index - z.index));

  const jobs = open.slice(0, MAX_JOBS).map(({ order }) => ({
    id: text(order.id),
    number: numberOf(order),
    stage: text(order.status),
    machine: (typeof order.machineId === 'string' && names.get(order.machineId)) || null,
    file: fileOf(order, o.connectorId),
  }));

  const listed = machines
    .filter((m) => !(M && typeof M.stateOf === 'function' && M.stateOf(m) === 'retired') && !m.deletedAt)
    .slice(0, MAX_MACHINES)
    .map((m) => ({
      id: text(m.id),
      name: text(m.name),
      state: M && typeof M.stateOf === 'function' ? M.stateOf(m) : 'active',
    }))
    .filter((m) => m.id);

  const now = o.now instanceof Date ? o.now : new Date(Number.isFinite(+o.now) ? +o.now : Date.now());
  const waiting = Number.isInteger(o.inboxWaiting) && o.inboxWaiting >= 0 ? o.inboxWaiting : 0;
  const out = {
    v: 1,
    at: now.toISOString(),
    shop: { name: text(o.shopName) || 'Khayt' },
    jobs,
    machines: listed,
    inbox: { waiting },
  };
  if (open.length > MAX_JOBS) out.more = open.length - MAX_JOBS;
  return out;
}

const api = { snapshot, isQueued, TOP_KEYS: TOP_KEYS.concat(['more']), JOB_KEYS, MACHINE_KEYS, MAX_JOBS, MAX_TEXT };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytConnectorQueue = api;
})();
