'use strict';
/**
 * What happens to a job when its stage changes.
 *
 * These rules were lifted out of `renderer/order-flows.js` so the Mac app can
 * move a job by the same rules the renderer moves it by, instead of inventing
 * a second answer to "is this job finished".
 *
 * The danger in moving code like this is not a crash. It is a job that stops
 * deducting its filament, or a due date that quietly stops being extended, and
 * nobody noticing until a quarter's margins are wrong. So the first test runs
 * the ORIGINAL `updateStatus` — copied out of order-flows.js before the move —
 * and the extracted module over a few thousand generated transitions, and
 * compares the resulting order field by field AND the exact sequence of side
 * effects each one asked for.
 *
 * The original is verbatim except for the clock: `Date.now()` and
 * `new Date().toISOString()` are frozen, because two implementations cannot be
 * compared while time passes between them.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/assembly.js');
// Loaded BEFORE order-status, the way a host loads it: `outboundFor` asks this
// module whether a move emails the customer, and throws rather than guessing
// when it is absent. A test that did not load it would be testing a host that
// cannot move a job at all.
require('../lib/order-email.js');
// The portal half needs the same treatment, plus the two modules it reads to
// judge a trial — `outboundFor` throws rather than guessing when any is absent.
require('../lib/currencies.js');
require('../lib/order-payment.js');
require('../lib/portal-trial.js');
require('../lib/cloud-plans.js');
require('../lib/portal-refresh.js');
const S = require('../lib/order-status.js');

const NOW_MS = Date.parse('2026-09-04T09:15:00.000Z');
const NOW_ISO = new Date(NOW_MS).toISOString();

/* ── The original, copied from renderer/order-flows.js before the move ────────
   Globals become `g`; every UI and side-effect call records itself instead of
   happening. `promptActuals` takes the confirm path — whether to ask is the
   caller's decision, not one of the rules being compared. */
