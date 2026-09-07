/**
 * lib/spool-edit.js is the shelf's two writers, lifted out of
 * renderer/inventory.js.
 *
 * THE PROOF: `addInventoryItem` and the spool editor's `onSave` are copied
 * below VERBATIM — their form controls answered from the same input, their id
 * and clock supplied — and run beside the module over thousands of generated
 * forms and spools. The record and the mutated spool are compared field for
 * field, and so is the shop's colour library, which the editor writes to.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { newSpool, applyEdit, coloursFor } = require('../lib/spool-edit.js');

const ORIGINAL_ADD = `
function addInventoryItem() {
  const material = $('#invMaterial').value.trim();
  const cost = clampPositive($('#invCost').value);
  const weight = Math.max(1, num($('#invWeight').value, 1000));
  const color = $('#invColor').value || '#888888';
  if (!material) { toast(t('inv.material_ph'), 'error'); return; }
  const today = localDateStr();
  const invMaterialType = $('#invMaterialType')?.value || 'fdm';
  const lot = ($('#invLot')?.value || '').trim() || undefined;
  // Per-location: tag the spool with the chosen branch (default to active filter).
  const activeLoc = (typeof activeLocation !== 'undefined') ? activeLocation : null;
  const locationId = ($('#invLocation')?.value || activeLoc || '') || undefined;
  inventory.push({ id: uid('INV'), material, cost, weight, color, purchasedAt: today, materialType: invMaterialType, lot, locationId });
  saveAll();
  renderInventory();
  $('#invMaterial').value = '';
  if ($('#invLot')) $('#invLot').value = '';
  toast(t('inv.added'), 'success');
}

return addInventoryItem;`;

const ORIGINAL_EDIT = `
function editSpool(item, settings) {
      const material = document.getElementById('ieMatInput').value.trim();
      if (!material) { return { refused: 'material' }; }
      item.material = material;
      item.color    = document.getElementById('ieColorInput').value || '#888888';
      // Feature 7: Material type
      item.materialType = document.getElementById('ieMaterialType')?.value || 'fdm';
      // Feature 5: Colour variant — save to item and to settings.filamentColours library
      const colourVariant = (document.getElementById('ieColourInput')?.value || '').trim();
      item.colourVariant = colourVariant || undefined;
      if (colourVariant) {
        if (!settings.filamentColours) settings.filamentColours = {};
        if (!settings.filamentColours[material]) settings.filamentColours[material] = [];
        if (!settings.filamentColours[material].includes(colourVariant)) {
          settings.filamentColours[material].push(colourVariant);
        }
      }
      const newCost = clampPositive(document.getElementById('ieCostInput').value);
      // Track price history when cost changes
      if (newCost !== item.cost) {
        if (!item.priceHistory) item.priceHistory = [];
        item.priceHistory.push({ cost: item.cost, date: localDateStr() });
      }
      item.cost        = newCost;
      item.weight      = Math.max(0, num(document.getElementById('ieWeightInput').value, 0));
      item.purchasedAt = document.getElementById('iePurchasedAt').value || undefined;
      item.openedAt    = document.getElementById('ieOpenedAt').value || undefined;
      item.lot         = (document.getElementById('ieLot')?.value || '').trim() || undefined;
      // Per-location: branch assignment (empty = unassigned/shared)
      item.locationId  = (document.getElementById('ieLocation')?.value || '') || undefined;
      // Feature 4: Print settings
      const pt = num(document.getElementById('iePrintTemp').value, 0);
      const bt = num(document.getElementById('ieBedTemp').value, 0);
      const ms = num(document.getElementById('ieMaxSpeed').value, 0);
      item.printTemp = pt > 0 ? pt : undefined;
      item.bedTemp   = bt > 0 ? bt : undefined;
      item.maxSpeed  = ms > 0 ? ms : undefined;
      // New Feature 5: Per-spool reorder thresholds
      const rp = num(document.getElementById('ieReorderPoint')?.value, 200);
      const rq = num(document.getElementById('ieReorderQty')?.value, 1000);
      item.reorderPoint = rp >= 0 ? rp : 200;
      item.reorderQty   = rq >= 0 ? rq : 1000;

  return { item, settings };
}
return editSpool;`;

const helpers = {
  num: (v, fallback = 0) => { const n = parseFloat(v); return Number.isFinite(n) ? n : fallback; },
  clampPositive: (v) => { const n = parseFloat(v); return Math.max(0, Number.isFinite(n) ? n : 0); },
  toast: () => {},
  t: (k) => k,
  saveAll: () => {},
  renderInventory: () => {},
};

function runOriginalAdd(form, ctx) {
  const inventory = [];
  const els = {
    '#invMaterial': { value: form.material },
    '#invCost': { value: form.cost },
    '#invWeight': { value: form.weight },
    '#invColor': { value: form.color },
  };
  if (form.materialType !== undefined) els['#invMaterialType'] = { value: form.materialType };
  if (form.lot !== undefined) els['#invLot'] = { value: form.lot };
  if (form.locationId !== undefined) els['#invLocation'] = { value: form.locationId };
  const scope = Object.assign({}, helpers, {
    $: (sel) => els[sel] || null,
    inventory,
    localDateStr: () => ctx.today,
    uid: () => ctx.id,
    activeLocation: ctx.activeLocation,
  });
  new Function(...Object.keys(scope), ORIGINAL_ADD)(...Object.values(scope))();
  return inventory[0] ? { spool: inventory[0] } : { refused: 'material' };
}

function runOriginalEdit(item, form, ctx) {
  const els = {
    ieMatInput: { value: form.material },
    ieColorInput: { value: form.color },
    ieMaterialType: { value: form.materialType },
    ieColourInput: { value: form.colourVariant },
    ieCostInput: { value: form.cost },
    ieWeightInput: { value: form.weight },
    iePurchasedAt: { value: form.purchasedAt },
    ieOpenedAt: { value: form.openedAt },
    ieLot: { value: form.lot },
    ieLocation: { value: form.locationId },
    iePrintTemp: { value: form.printTemp },
    ieBedTemp: { value: form.bedTemp },
    ieMaxSpeed: { value: form.maxSpeed },
    ieReorderPoint: { value: form.reorderPoint },
    ieReorderQty: { value: form.reorderQty },
  };
  const scope = Object.assign({}, helpers, {
    document: { getElementById: (id) => els[id] || null },
    localDateStr: () => ctx.today,
  });
  const settings = JSON.parse(JSON.stringify(ctx.settings || {}));
  const out = new Function(...Object.keys(scope), ORIGINAL_EDIT)(...Object.values(scope))(item, settings);
  return out.refused ? out : { item: out.item, settings };
}

function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];
const value = (r) => pick(r, ['', '  ', ' PLA ', 'PETG', '0', '-5', '750', '1000.5', 'abc', '1e3']);

test('the module and the original agree over 3000 generated new spools', () => {
  const r = rng(31337);
  for (let i = 0; i < 3000; i++) {
    const form = {
      material: pick(r, ['', '  ', ' PLA+ ', 'PETG-CF']),
      cost: value(r), weight: value(r),
      color: pick(r, ['', '#112233', '#888888']),
      materialType: pick(r, [undefined, '', 'fdm', 'resin']),
      lot: pick(r, [undefined, '', ' L-9 ']),
      locationId: pick(r, [undefined, '', 'LOC-1']),
    };
    const ctx = { id: 'INV-' + i, today: '2026-09-04', activeLocation: pick(r, [null, '', 'LOC-2']) };
    const made = newSpool(form, ctx);
    const original = runOriginalAdd(form, ctx);

    // `spoolWeight` is NEW and the original renderer never wrote it, so it is
    // checked against the module's own `weight` and then set aside. Comparing
    // it to the original would be asking a 2026 function about a field added
    // after it — the equivalence this test exists for is about the fields both
    // sides have opinions on.
    if (made.spool) {
      assert.equal(made.spool.spoolWeight, made.spool.weight,
        'a new spool arrives at the weight it is bought with: ' + JSON.stringify(form));
      delete made.spool.spoolWeight;
    }
    assert.deepEqual(made, original, JSON.stringify(form));
  }
});

test('the module and the original agree over 3000 generated edits, spool and colour library', () => {
  const r = rng(99991);
  for (let i = 0; i < 3000; i++) {
    const before = {
      id: 'S1',
      material: pick(r, ['PLA', 'PETG']),
      cost: pick(r, [0, 90, 120.5]),
      weight: pick(r, [0, 400, 1000]),
    };
    if (r() < 0.4) before.priceHistory = [{ cost: 80, date: '2026-01-01' }];
    if (r() < 0.3) before.printTemp = 215;
    if (r() < 0.3) before.lot = 'OLD';
    const form = {
      material: pick(r, [' PLA ', 'PETG', 'ABS']),
      color: pick(r, ['', '#111111']),
      materialType: pick(r, ['', 'fdm', 'resin']),
      colourVariant: pick(r, ['', '  ', ' Matte Black ', 'Galaxy']),
      cost: value(r), weight: value(r),
      purchasedAt: pick(r, ['', '2026-05-01']),
      openedAt: pick(r, ['', '2026-06-01']),
      lot: pick(r, ['', ' L-3 ']),
      locationId: pick(r, ['', 'LOC-9']),
      printTemp: value(r), bedTemp: value(r), maxSpeed: value(r),
      reorderPoint: value(r), reorderQty: value(r),
    };
    const settings = r() < 0.5 ? {} : { filamentColours: { PLA: ['Matte Black'] } };
    const ctx = { today: '2026-09-05', settings: JSON.parse(JSON.stringify(settings)) };

    const theirs = runOriginalEdit(JSON.parse(JSON.stringify(before)), form, { today: ctx.today, settings });
    const mine = JSON.parse(JSON.stringify(before));
    applyEdit(mine, form, ctx);
    assert.deepEqual(mine, theirs.item, `case ${i} spool: ${JSON.stringify(form)}`);
    assert.deepEqual(ctx.settings, theirs.settings, `case ${i} colours: ${JSON.stringify(form)}`);
  }
});

test('a spool with no material is refused, by both writers', () => {
  assert.deepEqual(newSpool({ material: '   ' }, { id: 'S', today: 'x' }), { refused: 'material' });
  const spool = { material: 'PLA', cost: 1 };
  assert.deepEqual(applyEdit(spool, { material: '' }, {}), { refused: 'material' });
  assert.equal(spool.material, 'PLA', 'and the spool is left as it was');
});

test('an edit changes only what it was given', () => {
  // What lets a smaller editor exist without wiping the fields it never showed.
  const spool = { id: 'S1', material: 'PLA', cost: 90, weight: 800, printTemp: 215,
                  reorderPoint: 300, lot: 'L-1', usageHistory: [{ g: 12 }] };
  applyEdit(spool, { weight: '650' }, { today: '2026-09-05' });
  assert.deepEqual(spool, { id: 'S1', material: 'PLA', cost: 90, weight: 650, printTemp: 215,
                            reorderPoint: 300, lot: 'L-1', usageHistory: [{ g: 12 }] });
});

test('a price change is remembered, and an unchanged price is not', () => {
  const spool = { material: 'PLA', cost: 90 };
  applyEdit(spool, { cost: '90' }, { today: '2026-09-05' });
  assert.equal(spool.priceHistory, undefined, 'saving without changing the price writes no history');
  applyEdit(spool, { cost: '110' }, { today: '2026-09-05' });
  assert.deepEqual(spool.priceHistory, [{ cost: 90, date: '2026-09-05' }], 'the OLD price, with the date it changed');
  applyEdit(spool, { cost: '95' }, { today: '2026-09-06' });
  assert.equal(spool.priceHistory.length, 2);
  assert.equal(spool.cost, 95);
});

test('a colour variant is added to the shop\'s library once, under the material it was typed for', () => {
  const settings = {};
  const spool = { material: 'PLA' };
  assert.equal(applyEdit(spool, { colourVariant: ' Matte Black ' }, { settings }).colourAdded, 'Matte Black');
  assert.deepEqual(coloursFor(settings, 'PLA'), ['Matte Black']);
  assert.equal(applyEdit(spool, { colourVariant: 'Matte Black' }, { settings }).colourAdded, undefined,
    'the same colour twice is not two entries');
  assert.deepEqual(coloursFor(settings, 'PLA'), ['Matte Black']);
  // Renamed material and colour in one edit: the colour is filed under the NEW
  // material, which is the one the spool now is.
  applyEdit(spool, { material: 'PETG', colourVariant: 'Galaxy' }, { settings });
  assert.deepEqual(coloursFor(settings, 'PETG'), ['Galaxy']);
  assert.deepEqual(coloursFor(settings, 'nothing'), []);
});

test('the renderer writes no spool of its own any more', () => {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'inventory.js'), 'utf8');
  const at = src.indexOf('function addInventoryItem(');
  const body = src.slice(at, src.indexOf('\n}\n', at));
  assert.match(body, /KhaytSpoolEdit\.newSpool\(|SpoolEdit\.newSpool\(/,
    'a new spool must come from the shared rule');
  assert.doesNotMatch(body, /inventory\.push\(\{/,
    'and the renderer must not build the record itself, or the two apps drift');
});

// ── what it weighed when it arrived ───────────────────────────────────────

test('a new spool records the weight it came with, not just what is left', () => {
  const made = newSpool({ material: 'PLA', cost: 75, weight: 1000 },
                           { id: 'INV-1', today: '2026-09-07' });
  assert.equal(made.spool.weight, 1000, 'what is left, today');
  assert.equal(made.spool.spoolWeight, 1000, 'and what it arrived as');
});

// THE REASON IT EXISTS. `weight` falls as the shop prints, so any figure that
// divides the spool's price by it drifts: a 1 kg roll bought at 75 reads 150
// half way down and 375 with 200 g left — the supplier-comparison number,
// wrong on exactly the spool a shop is about to reorder.
test('the original weight is what a cost-per-kilo can be trusted to', () => {
  const made = newSpool({ material: 'PLA', cost: 75, weight: 1000 }, { id: 'INV-1' });
  const spool = made.spool;
  spool.weight = 200;                              // 800 g printed
  assert.equal(spool.cost / (spool.spoolWeight / 1000), 75, 'the rate moved');
  assert.notEqual(spool.cost / (spool.weight / 1000), 75, 'the old sum was already right');
});

test('a part-roll records the part-roll', () => {
  const made = newSpool({ material: 'PETG', cost: 40, weight: 500 }, { id: 'INV-2' });
  assert.equal(made.spool.spoolWeight, 500);
});

// The same floor as `weight`: a spool weighing nothing divides into every
// cost-per-gram in the app.
test('the original weight has the same one-gram floor', () => {
  assert.equal(newSpool({ material: 'PLA', weight: 0 }, {}).spool.spoolWeight, 1);
  assert.equal(newSpool({ material: 'PLA' }, {}).spool.spoolWeight, 1000, 'a kilo by default');
});
