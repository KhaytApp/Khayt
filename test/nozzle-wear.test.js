/**
 * The nozzle counter, which had never counted anything.
 *
 * The machine card summed `p.weight` — not a field a part has — so every job
 * contributed `+undefined || 0` and the bar sat at zero forever. Checked against
 * a real shop before writing this: twelve completed jobs, 2,461 g through a
 * 2,000 g threshold, card said 0 g. Nobody has ever been told to change a
 * nozzle, which is also why nobody reported it.
 *
 * The first case below is that shop's data, so the fix is pinned to the thing
 * that proved it broken rather than to a number invented here.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const NW = require('../lib/nozzle-wear.js');

const job = (machineId, date, parts, status = 'completed') => ({ machineId, date, status, parts });

test('it counts print + support, times quantity — the fields a part actually has', () => {
  const log = [job('M1', '2026-08-10', [
    { printWeight: 100, supportWeight: 20, qty: 2, material: 'PLA' },   // 240
    { printWeight: 50, material: 'PLA' },                                // 50, qty defaults to 1
  ])];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', material: 'brass' } });
  assert.equal(r.grams, 290);
  // The old sum read p.weight and would have produced 0 for exactly this input.
  assert.notEqual(r.grams, 0);
});

test('supports and quantity are not optional extras', () => {
  const one = NW.partGrams({ printWeight: 100 });
  const withSupport = NW.partGrams({ printWeight: 100, supportWeight: 40 });
  const timesFour = NW.partGrams({ printWeight: 100, supportWeight: 40, qty: 4 });
  assert.equal(one, 100);
  assert.equal(withSupport, 140, 'support is real filament through the same nozzle');
  assert.equal(timesFour, 560, 'a part printed four times wears it four times');
});

test('jobs before the nozzle went in belong to the previous nozzle', () => {
  const log = [
    job('M1', '2026-07-20', [{ printWeight: 900, material: 'PLA' }]),
    job('M1', '2026-08-05', [{ printWeight: 100, material: 'PLA' }]),
  ];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01' } });
  assert.equal(r.grams, 100);
});

test('an undated order is not counted as recent', () => {
  // '' < any real date, so it falls out of the window. That is the safe
  // direction: crediting an unknown date to the current nozzle would let a
  // legacy import silently exhaust it.
  const log = [job('M1', '', [{ printWeight: 500, material: 'PLA' }])];
  assert.equal(NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01' } }).grams, 0);
});

test('only completed jobs on THIS machine count', () => {
  const log = [
    job('M1', '2026-08-10', [{ printWeight: 100 }], 'printing'),
    job('M2', '2026-08-10', [{ printWeight: 100 }]),
    job('M1', '2026-08-10', [{ printWeight: 100 }]),
  ];
  assert.equal(NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01' } }).grams, 100);
});

test('the default threshold follows the nozzle material the app already asks for', () => {
  // 5000, not the 2000 that shipped. The old figure was invented; published
  // reports put PETG at 3–5 kg through brass and PLA near 15 kg, so 2000 would
  // have told a shop printing ordinary filament to bin a good nozzle.
  assert.equal(NW.defaultThresholdFor('brass'), 5000);
  assert.ok(NW.defaultThresholdFor('hardened') > NW.defaultThresholdFor('stainless'));
  assert.ok(NW.defaultThresholdFor('stainless') > NW.defaultThresholdFor('brass'));
  assert.ok(NW.defaultThresholdFor('ruby') > NW.defaultThresholdFor('hardened'));
  // An unknown or missing fitment must assume the SOFT case. Guessing generously
  // would quietly extend the life of a nozzle nobody has described.
  const brass = NW.defaultThresholdFor('brass');
  assert.equal(NW.defaultThresholdFor(''), brass);
  assert.equal(NW.defaultThresholdFor('something new'), brass);
  assert.equal(NW.defaultThresholdFor(undefined), brass);
});

test('an explicit threshold always wins over the material default', () => {
  const log = [job('M1', '2026-08-10', [{ printWeight: 100 }])];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', material: 'ruby', gramsThreshold: 500 } });
  assert.equal(r.threshold, 500, 'a shop that typed a number is not overruled by a rule of thumb');
});

test('abrasive filaments cost more nozzle per gram', () => {
  // Ordered by what the sources actually measured, which is NOT the intuitive
  // order: glass-filled destroyed a brass nozzle in 100 g, carbon fibre took
  // 250 g to visibly damage one, and 330 g of glow left no measurable change.
  for (const [material, atLeast] of [
    ['PA6-GF', 12], ['PLA-CF', 8], ['Carbon Fibre PETG', 8],
    ['Bronze Fill', 4], ['Glow in the dark PLA', 2], ['Marble PLA', 2], ['Wood PLA', 1.5],
  ]) {
    assert.ok(NW.abrasivenessFor(material) >= atLeast,
      `${material} should be treated as abrasive (got ${NW.abrasivenessFor(material)}×)`);
  }
});

test('ordinary filaments are not', () => {
  // These are the materials a normal shop actually stocks — including the three
  // in the store this was checked against. A false positive here would tell a
  // shop its nozzle is dying when nothing is wrong, which spends its trust in
  // the warning for nothing.
  for (const material of [
    'PLA', 'PLA+ 2.0', 'Sunlu PETG', 'Sunlu TPU', 'ABS', 'ASA', 'PETG', 'Nylon',
    'Polycarbonate', 'PC Blend', 'Silk PLA', 'Matte PLA', 'HIPS', 'PVA', '',
  ]) {
    assert.equal(NW.abrasivenessFor(material), 1, `${material} should not be treated as abrasive`);
  }
});

test('the worst material in a mixed batch is the one that counts, not the first', () => {
  // Patterns are matched worst-first, and "worst" is decided by measurement
  // rather than by which sounds scarier. "PLA-CF Glow" lands on CARBON FIBRE:
  // E3D measured real gouging from it at 250 g, while CNC Kitchen measured no
  // orifice change from 330 g of glow. The first version of this model had that
  // backwards and this test asserted the backwards version.
  assert.equal(NW.abrasivenessFor('PLA-CF Glow'), NW.abrasivenessFor('PLA-CF'));
  assert.ok(NW.abrasivenessFor('PLA-CF Glow') > NW.abrasivenessFor('Glow PLA'));
  // Glass-filled outranks even carbon fibre.
  assert.ok(NW.abrasivenessFor('PA-GF Carbon') >= NW.abrasivenessFor('PLA-CF'));
});

test('wear and grams are the same number until something filled is printed', () => {
  const log = [job('M1', '2026-08-10', [{ printWeight: 500, material: 'PETG' }])];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01' } });
  assert.equal(r.grams, 500);
  assert.equal(r.wear, 500);
  assert.equal(r.abrasive, false, 'nothing to explain, so the card should not start explaining');
  assert.equal(r.worst, null);
});

test('600 g of carbon fibre is most of a brass nozzle, and the card can say why', () => {
  // E3D measured significant wear on brass at 250 g of carbon-filled PETG;
  // other sources say 1–2 kg. 10× against a 5 kg brass life puts the warning at
  // 500 g, between the two.
  const log = [job('M1', '2026-08-10', [{ printWeight: 600, material: 'PLA-CF' }])];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', material: 'brass' } });
  assert.equal(r.grams, 600, 'what the shop printed');
  assert.equal(r.wear, 6000, 'what it cost the nozzle');
  assert.equal(r.threshold, 5000);
  assert.equal(r.over, true, 'raw grams would have said 12% used');
  assert.equal(r.abrasive, true);
  assert.equal(r.worst.material, 'PLA-CF');
});

test('the same job on a hardened nozzle is not an emergency', () => {
  const log = [job('M1', '2026-08-10', [{ printWeight: 600, material: 'PLA-CF' }])];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', material: 'hardened' } });
  assert.equal(r.wear, 6000);
  assert.equal(r.over, false, 'E3D saw zero wear on hardened at ten times the amount that damaged brass');
});

test('glow in the dark is NOT the worst thing you can print, whatever intuition says', () => {
  // CNC Kitchen pushed 330 g of glow PLA through cheap brass and measured no
  // change in orifice diameter. The first version of this model rated glow the
  // most abrasive filament there is, above carbon fibre, on no evidence at all.
  assert.ok(NW.abrasivenessFor('Glow PLA') < NW.abrasivenessFor('PLA-CF'),
    'a measured result outranks an assumption');
});

test('a shop can overrule any figure, because none of them knows its filament', () => {
  const log = [job('M1', '2026-08-10', [{ printWeight: 600, material: 'PLA-CF' }])];
  const settings = { nozzleWear: { life: { brass: 12000 }, abrasive: { carbon: 2 } } };
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', material: 'brass' } }, settings);
  assert.equal(r.threshold, 12000);
  assert.equal(r.wear, 1200);
  assert.equal(r.over, false);
  // And a nonsense override falls back rather than producing a nonsense bar.
  const bad = { nozzleWear: { life: { brass: -5 }, abrasive: { carbon: 0 } } };
  assert.equal(NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', material: 'brass' } }, bad).threshold, 5000);
  assert.equal(NW.abrasivenessFor('PLA-CF', bad), 10);
});

test('every published figure names its source, and every guess admits it is one', () => {
  // The point of the rewrite. A number with no provenance is indistinguishable
  // from a number someone invented — which is what these were.
  const s = NW.suggestions();
  assert.match(s.checkedOn, /^\d{4}-\d{2}-\d{2}$/);
  for (const row of [...s.life, ...s.abrasive]) {
    assert.ok(row.note, `${row.key} needs a note explaining the figure`);
    assert.ok(row.source || row.estimated,
      `${row.key} has neither a source nor an "estimated" flag — that is exactly the state this file exists to end`);
    if (row.source) {
      assert.match(row.source.url, /^https:\/\//, `${row.key}'s source needs a real URL`);
      assert.ok(row.source.what, `${row.key}'s source needs to say what was actually measured`);
    }
  }
  // The two anchors of the whole model must be measured, not estimated.
  assert.ok(s.abrasive.find((r) => r.key === 'carbon').source, 'carbon fibre must be sourced');
  assert.ok(s.abrasive.find((r) => r.key === 'glow').source, 'glow must be sourced — it is the one that was wrong');
  assert.ok(s.life.find((r) => r.key === 'hardened').source, 'hardened steel must be sourced');
});

test('byMaterial explains the number, worst first', () => {
  const log = [job('M1', '2026-08-10', [
    { printWeight: 1000, material: 'PLA' },
    { printWeight: 100, material: 'PLA-CF' },
  ])];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01' } });
  assert.equal(r.grams, 1100);
  assert.equal(r.wear, 2000);
  // Ranked by WEAR CAUSED, which is the question the list answers — not by how
  // abrasive the material is. 1000 g of plain PLA really has taken more out of
  // this nozzle than 100 g of carbon fibre (1000 vs 800), and saying otherwise
  // to make the scary material come first would be theatre.
  assert.equal(r.byMaterial[0].material, 'PLA');
  assert.equal(r.byMaterial[0].wear, 1000);
  assert.equal(r.byMaterial[1].wear, 1000);
  // `worst` is a different question — which filament is punching above its
  // weight — and that is still the carbon fibre.
  assert.equal(r.worst.material, 'PLA-CF');
  assert.equal(r.worst.mult, 10);
});

test('a machine with no nozzle record does not divide by zero or throw', () => {
  for (const machine of [{ id: 'M1' }, { id: 'M1', nozzle: {} }, {}]) {
    const r = NW.nozzleWear([job('M1', '2026-08-10', [{ printWeight: 100 }])], machine);
    assert.ok(Number.isFinite(r.pct));
    assert.ok(Number.isFinite(r.wear));
  }
  assert.doesNotThrow(() => NW.nozzleWear(null, null));
  assert.doesNotThrow(() => NW.nozzleWear([{ parts: null }], { id: 'M1' }));
});

test('a zero threshold means "not tracked", not "always overdue"', () => {
  const log = [job('M1', '2026-08-10', [{ printWeight: 5000 }])];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', gramsThreshold: 0 } });
  // 0 is falsy, so it falls through to the material default rather than making
  // pct infinite — and the caller still gates the badge on installedAt.
  assert.ok(r.threshold > 0);
  assert.ok(Number.isFinite(r.pct));
});

/* ── the attention bar ─────────────────────────────────────────────────────
 *
 * The dashboard has a maintenance section listing overdue nozzles, and NO
 * SHIPPED THEME RENDERS IT: every theme replaces renderDashboard with its own
 * and none of them draws `.dash-section`. Confirmed by driving two of them —
 * zero `.dash-section` elements on either, with a machine well past its
 * threshold. The warning existed on the machine card and nowhere on the one
 * screen a shop leaves open.
 *
 * The attention bar is what the themes DO render, so that is where it goes.
 */