function originalUpdateStatus(g, id, newStatus) {
  const { printLog, settings, inventory, calls, notices } = g;
  const toast = (msg) => calls.push(`toast:${msg}`);
  const t = (k) => k;
  const saveAll = () => calls.push('saveAll');
  const renderKanban = () => calls.push('render:kanban');
  const renderLogs = () => calls.push('render:logs');
  const renderAnalytics = () => calls.push('render:analytics');
  const renderDashboard = () => calls.push('render:dashboard');
  const logActivity = (kind, text) => calls.push(`logActivity:${text}`);
  const deductFilamentForOrder = () => calls.push('deductFilamentForOrder');
  const deductPackagingConsumables = () => calls.push('deductPackagingConsumables');
  const autoExportStatusPage = () => calls.push('autoExportStatusPage');
  const autoSendEmailNotification = (o, s) => calls.push(`email:${s}`);
  const sendTelegramForOrder = (o, s) => calls.push(`telegram:${s}`);
  const fireWebhook = (ev, p) => calls.push(`webhook:${ev}${p.newStatus ? ':' + p.newStatus : ''}`);
  const fireOrderWebhook = (ev) => calls.push(`orderWebhook:${ev}`);
  const republishPortalIfPublished = () => calls.push('republishPortal');
  // The tier is READ twice by the original (once before the mutation, once
  // after the save) and reported once by the lifted version. Comparing two
  // reads against one report says nothing, so the tier is left out of the
  // sequence and covered by its own test below.
  const getClientTier = () => null;
  const localName = () => '';
  const clients = [];
  const wouldExceedWipLimit = S.wouldExceedWipLimit;
  const localDateStr = (d) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const promptActuals = (order, onConfirm) => { onConfirm(); };
  const KhaytAssembly = globalThis.KhaytAssembly;

  function fireOrderCompletionEvents(order) {
    fireWebhook('status_changed', { orderId: order.id, project: order.project, newStatus: 'completed', client: order.client });
    fireOrderWebhook('status', order);
    fireWebhook('order_delivered', { orderId: order.id, project: order.project, client: order.client });
    if (!order.surveyToken) {
      order.surveyToken = 'srv-TOKEN';
      calls.push('surveyToken');
      saveAll();
    }
  }

  function resumeFromHold(order, prevStatus, newStatus) {
    if (prevStatus === 'on_hold' && newStatus !== 'on_hold') {
      if (newStatus !== 'completed' && newStatus !== 'delivered' && order.dueDate && order.heldAt) {
        const holdDays = Math.ceil((NOW_MS - new Date(order.heldAt).getTime()) / 86400000);
        if (holdDays > 0) {
          const d = new Date(order.dueDate + 'T00:00:00');
          d.setDate(d.getDate() + holdDays);
          order.dueDate = localDateStr(d);
          notices.push({ code: 'due_extended', params: { days: holdDays, date: order.dueDate } });
        }
      }
      delete order.holdReason;
      delete order.heldAt;
    } else if (newStatus === 'pending' && order.holdReason !== undefined) {
      delete order.holdReason;
      delete order.heldAt;
    }
  }

  const order = printLog.find(o => o.id === id);
  if (!order) return;
  const prevStatus = order.status;
  if (settings.productionPaused && newStatus === 'printing') {
    calls.push('BLOCKED:prod.paused_block');
    return;
  }
  if (newStatus !== 'completed' && wouldExceedWipLimit(printLog, id, newStatus, settings.wipLimits)) {
    if (settings.wipEnforceHardLimit) {
      calls.push('BLOCKED:wip.limit_blocked');
      return;
    }
    calls.push('WARN:wip.limit_reached');
  }
  if (newStatus === 'completed' && typeof KhaytAssembly !== 'undefined' && KhaytAssembly.isAssembly(order)) {
    const gate = KhaytAssembly.canCompleteAssembly(order);
    if (!gate.ok) {
      calls.push(gate.reason === 'not_assembled' ? 'BLOCKED:asm.gate_not_assembled' : 'BLOCKED:asm.gate_parts');
      return;
    }
  }
  // NOT IN THE ORIGINAL, and the THIRD of three deliberate divergences (see
  // the on_hold stamp and the completion timer below). `quoteAcceptedAt` was
  // written by exactly one path — the Approve button in the invoicing screen —
  // so a quote won by dragging its card counted as a quote never accepted, and
  // the conversion rate a shop reads only ever fell. Added to BOTH sides so
  // the comparison still proves the rest; tested on its own in
  // test/quote-accepted.test.js.
  if (prevStatus === 'quote' && newStatus !== 'quote' && newStatus !== 'cancelled'
      && !order.quoteAcceptedAt) {
    order.quoteAcceptedAt = NOW_ISO.split('T')[0];
  }
  if (newStatus === 'completed') {
    promptActuals(order, () => {
      const prevTier = order.clientId ? getClientTier(order.clientId) : null;
      resumeFromHold(order, prevStatus, 'completed');
      if (!order.statusHistory) order.statusHistory = [];
      order.statusHistory.push({ status: 'completed', at: NOW_ISO });
      if (order.statusHistory.length > 200) order.statusHistory = order.statusHistory.slice(-200);
      order.status = 'completed';
      if (!order.completedAt) order.completedAt = NOW_ISO;
      // NOT IN THE ORIGINAL, and the second of two deliberate divergences (see
      // the on_hold stamp above). A completed job used to keep a running
      // timerStart until some later move cleared it. Nothing displayed it, but
      // "is this job's timer running" could not be answered by looking at the
      // job. Added to BOTH sides so the comparison still proves the rest.
      if (order.timerStart) {
        delete order.timerStart;
        delete order.timerPausedAt;
        delete order.timerPausedMs;
      }
      deductFilamentForOrder(order);
      if (!order.costBasis) {
        order.costBasis = (order.parts || []).reduce((s, p) => s + (+p.baseCost || 0), 0);
      }
      deductPackagingConsumables(order);
      saveAll();
      const newTier = order.clientId ? getClientTier(order.clientId) : null;
      if (newTier && (!prevTier || prevTier.name !== newTier.name)) {
        toast('cl.new_tier');
      }
      renderKanban(); renderLogs(); renderAnalytics(); renderDashboard();
      toast('toast.status_updated');
      if (order.clientId) autoExportStatusPage(order);
      sendTelegramForOrder(order, 'completed');
      fireOrderCompletionEvents(order);
      republishPortalIfPublished(order.id);
    });
    return;
  }
  order.status = newStatus;
  if (!order.statusHistory) order.statusHistory = [];
  order.statusHistory.push({ status: newStatus, at: NOW_ISO });
  if (order.statusHistory.length > 200) order.statusHistory = order.statusHistory.slice(-200);
  logActivity('status', `${order.id} → ${newStatus}`, order.id);
  if ((prevStatus === 'completed' || prevStatus === 'delivered') &&
      newStatus !== 'completed' && newStatus !== 'delivered') {
    delete order.completedAt;
    delete order.materialDeducted;
    delete order.printingStartedAt;
  }
  if (newStatus === 'post') {
    const invItem = inventory.find(i => i.id === order.filamentId || (order.parts || []).some(p => p.filamentId === i.id));
    if (invItem && invItem.materialType === 'resin') {
      order.isResin = true;
      if (!order.resinPost) {
        order.resinPost = { washDurationMins: null, washIpaVolumeMl: null, cureDurationMins: null, curePowerW: null, inspectionNotes: '', completedAt: null };
      }
    }
  }
  // NOT IN THE ORIGINAL. Entering on_hold now records WHEN, because the due
  // date a job gets back is computed from it and there was no path that set it
  // except Khayt's own hold dialog — so a job put on hold any other way came
  // back late with nothing to explain why. Added to BOTH sides so the
  // comparison below still proves everything else is unchanged; the change
  // itself is asserted by its own tests further down.
  if (newStatus === 'on_hold') {
    if (!order.heldAt) order.heldAt = NOW_ISO;
    if (Object.prototype.hasOwnProperty.call(g, 'holdReason')) {
      order.holdReason = g.holdReason || null;
    }
  }
  if (newStatus === 'printing') {
    order.timerStart = NOW_ISO;
    if (!order.printingStartedAt) order.printingStartedAt = NOW_ISO;
  } else if (order.timerStart) {
    delete order.timerStart;
    delete order.timerPausedAt;
    delete order.timerPausedMs;
  }
  resumeFromHold(order, prevStatus, newStatus);
  saveAll();
  renderKanban(); renderLogs(); renderAnalytics();
  toast('toast.status_updated:undo');
  if (order.clientId) autoExportStatusPage(order);
  autoSendEmailNotification(order, newStatus);
  sendTelegramForOrder(order, newStatus);
  fireWebhook('status_changed', { orderId: order.id, project: order.project, newStatus, client: order.client });
  fireOrderWebhook('status', order);
  republishPortalIfPublished(order.id);
}

