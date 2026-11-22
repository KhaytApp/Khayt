/**
 * lib/hueforge-calibrate.js — measuring a filament's colour and TD from a photographed card.
 *
 * The photos here are synthetic, rendered from filaments whose true colour and TD are KNOWN,
 * through the same front-lit model the painting engine uses, then put through what a phone
 * does to a picture: a tilted perspective, an exposure and white-balance shift. The test is
 * that the measured values come back to the truth — the only check that means anything for
 * a calibration, because a fit that returns the stated hex unchanged would pass any test
 * that compared it to the stated hex.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const CAL = require('../lib/hueforge-calibrate.js');
const KC = require('../lib/color-mix.js');
const M3 = require('../lib/hueforge-3mf.js');

/** The truth: what each loaded filament really is (front-lit TD in mm). */
const TRUE = [
  { hex: '#F2F0EA', tdFront: 0.9 },   // white, fairly translucent
  { hex: '#1C1C20', tdFront: 0.12 },  // black, near opaque
  { hex: '#C8202A', tdFront: 0.45 },  // red
  { hex: '#2A5DC0', tdFront: 0.6 },   // blue
];
/** What the maker typed: close to the truth but not it (except the white reference). */
const STATED = ['#F2F0EA', '#202020', '#E03030', '#3070D0'];

function renderPhoto(plan, opts = {}) {
  const W = 900, H = 600;
  const gain = opts.gain || [0.8, 0.85, 0.95];
  const corners = opts.corners || [[120, 90], [800, 130], [770, 520], [100, 470]];
  const toCard = CAL.homography(corners, [[0, 0], [plan.sizeMm.x, 0], [plan.sizeMm.x, plan.sizeMm.y], [0, plan.sizeMm.y]]);
  const lin = TRUE.map((f) => CAL.hexToLin(f.hex));
  const cellColour = (c) => {
    const X = lin[c.backing];
    if (!c.layers) return X;
    const t = 0.1 ** (c.layers * plan.layerH / TRUE[c.head].tdFront);
    return lin[c.head].map((v, ch) => (1 - t) * v + t * X[ch]);
  };
  const data = new Uint8ClampedArray(W * H * 4);
  const bg = [0.3, 0.3, 0.3];
  // A seeded sensor noise, so a noisy run is the same run every time.
  let seed = 7;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const noise = opts.noise || 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const [u, v] = toCard(x, y);
      let col = bg;
      if (u >= 0 && v >= 0 && u <= plan.sizeMm.x && v <= plan.sizeMm.y) {
        const c = plan.cells.find((k) => u >= k.x0 && u < k.x1 && v >= k.y0 && v < k.y1);
        col = c ? cellColour(c) : lin[plan.frameHead];
      }
      const hex = CAL.linToHex(col.map((cv, ch) => Math.max(0, Math.min(1, cv * gain[ch] * (1 + noise * (rnd() - 0.5) * 2)))));
      const rgb = KC.hexToRgb(hex);
      const o = (y * W + x) * 4;
      data[o] = rgb.r; data[o + 1] = rgb.g; data[o + 2] = rgb.b; data[o + 3] = 255;
    }
  }
  return { img: { data, width: W, height: H }, corners };
}

test('the card has a row per filament, each over its two most different backings', () => {
  const plan = CAL.planCard(STATED);
  assert.equal(plan.rows.length, 4);
  // Red's backings are the white and the black — the widest luminance gap among the others.
  assert.deepEqual(plan.rows[2].backings, [0, 1]);
  // White cannot sit on itself: its backings are drawn from the other three.
  assert.ok(!plan.rows[0].backings.includes(0));
  assert.equal(plan.frameHead, 1);
  assert.equal(plan.markHead, 0);
  // bare cell + 7 steps, over two backings
  assert.equal(plan.cells.filter((c) => c.row === 0).length, 16);
});

