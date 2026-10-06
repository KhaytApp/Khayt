const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');

require('../lib/order-status.js'); // globalThis.KhaytOrderStatus
const K = require('../lib/kiosk.js');

// ── THE ORIGINAL, VERBATIM ───────────────────────────────────────────────
//
// renderer/views.js renderKioskView as it stood before the rule moved to
// lib/kiosk.js. Kept as a string and compared against the rewired renderer on
// every case where the lift was meant to change nothing; the cases where it
// was meant to change something are the bug tests further down, each named
// for what the original got wrong.
const ORIGINAL = `
function renderKioskView() {
  const el = $('#kioskView');
  if (!el) return;

  // Build a map: machineId → current active order
  const activeMachines = machines.filter(m => !m.deleted);
  const activeOrders = printLog.filter(o => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote');

  const cards = activeMachines.map(m => {
    const job = activeOrders.filter(o => o.machineId === m.id)
      .sort((a, b) => {
        const rankOf = s => ({ printing: 0, post: 1, qc: 2, pending: 3, on_hold: 4 })[s] ?? 5;
        return rankOf(a.status) - rankOf(b.status);
      })[0] || null;

    const statusColors = {
      printing: '#22c55e',
      post:     '#f59e0b',
      qc:       '#3b82f6',
      pending:  '#6b7280',
      on_hold:  '#ef4444',
    };
    const idleColor = '#374151';

    const borderColor = job ? (statusColors[job.status] || '#6b7280') : idleColor;

    let progressHtml = '';
    if (job) {
      const printHrs = +job.printTime || 0;
      const startedAt = job.printingStartedAt ? new Date(job.printingStartedAt).getTime() : null;
      let pct = 0;
      let etaStr = '';
      if (printHrs > 0 && startedAt) {
        const elapsed = (Date.now() - startedAt) / 3600000;
        pct = Math.min(100, Math.round((elapsed / printHrs) * 100));
        const remaining = Math.max(0, printHrs - elapsed);
        if (remaining > 0) {
          const h = Math.floor(remaining);
          const min = Math.round((remaining - h) * 60);
          etaStr = h > 0 ? \`\${h}h \${min}m\` : \`\${min}m\`;
        } else {
          etaStr = t('kiosk.done') || 'Done';
        }
      } else if (printHrs > 0) {
        etaStr = \`~\${printHrs}h total\`;
      }

      // Enthusiast (hobbyist) mode has no clients — don't show a client name on kiosk cards.
      const kioskBiz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
      const client = (kioskBiz && job.clientId) ? clients.find(c => c.id === job.clientId) : null;
      const clientName = kioskBiz ? (client ? localName(client) : (job.client || '')) : '';

      progressHtml = \`
        <div class="kiosk-job">
          <div class="kiosk-job-name">\${escapeHtml(job.project || t('inv.walk_in'))}</div>
          \${clientName ? \`<div class="kiosk-job-client">👤 \${escapeHtml(clientName)}</div>\` : ''}
          <div class="kiosk-job-status">
            <span class="badge \${escapeHtml(job.status)}" style="font-size:13px;padding:3px 10px;">\${escapeHtml(t('queue.' + job.status))}</span>
          </div>
          \${pct > 0 ? \`
          <div class="kiosk-progress-wrap">
            <div class="kiosk-progress-bar" style="width:\${pct}%;background:\${borderColor};"></div>
          </div>
          <div class="kiosk-eta">\${pct}% \${etaStr ? \`· ETA \${escapeHtml(etaStr)}\` : ''}</div>\` : ''}
          \${job.dueDate ? \`<div class="kiosk-due">📅 \${escapeHtml(job.dueDate)}</div>\` : ''}
        </div>\`;
    } else {
      progressHtml = \`<div class="kiosk-idle">\${escapeHtml(t('kiosk.idle') || 'Idle')}</div>\`;
    }

    return \`
      <div class="kiosk-card" style="border-color:\${borderColor};">
        <div class="kiosk-machine-name">\${escapeHtml(m.name || m.model || m.id)}</div>
        \${m.model && m.name !== m.model ? \`<div class="kiosk-machine-model">\${escapeHtml(m.model)}</div>\` : ''}
        \${progressHtml}
      </div>\`;
  });

  if (cards.length === 0) {
    el.innerHTML = \`<p style="text-align:center;color:var(--text-muted);padding:32px;">\${escapeHtml(t('kiosk.no_machines') || 'No machines configured.')}</p>\`;
    return;
  }

  el.innerHTML = \`<div class="kiosk-grid">\${cards.join('')}</div>\`;
}
`;