/* ── The extracted module, driven the way a host drives it ─────────────────── */
function liftedUpdateStatus(g, id, newStatus) {
  const { printLog, settings, inventory, calls, notices } = g;
  const order = printLog.find(o => o.id === id);
  if (!order) return;

  const decision = S.gate(order, newStatus, { orders: printLog, settings });
  if (decision.warn) calls.push(`WARN:wip.limit_${decision.warn.code === 'wip_reached' ? 'reached' : '?'}`);
  if (!decision.ok) {
    const map = {
      production_paused: 'BLOCKED:prod.paused_block',
      wip_blocked: 'BLOCKED:wip.limit_blocked',
      assembly_not_assembled: 'BLOCKED:asm.gate_not_assembled',
      assembly_parts: 'BLOCKED:asm.gate_parts',
    };
    calls.push(map[decision.block.code]);
    return;
  }

  const ctx = { now: NOW_MS, inventory };
  if (Object.prototype.hasOwnProperty.call(g, 'holdReason')) ctx.holdReason = g.holdReason;
  const out = S.apply(order, newStatus, ctx);
  for (const n of out.notices) notices.push(n);
  for (const e of out.effects) {
    switch (e.type) {
      case 'activity_log': calls.push(`logActivity:${e.text}`); break;
      case 'tier_check': break; // left out of the sequence on purpose — see above
      case 'deduct_filament': calls.push('deductFilamentForOrder'); break;
      case 'deduct_packaging': calls.push('deductPackagingConsumables'); break;
      case 'save': calls.push('saveAll'); break;
      case 'render':
        calls.push('render:kanban'); calls.push('render:logs'); calls.push('render:analytics');
        if (e.dashboard) calls.push('render:dashboard');
        break;
      case 'toast_updated': calls.push('toast:toast.status_updated'); break;
      case 'toast_updated_undoable': calls.push('toast:toast.status_updated:undo'); break;
      case 'export_status_page': calls.push('autoExportStatusPage'); break;
      case 'email': calls.push(`email:${e.status}`); break;
      case 'telegram': calls.push(`telegram:${e.status}`); break;
      case 'webhook': calls.push(`webhook:${e.event}${e.newStatus ? ':' + e.newStatus : ''}`); break;
      case 'order_webhook': calls.push(`orderWebhook:${e.event}`); break;
      case 'ensure_survey_token':
        order.surveyToken = 'srv-TOKEN'; calls.push('surveyToken'); calls.push('saveAll'); break;
      case 'republish_portal': calls.push('republishPortal'); break;
      default: throw new Error(`unknown effect ${e.type}`);
    }
  }
}

/* ── Generated orders ──────────────────────────────────────────────────────── */
const STATUSES = ['quote', 'pending', 'printing', 'post', 'qc', 'on_hold', 'completed', 'delivered', 'cancelled'];

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeOrder(rnd, i) {
  const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
  const maybe = (p) => rnd() < p;
  const o = {
    id: `o${i}`,
    project: `Job ${i}`,
    client: 'Acme',
    status: pick(STATUSES),
    parts: Array.from({ length: 1 + Math.floor(rnd() * 3) }, (_, k) => ({
      id: `p${k}`, name: `part ${k}`, qty: 1 + Math.floor(rnd() * 3),
      baseCost: Math.round(rnd() * 5000) / 100,
      filamentId: maybe(0.6) ? pick(['f1', 'f2', 'f3']) : null,
    })),
  };
  if (maybe(0.7)) o.clientId = `c${Math.floor(rnd() * 5)}`;
  if (maybe(0.7)) o.dueDate = `2026-0${1 + Math.floor(rnd() * 9)}-1${Math.floor(rnd() * 9)}`;
  if (maybe(0.5)) o.filamentId = pick(['f1', 'f2', 'f3']);
  if (o.status === 'on_hold' || maybe(0.2)) {
    o.holdReason = maybe(0.5) ? 'waiting on filament' : null;
    o.heldAt = new Date(NOW_MS - Math.floor(rnd() * 20) * 86400000).toISOString();
  }
  if (o.status === 'completed' || o.status === 'delivered') {
    o.completedAt = new Date(NOW_MS - 86400000).toISOString();
    if (maybe(0.8)) o.materialDeducted = true;
    if (maybe(0.8)) o.printingStartedAt = new Date(NOW_MS - 3 * 86400000).toISOString();
    if (maybe(0.5)) o.costBasis = Math.round(rnd() * 20000) / 100;
  }
  if (o.status === 'printing') {
    o.timerStart = new Date(NOW_MS - 3600000).toISOString();
    if (maybe(0.4)) o.timerPausedAt = new Date(NOW_MS - 1800000).toISOString();
    if (maybe(0.4)) o.timerPausedMs = Math.floor(rnd() * 100000);
  }
  if (maybe(0.15)) o.surveyToken = 'srv-existing';
  if (maybe(0.2)) {
    o.statusHistory = Array.from({ length: 195 + Math.floor(rnd() * 10) }, (_, k) => ({
      status: 'pending', at: new Date(NOW_MS - k * 60000).toISOString(),
    }));
  }
  if (maybe(0.25)) {
    // A true BOM assembly: bought-in components alongside the printed parts.
    // The completion gate reads `parts[].partStatus` and `assembledAt`, so vary
    // both — an assembly that passes the gate is as important to compare as one
    // that does not.
    o.components = [{ id: 'k1', name: 'body', qty: 1 }, { id: 'k2', name: 'lid', qty: 1 }];
    const roll = rnd();
    for (const p of o.parts) p.partStatus = roll < 0.6 ? 'qc_pass' : pick(['pending', 'printed', 'qc_fail']);
    if (roll < 0.35) o.assembledAt = new Date(NOW_MS - 3600000).toISOString();
  }
  return o;
}

const INVENTORY = [
  { id: 'f1', material: 'PLA', materialType: 'filament', weight: 900 },
  { id: 'f2', material: 'Resin', materialType: 'resin', weight: 500 },
  { id: 'f3', material: 'PETG', materialType: 'filament', weight: 300 },
];