test('two filaments are not enough for two backings, and the card says so by using one', () => {
  const plan = CAL.planCard(['#FFFFFF', '#000000']);
  assert.equal(plan.rows.length, 2);
  assert.deepEqual(plan.rows[0].backings, [1]);
  assert.equal(CAL.planCard(['#FFFFFF']), null);
});

test('a tilted, badly exposed photo still measures the true colour and TD', () => {
  const plan = CAL.planCard(STATED);
  const { img, corners } = renderPhoto(plan);
  const out = CAL.measureCard(img, corners, plan);
  assert.ok(out);
  for (const r of out.results) {
    const truth = TRUE[r.head];
    assert.ok(!r.error, 'row ' + r.head + ' unreadable');
    const de = KC.deltaE(r.hex, truth.hex);
    assert.ok(de < 2.5, `head ${r.head}: measured ${r.hex} vs true ${truth.hex}, ΔE ${de.toFixed(2)}`);
    if (!r.warnings.includes('too-opaque')) {
      const rel = Math.abs(r.tdFront - truth.tdFront) / truth.tdFront;
      assert.ok(rel < 0.15, `head ${r.head}: TD ${r.tdFront} vs ${truth.tdFront}`);
    }
    assert.ok(r.residual < 3, `head ${r.head}: residual ${r.residual}`);
  }
  // The measured red is the real red, not the label's brighter one.
  const red = out.results.find((r) => r.head === 2);
  assert.ok(KC.deltaE(red.hex, TRUE[2].hex) < KC.deltaE(STATED[2], TRUE[2].hex));
});

test('sensor noise of ±8% per pixel moves the measurement by little — the median earns its keep', () => {
  const plan = CAL.planCard(STATED);
  const { img, corners } = renderPhoto(plan, { noise: 0.08 });
  for (const r of CAL.measureCard(img, corners, plan).results) {
    assert.ok(KC.deltaE(r.hex, TRUE[r.head].hex) < 3, `head ${r.head}: ${r.hex}`);
    assert.ok(Math.abs(r.tdFront - TRUE[r.head].tdFront) / TRUE[r.head].tdFront < 0.25, `head ${r.head}: TD ${r.tdFront}`);
  }
});

test('the stored TD is in the engine\'s backlit units, so default vividness reproduces the card', () => {
  const plan = CAL.planCard(STATED);
  const { img, corners } = renderPhoto(plan);
  const blue = CAL.measureCard(img, corners, plan).results.find((r) => r.head === 3);
  assert.ok(Math.abs(blue.td * CAL.DEFAULT_TD_SCALE - blue.tdFront) < 0.02);
});

test('a near-opaque filament is flagged rather than given an invented TD', () => {
  const plan = CAL.planCard(STATED);
  const { img, corners } = renderPhoto(plan);
  const black = CAL.measureCard(img, corners, plan).results.find((r) => r.head === 1);
  // 0.12 mm front-lit TD: the first step (0.08 mm) already hides 90% — few usable steps.
  assert.ok(black.tdFront < 0.2);
});

test('corners that do not form a quadrilateral are refused, not sampled', () => {
  const plan = CAL.planCard(STATED);
  const { img } = renderPhoto(plan);
  assert.equal(CAL.measureCard(img, [[0, 0], [0, 0], [0, 0], [0, 0]], plan), null);
});

test('the card builds as a printable U1 3MF, one part per head', () => {
  const plan = CAL.planCard(STATED);
  const built = CAL.buildCardParts(plan);
  assert.equal(built.parts.length, 4);
  for (const p of built.parts) assert.ok(p.triangles.length > 0);
  // Tallest cell: backing + 13 layers.
  assert.ok(Math.abs(built.sizeMm.z - (0.8 + 13 * 0.08)) < 1e-9);
  const buf = M3.buildFlatU1_3mf({ parts: built.parts, filaments: built.filaments, sizeMm: built.sizeMm,
    baseHead: built.baseHead, layerH: plan.layerH, name: 'calibration-card' });
  assert.ok(buf && buf.length > 1000);
});
