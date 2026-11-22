'use strict';

/**
 * The alpha.59 pre-release review: the 3MF plate reader on a hostile file, the
 * per-spool and per-plate figures it hands both apps, and the money rules the
 * calculator's consumables and a product's components share.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const mf = require('../lib/mf-convert.js');
const { intake: intakeRaw } = require('../lib/model-intake.js');
const CC = require('../lib/calculator-cost.js');
const { writeZip } = require('../lib/zip-write.js');

const slice = (text) => [{ name: 'Metadata/slice_info.config', data: Buffer.from(text, 'utf8') }];

// ── S2: no quadratic regex on an unclosed <plate ────────────────────────────

test('350 KB of unclosed <plate tags is read in well under a second', () => {
  const evil = '<config>' + '<plate '.repeat(50000) + '<filament '.repeat(20000);
  const settings = '<config>' + '<plate '.repeat(50000) + '<metadata '.repeat(20000);
  const members = [
    { name: 'Metadata/slice_info.config', data: Buffer.from(evil, 'utf8') },
    { name: 'Metadata/model_settings.config', data: Buffer.from(settings, 'utf8') },
  ];
  const t0 = Date.now();
  const meta = mf.extractMeta(members);
  mf.extractPlates(members);
  mf.extractFilaments(members);
  const ms = Date.now() - t0;
  assert.ok(ms < 500, `took ${ms} ms`);
  assert.equal(meta.plates, undefined);
});

test('closed plates past the cap are not read, and filaments per plate are capped', () => {
  const many = '<config>' + Array.from({ length: 400 }, (_, i) =>
    `<plate><metadata key="index" value="${i + 1}"/><metadata key="prediction" value="60"/>`
    + '<filament id="1" used_g="1"/>'.repeat(100) + '</plate>').join('') + '</config>';
  const t0 = Date.now();
  const meta = mf.extractMeta(slice(many));
  assert.ok(Date.now() - t0 < 1000);
  assert.equal(meta.plates.length, 256);
  assert.equal(meta.plates[0].filaments.length, 64);
  assert.equal(meta.printMinutes, 256);
});

// ── S1/S3: indices, figures and names a crafted file cannot poison ──────────

test('a plate index of 1e20, or a repeat, becomes the next free small number', () => {
  const xml = `<config>
    <plate><metadata key="index" value="100000000000000000000"/><metadata key="prediction" value="60"/><filament id="1" used_g="1"/></plate>
    <plate><metadata key="index" value="2"/><metadata key="prediction" value="60"/><filament id="1" used_g="1"/></plate>
    <plate><metadata key="index" value="2"/><metadata key="prediction" value="60"/><filament id="1" used_g="1"/></plate>
  </config>`;
  const meta = mf.extractMeta(slice(xml));
  const idx = meta.plates.map((p) => p.index);
  assert.deepEqual(idx, [1, 2, 3]);
  assert.ok(idx.every(Number.isSafeInteger));
});

test('used_g, used_m and prediction are clamped to finite, sane figures', () => {
  const xml = `<config>
    <plate><metadata key="index" value="1"/><metadata key="prediction" value="${'9'.repeat(400)}"/>
      <filament id="1" type="PLA" used_g="${'9'.repeat(400)}" used_m="${'9'.repeat(400)}"/></plate>
    <plate><metadata key="index" value="2"/><metadata key="prediction" value="60"/>
      <filament id="1" type="PLA" used_g="2"/></plate>
  </config>`;
  const meta = mf.extractMeta(slice(xml));
  for (const v of [meta.totalGrams, meta.printMinutes, ...meta.plates.map((p) => p.filamentGrams),
    ...meta.filaments.map((f) => f.grams), ...meta.filaments.map((f) => f.meters)]) {
    assert.ok(Number.isFinite(v), String(v));
  }
  assert.ok(meta.totalGrams <= 100002);
  assert.ok(meta.printMinutes <= 365 * 24 * 60 + 1);
});

test('plate names are decoded and cut to 80 characters', () => {
  const long = 'A'.repeat(300);
  const members = [
    { name: 'Metadata/slice_info.config', data: Buffer.from(`<config>
      <plate><metadata key="index" value="1"/><metadata key="prediction" value="60"/><filament id="1" used_g="1"/></plate>
      <plate><metadata key="index" value="2"/><metadata key="prediction" value="60"/><filament id="1" used_g="1"/></plate>
    </config>`, 'utf8') },
    { name: 'Metadata/model_settings.config', data: Buffer.from(`<config>
      <plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="Tom &amp; Jerry &#x2014; &lt;lid&gt;"/></plate>
      <plate><metadata key="plater_id" value="2"/><metadata key="plater_name" value="${long}"/></plate>
    </config>`, 'utf8') },
  ];
  const meta = mf.extractMeta(members);
  assert.equal(meta.plates[0].name, 'Tom & Jerry — <lid>');
  assert.equal(meta.plates[1].name.length, 80);
});

// ── S3/B6: embedded G-codes read by their ends, and their cost kept ──────────

const gcode = (t, w, cost, filler) => `; BambuStudio 02.02\n; total estimated time: ${t}\n`
  + `; total filament weight [g] : ${w}\n; filament_type = PLA\n`
  + (cost != null ? `; total filament cost = ${cost}\n` : '')
  + (filler ? 'G1 X1 Y1\n'.repeat(filler) : '');

test('several big embedded G-codes are summed from their head windows', () => {
  const buf = writeZip([
    { name: 'Metadata/plate_1.gcode', data: Buffer.from(gcode('1h 0m 0s', '10', null, 200000), 'utf8') },
    { name: 'Metadata/plate_2.gcode', data: Buffer.from(gcode('0h 30m 0s', '5.5', null, 200000), 'utf8') },
  ]);
  const r = intakeRaw({ filename: 'p.3mf', bytes: buf });
  assert.equal(r.printTimeMins, 90);
  assert.equal(r.filamentGrams, 15.5);
});

test('a multi-plate project keeps a filament cost when every plate G-code states one', () => {
  const info = `<config>
    <plate><metadata key="index" value="1"/><metadata key="prediction" value="3600"/><filament id="1" type="PLA" used_g="10"/></plate>
    <plate><metadata key="index" value="2"/><metadata key="prediction" value="1800"/><filament id="1" type="PLA" used_g="5.5"/></plate>
  </config>`;
  const withCosts = writeZip([
    { name: 'Metadata/slice_info.config', data: Buffer.from(info, 'utf8') },
    { name: 'Metadata/plate_1.gcode', data: Buffer.from(gcode('1h 0m 0s', '10', '1.25'), 'utf8') },
    { name: 'Metadata/plate_2.gcode', data: Buffer.from(gcode('0h 30m 0s', '5.5', '0.70'), 'utf8') },
  ]);
  const r = intakeRaw({ filename: 'p.3mf', bytes: withCosts });
  assert.equal(r.plates.length, 2);
  assert.equal(r.filamentCost, 1.95);
  // Only one plate's G-code: no sum of SOME plates passed off as the cost.
  const onePlate = writeZip([
    { name: 'Metadata/slice_info.config', data: Buffer.from(info, 'utf8') },
    { name: 'Metadata/plate_1.gcode', data: Buffer.from(gcode('1h 0m 0s', '10', '1.25'), 'utf8') },
  ]);
  assert.equal(intakeRaw({ filename: 'p.3mf', bytes: onePlate }).filamentCost, null);
});

// ── B5: one rule for what a consumable costs ─────────────────────────────────

test('a shelf cost of 0 is free; a deleted item costs what was written on the line', () => {
  const shelf = [{ id: 'free', cost: 0 }, { id: 'mag', cost: 0.5 }];
  const part = { consumables: [
    { consumableId: 'free', qty: 4, unitCost: 9 },
    { consumableId: 'mag', qty: 2, unitCost: 9 },
    { consumableId: 'gone', qty: 3, unitCost: 0.2 },
  ] };
  assert.equal(CC.partConsumablesCost(part, { consumables: shelf }), 0 + 1 + 0.6000000000000001);
  // The components rule is the same rule.
  const comps = [
    { consumableId: 'free', qtyPerUnit: 4, unitCost: 9 },
    { consumableId: 'mag', qtyPerUnit: 2 },
    { consumableId: 'gone', qtyPerUnit: 3, unitCost: 0.2 },
  ];
  assert.equal(CC.computeComponentsCost(comps, shelf), 1.6);
});

test('a consumable quantity of Infinity or -4 cannot make a price Infinity or negative', () => {
  const shelf = [{ id: 'mag', cost: 0.5 }];
  const part = { consumables: [
    { consumableId: 'mag', qty: Infinity },
    { consumableId: 'mag', qty: -4 },
    { consumableId: 'mag', qty: 'nan' },
    { consumableId: 'mag', qty: 1e308 },
  ] };
  // Not a number is no quantity; a finite absurd one is held at 9,999.
  assert.equal(CC.partConsumablesCost(part, { consumables: shelf }), 9999 * 0.5);
  assert.equal(CC.consumableQty(1e308), 9999);
  assert.equal(CC.consumableQty(-1), 0);
});

test('the dashboard cost of a job prices part consumables from the shelf it is handed', () => {
  const KR = require('../lib/kpi-rows.js');
  require('../lib/pnl-report.js');
  const o = { parts: [{ qty: 1, printTime: 1, consumables: [{ consumableId: 'mag', qty: 2, unitCost: 1 }] }] };
  // With the shelf the magnet is priced at the shelf's 0 (free); the old Mac
  // context (no shelf) priced it at the written 1 each.
  const withShelf = KR.orderCost(o, { consumables: [{ id: 'mag', cost: 0 }] });
  const pricier = KR.orderCost(o, { consumables: [{ id: 'mag', cost: 3 }] });
  assert.ok(Number.isFinite(withShelf) && Number.isFinite(pricier));
  assert.ok(pricier - withShelf >= 6 - 1e-9, `${pricier} vs ${withShelf}`);
});

// ── B2: a job's components are part of what that job cost ──────────────────

test('per-product profit counts the components a job was priced with', () => {
  const { productProfit } = require('../lib/product-profit.js');
  const orders = [{ id: 'J1', status: 'completed', productId: 'P', price: 100,
    parts: [{ qty: 1, baseCost: 40 }], componentsCost: 15 }];
  const r = productProfit({ orders, products: [{ id: 'P', name: 'Box' }] },
    { revenueOf: (x) => x.price, partCostOf: (p) => p.baseCost });
  assert.equal(r.rows[0].cost, 55);
  assert.equal(r.rows[0].profit, 45);
});