const SETTINGS_VARIANTS = [
  {},
  { productionPaused: true },
  { wipLimits: { printing: 2, post: 1 }, wipEnforceHardLimit: false },
  { wipLimits: { printing: 2, post: 1 }, wipEnforceHardLimit: true },
  { productionPaused: true, wipLimits: { post: 1 }, wipEnforceHardLimit: true },
];

test('the lifted rules and the originals agree on every transition', () => {
  const rnd = mulberry32(20260904);
  let compared = 0;
  for (let seed = 0; seed < 60; seed++) {
    const base = Array.from({ length: 8 }, (_, i) => makeOrder(rnd, i));
    for (const settings of SETTINGS_VARIANTS) {
      for (const o of base) {
        for (const target of STATUSES) {
          const a = {
            printLog: JSON.parse(JSON.stringify(base)), settings, inventory: INVENTORY,
            calls: [], notices: [],
          };
          const b = {
            printLog: JSON.parse(JSON.stringify(base)), settings, inventory: INVENTORY,
            calls: [], notices: [],
          };
          originalUpdateStatus(a, o.id, target);
          liftedUpdateStatus(b, o.id, target);
          const label = `${o.id} ${o.status} → ${target} / ${JSON.stringify(settings)}`;
          assert.deepEqual(b.printLog, a.printLog, `order state diverged: ${label}`);
          assert.deepEqual(b.calls, a.calls, `effects diverged: ${label}`);
          assert.deepEqual(b.notices, a.notices, `notices diverged: ${label}`);
          compared++;
        }
      }
    }
  }
  assert.ok(compared > 15000, `expected thousands of transitions, compared ${compared}`);
});

/* ── The rules that are easy to break and hard to notice ───────────────────── */

test('a job held for nine days has its due date pushed out by nine', () => {
  const order = {
    id: 'o1', status: 'on_hold', dueDate: '2026-09-20',
    heldAt: new Date(NOW_MS - 9 * 86400000).toISOString(), holdReason: 'no filament',
  };
  const out = S.apply(order, 'printing', { now: NOW_MS });
  assert.equal(order.dueDate, '2026-09-29');
  assert.equal(order.holdReason, undefined);
  assert.equal(order.heldAt, undefined);
  assert.deepEqual(out.notices, [{ code: 'due_extended', params: { days: 9, date: '2026-09-29' } }]);
});

test('a job completed straight out of hold keeps its due date but loses the hold', () => {
  const order = {
    id: 'o1', status: 'on_hold', dueDate: '2026-09-20',
    heldAt: new Date(NOW_MS - 9 * 86400000).toISOString(), holdReason: 'no filament',
  };
  const out = S.apply(order, 'completed', { now: NOW_MS });
  assert.equal(order.dueDate, '2026-09-20', 'a finished job needs no new due date');
  assert.equal(order.holdReason, undefined, 'the hold must not outlive the job');
  assert.equal(order.heldAt, undefined);
  assert.deepEqual(out.notices, []);
});

test('re-opening a finished job clears what would make the reprint free', () => {
  const order = {
    id: 'o1', status: 'completed', completedAt: NOW_ISO,
    materialDeducted: true, printingStartedAt: '2026-09-01T00:00:00.000Z',
  };
  S.apply(order, 'printing', { now: NOW_MS });
  assert.equal(order.completedAt, undefined);
  assert.equal(order.materialDeducted, undefined, 'else the reprint consumes no filament');
  assert.equal(order.printingStartedAt, NOW_ISO, 'the new run starts now');
});

test('the cost basis is fixed once and never rewritten', () => {
  const order = { id: 'o1', status: 'qc', parts: [{ baseCost: 10 }, { baseCost: 5.5 }] };
  S.apply(order, 'completed', { now: NOW_MS });
  assert.equal(order.costBasis, 15.5);
  order.status = 'qc';
  order.parts = [{ baseCost: 999 }];
  S.apply(order, 'completed', { now: NOW_MS });
  assert.equal(order.costBasis, 15.5, "last year's margins are not recomputed at today's prices");
});

test('history is capped at two hundred moves', () => {
  const order = {
    id: 'o1', status: 'pending',
    statusHistory: Array.from({ length: 200 }, (_, k) => ({ status: 'pending', at: `t${k}` })),
  };
  S.apply(order, 'printing', { now: NOW_MS });
  assert.equal(order.statusHistory.length, S.HISTORY_CAP);
  assert.equal(order.statusHistory[0].at, 't1', 'the oldest move is the one that falls off');
  assert.equal(order.statusHistory[199].status, 'printing');
});

test('a paused shop refuses to start a print and nothing else', () => {
  const settings = { productionPaused: true };
  const order = { id: 'o1', status: 'pending' };
  assert.equal(S.gate(order, 'printing', { settings, orders: [order] }).ok, false);
  assert.equal(S.gate(order, 'completed', { settings, orders: [order] }).ok, true);
  assert.equal(S.gate(order, 'delivered', { settings, orders: [order] }).ok, true);
});

test('a full column warns when soft and refuses when hard', () => {
  const orders = [
    { id: 'a', status: 'printing' }, { id: 'b', status: 'printing' }, { id: 'c', status: 'pending' },
  ];
  const soft = S.gate(orders[2], 'printing', { orders, settings: { wipLimits: { printing: 2 } } });
  assert.equal(soft.ok, true);
  assert.deepEqual(soft.warn, { code: 'wip_reached', params: { col: 'printing', n: 2 } });

  const hard = S.gate(orders[2], 'printing', {
    orders, settings: { wipLimits: { printing: 2 }, wipEnforceHardLimit: true },
  });
  assert.equal(hard.ok, false);
  assert.equal(hard.block.code, 'wip_blocked');
});