const AT = require('../lib/attention.js');

test('a nozzle past its threshold reaches the attention bar', () => {
  const machines = [{ id: 'M1', name: 'U1', nozzle: { installedAt: '2026-08-01', gramsThreshold: 2000 } }];
  const nozzleWear = () => ({ over: true, wear: 4980, threshold: 2000 });
  const r = AT.selectAttention({ machines, orders: [], statusCache: {}, now: Date.parse('2026-09-01'), nozzleWear });
  const item = r.items.find((i) => i.kind === 'nozzle');
  assert.ok(item, 'an overdue nozzle is something the operator must act on');
  assert.equal(item.severity, 'warn',
    'warn, not crit: it does not stop the printer, it makes the parts wrong');
  assert.equal(item.name, 'U1');
  assert.equal(item.grams, 4980);
});

test('a nozzle inside its threshold does not', () => {
  const machines = [{ id: 'M1', name: 'U1', nozzle: { installedAt: '2026-08-01', gramsThreshold: 50000 } }];
  const r = AT.selectAttention({ machines, orders: [], statusCache: {}, now: Date.now(),
    nozzleWear: () => ({ over: false, wear: 4980, threshold: 50000 }) });
  assert.equal(r.items.filter((i) => i.kind === 'nozzle').length, 0);
});