const NOW = Date.parse('2026-10-06T12:00:00Z');
const H = 3600000;
const iso = (ms) => new Date(ms).toISOString();

function stage({ machines, orders, clients = [], mode = 'professional' }) {
  const el = { innerHTML: '' };
  global.$ = (sel) => (sel === '#kioskView' ? el : null);
  global.machines = machines;
  global.printLog = orders;
  global.clients = clients;
  global.settings = { mode };
  global.t = (k) => k;
  global.escapeHtml = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;');
  global.localName = (c) => c.name;
  return el;
}

function withClock(fn) {
  const real = Date.now;
  Date.now = () => NOW;
  try { return fn(); } finally { Date.now = real; }
}

const original = vm.runInThisContext('(' + ORIGINAL + ')');
const { renderKioskView: lifted } = require('../renderer/views.js');

function both(world) {
  const a = withClock(() => { const el = stage(world); original(); return el.innerHTML; });
  const b = withClock(() => { const el = stage(world); lifted(); return el.innerHTML; });
  return [a, b];
}

const SAME = {
  'a printing job part way through, with a client looked up by id': {
    machines: [{ id: 'm1', name: 'U1', model: 'Snapmaker U1' }],
    orders: [{ id: 'o1', status: 'printing', machineId: 'm1', project: 'Vase', clientId: 'c1',
      printTime: 4, printingStartedAt: iso(NOW - 1.5 * H), dueDate: '2026-10-08' }],
    clients: [{ id: 'c1', name: 'Noura' }],
  },
  'printing beats pending on the same machine, whatever the book order': {
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [
      { id: 'o0', status: 'pending', machineId: 'm1', project: 'Next' },
      { id: 'o1', status: 'printing', machineId: 'm1', project: 'Now', printTime: 2, printingStartedAt: iso(NOW - 0.5 * H) },
    ],
  },
  'a client id the book has lost falls back to the typed name': {
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'qc', machineId: 'm1', project: 'Gear', clientId: 'gone', client: 'Walk-in Ali' }],
  },
  'an enthusiast has no customers to name': {
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'pending', machineId: 'm1', project: 'Toy', client: 'Ali' }],
    mode: 'enthusiast',
  },
  'idle, deleted, and a finished job that is not the machine\'s any more': {
    machines: [{ id: 'm1', name: 'U1' }, { id: 'm2', name: 'Old', deleted: true }],
    orders: [{ id: 'o1', status: 'completed', machineId: 'm1', project: 'Done' }],
  },
  'no machines at all': { machines: [], orders: [] },
  'a job with no project reads as a walk-in': {
    machines: [{ id: 'm1', name: 'CORE One', model: 'Prusa CORE One' }],
    orders: [{ id: 'o1', status: 'on_hold', machineId: 'm1' }],
  },
};

for (const [name, world] of Object.entries(SAME)) {
  test(`kiosk lift draws exactly what the original drew: ${name}`, () => {
    const [a, b] = both(world);
    assert.equal(b, a);
  });
}

// ── WHAT THE ORIGINAL GOT WRONG ───────────────────────────────────────────

const one = (input) => K.cards(Object.assign({ now: NOW }, input))[0];

test('a cancelled job is not on the machine', () => {
  const world = {
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'cancelled', machineId: 'm1', project: 'Nope' }],
  };
  const [a, b] = both(world);
  assert.match(a, /Nope/, 'the original showed it');
  assert.doesNotMatch(b, /Nope/);
  assert.equal(one(world).state, 'idle');
});

test('a split parent, a voided order and an archived one are not on the machine', () => {
  for (const o of [
    { id: 'p', status: 'split', machineId: 'm1', splitInto: ['a'] },
    { id: 'v', status: 'pending', machineId: 'm1', voidedAt: '2026-10-01' },
    { id: 'r', status: 'pending', machineId: 'm1', archived: true },
  ]) {
    assert.equal(one({ machines: [{ id: 'm1', name: 'U1' }], orders: [o] }).state, 'idle', o.id);
  }
});