test('a finished column is never full — a limit stops work starting, not finishing', () => {
  const orders = [
    { id: 'a', status: 'completed' }, { id: 'b', status: 'completed' }, { id: 'c', status: 'qc' },
  ];
  const settings = { wipLimits: { completed: 1, delivered: 1 }, wipEnforceHardLimit: true };
  assert.equal(S.gate(orders[2], 'completed', { orders, settings }).ok, true);
  assert.equal(S.gate(orders[2], 'delivered', { orders, settings }).ok, true);
});

test('an unfinished assembly cannot be completed', () => {
  const order = {
    id: 'o1', status: 'qc',
    components: [{ id: 'k1', name: 'bracket' }],
    parts: [{ name: 'body', partStatus: 'qc_pass' }, { name: 'lid', partStatus: 'printed' }],
  };
  const waiting = S.gate(order, 'completed', { orders: [order], settings: {} });
  assert.equal(waiting.ok, false);
  assert.equal(waiting.block.code, 'assembly_parts');
  assert.ok(waiting.block.params.parts.includes('lid'), 'say which part is holding it up');

  order.parts[1].partStatus = 'qc_pass';
  const unassembled = S.gate(order, 'completed', { orders: [order], settings: {} });
  assert.equal(unassembled.block.code, 'assembly_not_assembled', 'passing QC is not being assembled');

  order.assembledAt = NOW_ISO;
  assert.equal(S.gate(order, 'completed', { orders: [order], settings: {} }).ok, true);

  const plain = { id: 'o2', status: 'qc', parts: [{ name: 'body', partStatus: 'pending' }] };
  assert.equal(S.gate(plain, 'completed', { orders: [plain], settings: {} }).ok, true,
    'an order with no components[] is not an assembly and is not gated');
});

test('the completion webhooks are asked for once, and only when there is no token yet', () => {
  const fresh = { id: 'o1', status: 'qc', clientId: 'c1' };
  const effects = S.apply(fresh, 'completed', { now: NOW_MS }).effects;
  const wired = effects.map(e => `${e.type}${e.event ? ':' + e.event : ''}`);
  assert.equal(wired.filter(x => x === 'webhook:order_delivered').length, 1);
  assert.ok(wired.includes('ensure_survey_token'));

  const known = { id: 'o2', status: 'qc', surveyToken: 'srv-already' };
  const t2 = S.apply(known, 'completed', { now: NOW_MS }).effects.map(e => e.type);
  assert.ok(!t2.includes('ensure_survey_token'), 'a token is minted once per job');
});

test('a completion asks for no email and a plain move does', () => {
  const done = S.apply({ id: 'o1', status: 'qc' }, 'completed', { now: NOW_MS });
  assert.ok(!done.effects.some(e => e.type === 'email'));
  const moved = S.apply({ id: 'o2', status: 'pending' }, 'printing', { now: NOW_MS });
  assert.deepEqual(moved.effects.filter(e => e.type === 'email'), [{ type: 'email', status: 'printing' }]);
});

test('a resin job entering post gets somewhere to record the wash and cure', () => {
  const order = { id: 'o1', status: 'printing', filamentId: 'f2' };
  S.apply(order, 'post', { now: NOW_MS, inventory: INVENTORY });
  assert.equal(order.isResin, true);
  assert.equal(order.resinPost.washDurationMins, null);

  const pla = { id: 'o2', status: 'printing', filamentId: 'f1' };
  S.apply(pla, 'post', { now: NOW_MS, inventory: INVENTORY });
  assert.equal(pla.isResin, undefined);
  assert.equal(pla.resinPost, undefined);
});

test('the timer stops the moment the job stops printing', () => {
  const order = {
    id: 'o1', status: 'printing',
    timerStart: '2026-09-04T08:00:00.000Z', timerPausedAt: '2026-09-04T08:30:00.000Z', timerPausedMs: 900000,
    printingStartedAt: '2026-09-03T00:00:00.000Z',
  };
  S.apply(order, 'qc', { now: NOW_MS });
  assert.equal(order.timerStart, undefined);
  assert.equal(order.timerPausedAt, undefined);
  assert.equal(order.timerPausedMs, undefined);
  assert.equal(order.printingStartedAt, '2026-09-03T00:00:00.000Z', 'the first start survives');
});

test('a survey token is minted in the format both apps read', () => {
  const token = S.makeSurveyToken(new Uint8Array([0, 15, 255, 1]));
  assert.equal(token, 'srv-000fff01');
});

test('a customer is checked for a new tier, and a walk-in is not', () => {
  const known = S.apply({ id: 'o1', status: 'qc', clientId: 'c1' }, 'completed', { now: NOW_MS });
  assert.ok(known.effects.some(e => e.type === 'tier_check'));

  const walkIn = S.apply({ id: 'o2', status: 'qc' }, 'completed', { now: NOW_MS });
  assert.ok(!walkIn.effects.some(e => e.type === 'tier_check'), 'no customer, no tier');
  assert.ok(!walkIn.effects.some(e => e.type === 'export_status_page'),
    'and nobody to publish a status page for');
});

/* ── What a move reaches outside the shop's own book ───────────────────────── */

const CONFIGURED = {
  webhooks: { enabled: true },
  eventWebhooks: { enabled: true, url: 'https://erp.example.com/hook' },
  telegram: { botToken: 'b', chatId: 'c', notifyOnComplete: true, notifyOnHold: true },
  emailConfig: { provider: 'smtp', triggers: ['completed', 'printing'] },
  cloud: { enabled: true, shopId: 'shop1' },
};
const CLIENTS = [{ id: 'c1', email: 'someone@example.com' }, { id: 'c2' }];

