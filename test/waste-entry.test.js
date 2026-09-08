/**
 * lib/waste-entry.js is the waste form's save and delete, lifted out of
 * renderer/waste.js.
 *
 * THE PROOF: the original save handler's record lines and its spool deduction
 * are copied below VERBATIM and run beside the module over generated forms and
 * shelves; the entry and the shelf are compared. The one deliberate fix — the
 * entry now records which spool it deducted from — is outside the comparison
 * (the original wrote nothing there) and has its own tests.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/waste-entry.js');
const QC = require('../lib/qc-failure.js');

const ORIGINAL = `
      const material    = $('#wf_material').value.trim();
      const failureType = $('#wf_failure_type').value;
      const weight      = Math.max(0, +$('#wf_weight').value || 0);
      const cost        = Math.max(0, +$('#wf_cost').value || 0);
      const reason      = $('#wf_reason').value.trim();
      const notes       = $('#wf_notes').value.trim();
      const deduct      = $('#wf_deduct').checked;
      const date        = $('#wf_date').value || today;
      const orderRef    = ($('#wf_order_ref').value || '').trim() || null;
      const machineId   = ($('#wf_machine')?.value || '').trim() || null;

      if (!material) { return { refused: 'material' }; }

      const entry = {
        id: ID,
        date,
        material,
        failureType,
        weight,
        cost,
        reason,
        notes,
        orderId: orderRef,
        machineId,
      };

      // Auto-deduct from matching inventory spool
      if (deduct && weight > 0) {
        const spool = inventory.find(f => f.material === material);
        if (spool) {
          spool.weight = Math.max(0, (+spool.weight || 0) - weight);
        }
      }
      return { entry };`;

function runOriginal(form, ctx) {
  const els = {
    '#wf_material': { value: form.material }, '#wf_failure_type': { value: form.failureType },
    '#wf_weight': { value: form.weight }, '#wf_cost': { value: form.cost },
    '#wf_reason': { value: form.reason }, '#wf_notes': { value: form.notes },
    '#wf_deduct': { checked: form.deduct }, '#wf_date': { value: form.date },
    '#wf_order_ref': { value: form.orderId },
  };
  if (form.machineId !== undefined) els['#wf_machine'] = { value: form.machineId };
  const fn = new Function('$', 'today', 'ID', 'inventory', ORIGINAL);
  return fn((sel) => els[sel] || null, ctx.today, ctx.id, ctx.inventory);
}

function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];
const shelf = (r) => [
  { id: 'S1', material: 'PLA', weight: pick(r, [0, 30, 500]), cost: pick(r, [0, 90]) },
  { id: 'S2', material: 'PLA', weight: 800, cost: 100 },
  { material: 'PETG', weight: 200, cost: 120 },      // a spool with no id
];

test('the module and the original agree, entry and shelf, over 4000 generated forms', () => {
  const r = rng(777);
  for (let i = 0; i < 4000; i++) {
    const form = {
      material: pick(r, ['', ' PLA ', 'PETG', 'ABS']),
      failureType: pick(r, W.FAILURE_TYPES),
      weight: pick(r, ['', '0', '-2', '50', '25.5', 'x', '1000']),
      cost: pick(r, ['', '0', '4.5', 'x']),
      reason: pick(r, ['', ' shift ']), notes: pick(r, ['', 'n ']),
      deduct: pick(r, [true, false]),
      date: pick(r, ['', '2026-09-01']),
      orderId: pick(r, ['', ' ORD-9 ']),
      machineId: pick(r, [undefined, '', 'M1']),
    };
    const a = shelf(r), b = JSON.parse(JSON.stringify(a));
    const theirs = runOriginal(form, { today: '2026-09-04', id: 'w-1', inventory: a });
    const ours = W.newEntry(form, { today: '2026-09-04', id: 'w-1', inventory: b });
    if (ours.entry) delete ours.entry.spoolId;   // the deliberate addition
    assert.deepEqual(ours, theirs, JSON.stringify(form));
    assert.deepEqual(b, a, 'the shelf after: ' + JSON.stringify(form));
  }
});

test('an entry that deducted remembers the spool, and deleting it puts the grams back', () => {
  const inventory = [{ id: 'S1', material: 'PLA', weight: 500, cost: 100 }];
  const { entry } = W.newEntry({ material: 'PLA', weight: 120, deduct: true }, { id: 'w-1', today: '2026-09-04', inventory });
  assert.equal(entry.spoolId, 'S1');
  assert.equal(inventory[0].weight, 380);
  const log = [entry];
  const removed = W.removeEntry(log, 'w-1', { inventory });
  assert.equal(removed, entry);
  assert.equal(log.length, 0);
  assert.equal(inventory[0].weight, 500, 'restored — the renderer read spoolId here and nothing ever wrote it');
});

test('an entry that did not deduct, or came off a spool with no id, restores nothing', () => {
  const inventory = [{ material: 'PETG', weight: 200, cost: 120 }];
  const { entry } = W.newEntry({ material: 'PETG', weight: 50, deduct: true }, { id: 'w-2', today: '2026-09-04', inventory });
  assert.equal(entry.spoolId, undefined, 'no id to remember');
  assert.equal(inventory[0].weight, 150, 'but the grams still came off, as they always did');
  const log = [entry];
  W.removeEntry(log, 'w-2', { inventory });
  assert.equal(inventory[0].weight, 150);
  assert.equal(W.removeEntry(log, 'nope', { inventory }), null);
});

test('the cost of wasted grams agrees with the QC failure\'s rule', () => {
  const r = rng(99);
  for (let i = 0; i < 500; i++) {
    const inv = shelf(r);
    const material = pick(r, ['PLA', 'PETG', 'ABS', '']);
    const grams = pick(r, [0, 12.5, 50, -1, 'x']);
    assert.equal(W.costOf(material, grams, inv), QC.wasteCost(material, grams, inv), `${material} ${grams}`);
  }
});

test('a failure category the log does not know is filed as other', () => {
  const { entry } = W.newEntry({ material: 'PLA', failureType: 'gremlins' }, { id: 'w', today: '2026-09-04' });
  assert.equal(entry.failureType, 'other');
  assert.deepEqual(W.FAILURE_TYPES, QC.FAILURE_TYPES, 'and the two writers of the log agree on the categories');
});

test('totals', () => {
  const t = W.totals([{ weight: 10, cost: 1, failureType: 'warping' }, { weight: '5', cost: '2.5' }]);
  assert.deepEqual(t, { count: 2, grams: 15, cost: 3.5, byFailureType: { warping: 1, other: 1 } });
});

const round2 = (n) => Math.round(n * 100) / 100;
const costOf = W.costOf;

test('wasted plastic costs what the roll cost, not what is left of it', () => {
  require('../lib/spool-edit.js');
  // A 500 g roll of PA-CF bought at 240 is 0.48 a gram, all its life. `weight`
  // is what is LEFT and falls as the shop prints, so dividing the price by it
  // made the plastic dearer every time somebody used some: with 120 g left this
  // read 2.00 a gram and costed 180 g at 360.00 instead of 86.40 — four times
  // over, and without bound as the roll empties.
  const nearlyEmpty = [{ id: 'sp', material: 'PA-CF', cost: 240, weight: 120, spoolWeight: 500 }];
  const full = [{ id: 'sp', material: 'PA-CF', cost: 240, weight: 500, spoolWeight: 500 }];
  assert.equal(round2(costOf('PA-CF', 180, nearlyEmpty)), 86.40);
  assert.equal(round2(costOf('PA-CF', 180, full)), 86.40,
    'the same 180 g costs the same whether the roll is full or nearly gone');

  // A roll bought before `spoolWeight` existed is the one case with no better
  // answer — what it originally weighed is unrecoverable — so it still divides
  // by what is left. Stated so nobody "fixes" it into inventing a figure.
  const legacy = [{ id: 'sp', material: 'PA-CF', cost: 240, weight: 120 }];
  assert.equal(round2(costOf('PA-CF', 180, legacy)), 360,
    'unrecoverable, and it must not guess');
});

test('a registered shop did not pay the tax on the plastic it threw away', () => {
  require('../lib/spool-edit.js');
  const roll = [{ id: 'sp', material: 'PA-CF', cost: 240, weight: 500, spoolWeight: 500, vatAmount: 31.30 }];
  assert.equal(round2(costOf('PA-CF', 180, roll, false)), 86.40, 'not registered: it paid all of it');
  assert.equal(round2(costOf('PA-CF', 180, roll, true)), 75.13, 'registered: the tax comes back');
  // A roll with no tax recorded costs what it cost, whatever the shop is.
  const plain = [{ id: 'sp', material: 'PA-CF', cost: 240, weight: 500, spoolWeight: 500 }];
  assert.equal(round2(costOf('PA-CF', 180, plain, true)), 86.40);
});