test('a job on hold does not advance with the clock', () => {
  const world = {
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'on_hold', machineId: 'm1', printTime: 4, printingStartedAt: iso(NOW - 2 * H) }],
  };
  const [a, b] = both(world);
  assert.match(a, /50%/, 'the original drew a moving bar on a held job');
  assert.doesNotMatch(b, /50%/);
  const c = one(world);
  assert.equal(c.pct, null);
  assert.equal(c.remainingMinutes, null);
});

test('a job in post-processing is not "Done" printing', () => {
  const c = one({
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'post', machineId: 'm1', printTime: 1, printingStartedAt: iso(NOW - 5 * H) }],
  });
  assert.equal(c.pct, null);
});

test('never "1h 60m": minutes are rounded before they are split', () => {
  const world = {
    machines: [{ id: 'm1', name: 'U1' }],
    // 1.999 hours left
    orders: [{ id: 'o1', status: 'printing', machineId: 'm1', printTime: 3, printingStartedAt: iso(NOW - 1.001 * H) }],
  };
  const [a, b] = both(world);
  assert.match(a, /1h 60m/, 'the original said it');
  assert.doesNotMatch(b, /60m/);
  assert.equal(K.duration(one(world).remainingMinutes), '2h 0m');
});

test('past its estimate a print says how far over, not "Done"', () => {
  const world = {
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'printing', machineId: 'm1', printTime: 2, printingStartedAt: iso(NOW - 2.5 * H) }],
  };
  const [a, b] = both(world);
  assert.match(a, /kiosk\.done/, 'the original said Done');
  assert.match(b, /\+30m/);
  const c = one(world);
  assert.equal(c.pct, 100, 'the bar stays in its track');
  assert.equal(c.overrunMinutes, 30);
  assert.equal(c.remainingMinutes, 0);
});

test('an estimate with no start is shown, not built and dropped', () => {
  const world = {
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'printing', machineId: 'm1', printTime: 6 }],
  };
  const [a, b] = both(world);
  assert.doesNotMatch(a, /6h total/, 'the original never drew it');
  assert.match(b, /~6h total/);
  assert.equal(one(world).totalHours, 6);
});

test('a machine with a model and no name says its model once', () => {
  const c = one({ machines: [{ id: 'm1', name: '', model: 'Ender 3' }], orders: [] });
  assert.equal(c.name, 'Ender 3');
  assert.equal(c.model, '');
});

// ── THE PRINTER'S OWN WORD ────────────────────────────────────────────────

test('a live reading beats the clock', () => {
  const c = one({
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'printing', machineId: 'm1', printTime: 4, printingStartedAt: iso(NOW - 1 * H) }],
    live: { m1: { progress: 80, timeRemaining: 1800 } },
  });
  assert.equal(c.source, 'printer');
  assert.equal(c.pct, 80);
  assert.equal(c.remainingMinutes, 30);
});

test('progress alone is turned into time left against the estimate', () => {
  const c = one({
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'printing', machineId: 'm1', printTime: 4 }],
    live: { m1: { progress: 75 } },
  });
  assert.equal(c.remainingMinutes, 60);
});

test('a printer printing a job the book does not know is busy, not idle', () => {
  const c = one({ machines: [{ id: 'm1', name: 'U1' }], orders: [], live: { m1: { progress: 40, timeRemaining: 600 } } });
  assert.equal(c.state, 'busy');
  assert.equal(c.pct, 40);
  assert.equal(c.remainingMinutes, 10);
});

test('a printer that is not answering is marked offline, and the clock is used', () => {
  const c = one({
    machines: [{ id: 'm1', name: 'U1' }],
    orders: [{ id: 'o1', status: 'printing', machineId: 'm1', printTime: 4, printingStartedAt: iso(NOW - 1 * H) }],
    live: { m1: { error: 'timeout' } },
  });
  assert.equal(c.offline, true);
  assert.equal(c.source, 'estimate');
  assert.equal(c.pct, 25);
});

test('an idle printer that is not answering is not "busy"', () => {
  const c = one({ machines: [{ id: 'm1', name: 'U1' }], orders: [], live: { m1: { error: 'x' } } });
  assert.equal(c.state, 'idle');
  assert.equal(c.offline, true);
});