const channels = (order, status, settings = CONFIGURED, clients = CLIENTS) =>
  S.outboundFor(order, status, { settings, clients }).map(x => x.channel);

test('a shop with nothing configured reaches nobody', () => {
  const order = { id: 'o1', clientId: 'c1', cloudPublished: true, trackingToken: 't' };
  assert.deepEqual(S.outboundFor(order, 'completed', { settings: {}, clients: CLIENTS }), []);
  assert.deepEqual(S.outboundFor(order, 'completed', {}), []);
});

test('a fully wired shop reaches everything a completion touches', () => {
  const order = { id: 'o1', clientId: 'c1', cloudPublished: true, trackingToken: 't' };
  assert.deepEqual(channels(order, 'completed'),
    ['webhooks', 'event_webhook', 'telegram', 'email', 'portal']);
});

test('Telegram announces a completion and a hold, and stays quiet otherwise', () => {
  const order = { id: 'o1' };
  const only = { telegram: CONFIGURED.telegram };
  assert.deepEqual(channels(order, 'completed', only), ['telegram']);
  assert.deepEqual(channels(order, 'on_hold', only), ['telegram']);
  assert.deepEqual(channels(order, 'printing', only), [], 'moving a job to printing reaches nobody');

  const quiet = { telegram: { botToken: 'b', chatId: 'c' } };
  assert.deepEqual(channels(order, 'completed', quiet), [],
    'a bot that was told not to announce completions does not');
});

test('email needs a trigger for THIS status and an address on file', () => {
  const only = { emailConfig: CONFIGURED.emailConfig };
  assert.deepEqual(channels({ id: 'o', clientId: 'c1' }, 'completed', only), ['email']);
  assert.deepEqual(channels({ id: 'o', clientId: 'c1' }, 'qc', only), [], 'not a triggered status');
  assert.deepEqual(channels({ id: 'o', clientId: 'c2' }, 'completed', only), [],
    'a customer with no email is nobody to reach');
  assert.deepEqual(channels({ id: 'o' }, 'completed', only), [], 'and a walk-in is nobody at all');
  assert.deepEqual(channels({ id: 'o', clientId: 'c1' }, 'completed',
    { emailConfig: { provider: 'none', triggers: ['completed'] } }), []);
});

test('the portal only refreshes for a job that was actually published', () => {
  const only = { cloud: CONFIGURED.cloud };
  assert.deepEqual(channels({ id: 'o', cloudPublished: true, trackingToken: 't' }, 'printing', only), ['portal']);
  assert.deepEqual(channels({ id: 'o', cloudPublished: true }, 'printing', only), [], 'no token, no link');
  assert.deepEqual(channels({ id: 'o', trackingToken: 't' }, 'printing', only), [], 'never published');
  assert.deepEqual(channels({ id: 'o', cloudPublished: true, trackingToken: 't' }, 'printing',
    { cloud: { enabled: false, shopId: 'shop1' } }), []);
});

test('an event webhook must be enabled, https, and not switched off for status', () => {
  const on = { eventWebhooks: { enabled: true, url: 'https://erp.example.com/hook' } };
  assert.deepEqual(channels({ id: 'o' }, 'printing', on), ['event_webhook']);
  assert.deepEqual(channels({ id: 'o' }, 'printing',
    { eventWebhooks: { enabled: true, url: 'http://erp.example.com/hook' } }), [],
    'plain http is refused there, so it is refused here');
  assert.deepEqual(channels({ id: 'o' }, 'printing',
    { eventWebhooks: { enabled: true, url: 'https://x/h', events: { status: false } } }), [],
    'a shop that switched status events off is not reached by one');
});

/**
 * outboundFor() promises that its conditions ARE the renderer's. A guard that
 * changes in integrations.js and not here turns the promise into a guess, and
 * the failure is silent: an app decides a move reaches nobody, performs it, and
 * a customer's ERP never hears.
 *
 * This pins each guard to the source it was copied from. It fails loudly on a
 * refactor, which is the point — the fix is to read the new guard and update
 * outboundFor, not to loosen the pattern.
 */