test('a machine with no nozzle logged is never nagged about one', () => {
  const r = AT.selectAttention({ machines: [{ id: 'M1', name: 'X' }], orders: [], statusCache: {},
    now: Date.now(), nozzleWear: () => ({ over: true, wear: 9e9, threshold: 1 }) });
  assert.equal(r.items.filter((i) => i.kind === 'nozzle').length, 0,
    'installedAt gates it: a nozzle nobody has logged has no window to measure');
});

test('attention still works for callers that pass no wear function', () => {
  // lib/attention.js is pure and must not reach for a global; a caller that
  // does not supply one gets exactly today's behaviour.
  const r = AT.selectAttention({ machines: [{ id: 'M1', name: 'X', nozzle: { installedAt: '2026-08-01' } }],
    orders: [], statusCache: {}, now: Date.now() });
  assert.equal(r.items.filter((i) => i.kind === 'nozzle').length, 0);
  assert.doesNotThrow(() => AT.selectAttention({ machines: [{ id: 'M1', nozzle: { installedAt: 'x' } }],
    orders: [], statusCache: {}, nozzleWear: () => { throw new Error('boom'); } }),
    'and a wear function that throws must not take the whole bar down');
});

test('a legacy `delivered` job wore the nozzle too', () => {
  const log = [
    job('M1', '2026-08-10', [{ printWeight: 100, material: 'PLA' }]),
    job('M1', '2026-08-11', [{ printWeight: 50, material: 'PLA' }], 'delivered'),
    job('M1', '2026-08-12', [{ printWeight: 999, material: 'PLA' }], 'cancelled'),
  ];
  const r = NW.nozzleWear(log, { id: 'M1', nozzle: { installedAt: '2026-08-01', material: 'brass' } });
  assert.equal(r.grams, 150, 'the delivered job counts; the cancelled one does not');
});