test('the outbound conditions still match the renderer they were copied from', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const root = path.join(__dirname, '..');
  const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');

  const integrations = read('renderer/integrations.js');
  const extras = read('renderer/operations-extras.js');
  const telegram = read('lib/telegram-message.js');
  const email = read('lib/order-email.js');
  const portal = read('lib/portal-refresh.js');

  const pinned = [
    ['fireWebhook', integrations, "const wh = settings.webhooks;\n  if (!wh?.enabled) return;"],
    // The Telegram guards moved into lib/telegram-message.js when the Mac app
    // learned to send one, so they are pinned THERE — and pinned by running
    // the rule rather than by reading its text, below.
    ['telegram bot configured', telegram,
      "if (!tg || !tg.botToken || !tg.chatId) return null;"],
    ['telegram completion', telegram,
      "if (newStatus === 'completed' && tg.notifyOnComplete) {"],
    ['telegram hold', telegram,
      "} else if (newStatus === 'on_hold' && tg.notifyOnHold) {"],
    // The email guards moved into lib/order-email.js when the Mac app learned
    // to send one — the same move the Telegram guards made above — so they are
    // pinned THERE, and pinned by RUNNING the rule beside outboundFor in
    // test/order-email.test.js rather than by reading its text. What is pinned
    // here is that the renderer still asks the module instead of opening with
    // its own copy of the conditions again.
    ['autoSendEmailNotification asks the module', integrations,
      "const mail = KhaytOrderEmail.messageFor(order, newStatus, {"],
    ['order-email owns the guard', email,
      "if (!provider || provider === 'none') return none;"],
    // The portal guards moved into lib/portal-refresh.js when the Mac app
    // learned to refresh the link — the third lift of this shape — so they are
    // pinned THERE, and pinned by RUNNING them beside outboundFor in
    // test/portal-refresh.test.js. What is pinned here is that the renderer
    // still asks the module rather than opening with its own copy again.
    ['republishPortalIfPublished asks the module', integrations,
      "const req = KhaytPortalRefresh.requestFor(order, {"],
    ['portal-refresh owns the guards', portal,
      "if (!o.cloudPublished || !o.trackingToken) return false;"],
    ['portal-refresh owns the cloud guard', portal,
      "if (!cloud.enabled || !cloud.shopId) return false;"],
    ['fireOrderWebhook', extras,
      "if (!w || !w.enabled || !/^https:\\/\\//i.test(w.url || '')) return;"],
    ['fireOrderWebhook per-event', extras, "if (w.events && w.events[type] === false) return;"],
  ];

  for (const [name, source, guard] of pinned) {
    assert.ok(source.includes(guard),
      `${name}'s guard has changed. lib/order-status.js outboundFor() copied it, and an app `
      + `uses that copy to decide whether a move it performs would reach anybody. Read the new `
      + `guard, update outboundFor to match, then update this pin.\n\nexpected to find:\n${guard}`);
  }

  // And the Telegram half is checked by RUNNING it: `outboundFor` says a move
  // would reach Telegram exactly when the message rule would write one, and
  // the Mac app now sends on the strength of that agreement.
  const TG = require('../lib/telegram-message.js');
  const bot = { botToken: '1:a', chatId: '2' };
  const cases = [
    [{}, 'completed'], [{ telegram: bot }, 'completed'],
    [{ telegram: { ...bot, notifyOnComplete: true } }, 'completed'],
    [{ telegram: { ...bot, notifyOnComplete: true } }, 'on_hold'],
    [{ telegram: { ...bot, notifyOnHold: true } }, 'on_hold'],
    [{ telegram: { ...bot, notifyOnHold: true } }, 'printing'],
  ];
  for (const [settings, to] of cases) {
    const reaches = S.outboundFor({ id: 'o1', status: 'printing' }, to, { settings })
      .some((o) => o.channel === 'telegram');
    const writes = !!TG.forStatus({ id: 'o1' }, to, { settings, fmtPrice: String });
    assert.equal(reaches, writes,
      `outboundFor and the message rule disagree for ${to} with ${JSON.stringify(settings)}`);
  }
});

/* ── Putting a job on hold ─────────────────────────────────────────────────── */

test('a job put on hold records when, so it can be given the days back', () => {
  const order = { id: 'o1', status: 'printing', dueDate: '2026-09-20' };
  S.apply(order, 'on_hold', { now: NOW_MS });
  assert.equal(order.heldAt, NOW_ISO);

  // Nine days later it resumes, and the due date moves by nine.
  const later = NOW_MS + 9 * 86400000;
  const out = S.apply(order, 'printing', { now: later });
  assert.equal(order.dueDate, '2026-09-29');
  assert.equal(order.heldAt, undefined);
  assert.deepEqual(out.notices, [{ code: 'due_extended', params: { days: 9, date: '2026-09-29' } }]);
});

test('a caller that recorded the hold itself keeps its own moment', () => {
  const order = { id: 'o1', status: 'printing', heldAt: '2026-08-01T00:00:00.000Z' };
  S.apply(order, 'on_hold', { now: NOW_MS });
  assert.equal(order.heldAt, '2026-08-01T00:00:00.000Z');
});

test('a reason is optional, and "none given" is stored as none', () => {
  const withReason = { id: 'o1', status: 'printing' };
  S.apply(withReason, 'on_hold', { now: NOW_MS, holdReason: 'waiting on filament' });
  assert.equal(withReason.holdReason, 'waiting on filament');

  // Held again after resuming, this time with nothing typed: the old reason
  // must not survive as an explanation for a different hold.
  S.apply(withReason, 'pending', { now: NOW_MS });
  S.apply(withReason, 'on_hold', { now: NOW_MS, holdReason: '' });
  assert.equal(withReason.holdReason, null);

  // A caller that says nothing about the reason changes nothing about it.
  const quiet = { id: 'o2', status: 'printing', holdReason: 'kept' };
  S.apply(quiet, 'on_hold', { now: NOW_MS });
  assert.equal(quiet.holdReason, 'kept');
});

test('holding a printing job stops its timer', () => {
  const order = {
    id: 'o1', status: 'printing',
    timerStart: '2026-09-04T08:00:00.000Z', printingStartedAt: '2026-09-03T00:00:00.000Z',
  };
  S.apply(order, 'on_hold', { now: NOW_MS });
  assert.equal(order.timerStart, undefined, 'elapsed time must not accrue while nobody is working on it');
  assert.equal(order.printingStartedAt, '2026-09-03T00:00:00.000Z');
});

test('a finished job is not still being printed', () => {
  const order = {
    id: 'o1', status: 'printing',
    timerStart: '2026-09-04T08:00:00.000Z', timerPausedAt: '2026-09-04T08:30:00.000Z',
    timerPausedMs: 900000, printingStartedAt: '2026-09-03T00:00:00.000Z',
  };
  S.apply(order, 'completed', { now: NOW_MS });
  assert.equal(order.timerStart, undefined);
  assert.equal(order.timerPausedAt, undefined);
  assert.equal(order.timerPausedMs, undefined);
  assert.equal(order.printingStartedAt, '2026-09-03T00:00:00.000Z',
    'when it first went on the machine is a fact about the job, not about the clock');
});

/* ── Passing QC ────────────────────────────────────────────────────────────── */

test('a job that passed inspection says so, in the fields Khayt reads', () => {
  const order = { id: 'o1', status: 'qc' };
  S.apply(order, 'completed', { now: NOW_MS, qc: { outcome: 'pass', notes: 'clean', inspector: 'OP1' } });
  assert.equal(order.qcStatus, 'pass');
  assert.equal(order.qcAt, NOW_ISO);
  assert.equal(order.qcPassedAt, NOW_ISO, 'qcStatusOf falls back to this one');
  assert.equal(order.qcNotes, 'clean');
  assert.equal(order.inspector, 'OP1');
});

test('an unnamed inspector is nobody, not whoever inspected the last job', () => {
  const order = { id: 'o1', status: 'qc', inspector: 'OP-OLD' };
  S.apply(order, 'completed', { now: NOW_MS, qc: { outcome: 'pass' } });
  assert.equal(order.inspector, null);
  assert.equal(order.qcNotes, null);
});

test('a completion with no QC record leaves the fields alone', () => {
  // Completing from the column button is not an inspection, and pretending it
  // was would make a shop's pass rate a fiction.
  const order = { id: 'o1', status: 'printing' };
  S.apply(order, 'completed', { now: NOW_MS });
  assert.equal(order.qcStatus, undefined);
  assert.equal(order.qcPassedAt, undefined);
});

test('only a pass is recorded here — a failure does not end in completed', () => {
  const order = { id: 'o1', status: 'qc' };
  S.apply(order, 'completed', { now: NOW_MS, qc: { outcome: 'fail', notes: 'warped' } });
  assert.equal(order.qcStatus, undefined, 'a failure is a waste entry and a decision, not a completion');
});

/* ── Delivered is a handover, not a status ─────────────────────────────────── */

test('a handed-over job is a completed job that carries the date', () => {
  assert.equal(S.stageOf({ status: 'completed' }), 'completed');
  assert.equal(S.stageOf({ status: 'completed', deliveredAt: '2026-09-01T00:00:00.000Z' }), 'delivered');
  assert.equal(S.stageOf({ status: 'printing' }), 'printing');
  assert.equal(S.stageOf({ status: 'printing', deliveredAt: 'x' }), 'printing',
    'a date on an unfinished job says nothing — the pair is the rule');
  assert.equal(S.stageOf({ status: 'split' }), 'split', 'returned as itself, for the caller to place');
  assert.equal(S.stageOf(null), null);
});

test('marking delivered does not move the status, and that is the whole rule', () => {
  // Moving it would empty the very column the button feeds: the Delivered
  // column IS completed-jobs-with-a-date.
  const order = { id: 'o1', status: 'completed' };
  const out = S.markDelivered(order, { now: NOW_MS });
  assert.equal(out.ok, true);
  assert.equal(order.status, 'completed');
  assert.equal(order.deliveredAt, NOW_ISO);
  assert.equal(S.stageOf(order), 'delivered');
  assert.deepEqual(order.statusHistory, [{ status: 'delivered', at: NOW_ISO }]);
});

test('a job cannot be delivered before it is made', () => {
  for (const status of ['quote', 'pending', 'printing', 'post', 'qc', 'on_hold']) {
    const order = { id: 'o1', status };
    const out = S.markDelivered(order, { now: NOW_MS });
    assert.equal(out.ok, false, `${status} should not be deliverable`);
    assert.equal(out.block.code, 'not_completed');
    assert.equal(order.deliveredAt, undefined, 'and nothing is written');
  }
});

test('the handover reaches the activity log and the dashboard', () => {
  const order = { id: 'o1', status: 'completed' };
  const types = S.markDelivered(order, { now: NOW_MS }).effects.map(e => e.type);
  assert.deepEqual(types, ['activity_log', 'save', 'render', 'toast_delivered']);
});

/**
 * ── THE TWO SPELLINGS OF FINISHED ──────────────────────────────────────────
 *
 * Khayt wrote `delivered` before it wrote `completed` with a `deliveredAt`
 * beside it, and both are still in shops' books. The test was written out by
 * hand in at least eight modules, and two callers got it wrong: the machine
 * P&L and the machine revenue chart filtered `completed` alone, so every job
 * a shop had marked delivered was missing from what its printers had earned.
 */
test('finished means either spelling, and nothing else', () => {
  const S = require('../lib/order-status.js');
  assert.deepEqual([...S.FINISHED_STATUSES].sort(), ['completed', 'delivered']);
  assert.equal(S.isFinished({ status: 'completed' }), true);
  assert.equal(S.isFinished({ status: 'delivered' }), true);
  for (const st of ['printing', 'quote', 'pending', 'post', 'qc', 'on_hold', 'cancelled', '', null, undefined]) {
    assert.equal(S.isFinished({ status: st }), false, String(st));
  }
  // A missing order is not a finished one.
  assert.equal(S.isFinished(null), false);
  assert.equal(S.isFinished(undefined), false);
  assert.equal(S.isFinished({}), false);
});

test('the machine charts ask the rule rather than comparing by hand', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
  for (const fn of ['renderMachineRevenueChart', 'renderMachinePL']) {
    const at = src.indexOf('function ' + fn);
    assert.ok(at > 0, fn + ' has moved');
    const body = src.slice(at, at + 1200);
    assert.ok(!/o\.status === 'completed'/.test(body),
      fn + ' compares the status by hand again — delivered jobs will go missing');
    assert.ok(/KhaytOrderStatus\.isFinished/.test(body), fn + ' no longer asks the rule');
  }
});
