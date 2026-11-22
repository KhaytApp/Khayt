#!/usr/bin/env node
/**
 * What one shop costs Khayt Cloud per month, and how many fit on a plan.
 *
 * KHAYT-3.0-CLOUD-INFRA-SPEC §10 gives a cost envelope for a Node + Postgres +
 * Redis stack. Production does not run that — it is PHP 8.3 + MySQL on shared
 * hosting — so that envelope cannot price anything. This model replaces it with
 * measured numbers.
 *
 * Every constant below was MEASURED through the shipped code path, not estimated.
 * Re-measure any of them with scripts/measure-push-cost.mjs against a real store.
 *
 *     collection      count     bytes   bytes/record
 *     printLog           19     29591           1557
 *     printFiles         11      7261            660
 *     inventory           3       332            111
 *     settings (fixed)          4926
 *
 * Two properties of the sync protocol turn those into the real cost:
 *
 *   1. It is BLOB-FIRST. push() (lib/cloud-backend.js:50) encrypts and sends the
 *      WHOLE store every time, so bandwidth is store size × how often the shop
 *      saves — not the size of what changed. A shop that edits often pays for its
 *      whole history on every edit, so cost per shop grows QUADRATICALLY with age.
 *   2. Since v3.6.0-beta.18 the store is GZIPPED before encryption
 *      (lib/sync-crypto.js:73, COMPRESS_ON_WRITE = true). Measured on a real
 *      store, one push: 44,305 B plaintext → 59,175 B on the wire uncompressed,
 *      → 9,590 B compressed. That is 6.17× like-for-like.
 *
 * The distinction this model exists to make, and the one the docs originally got
 * wrong: COMPRESSION IS A UNIFORM MULTIPLIER. It divides the hobbyist and the
 * farm by the same 6.17×, so it lowers the bill but leaves the ~12,000× SPREAD
 * between them exactly where it was. Only entity-level deltas change the shape,
 * because only they break the coupling between store SIZE and push COST.
 *
 * Shared hosting is a flat fee with capped resources, so "cost per shop" is not
 * a bill — it is the plan price divided by how many shops fit before the
 * binding resource runs out. That is the number this prints.
 *
 * Usage:
 *   node scripts/cloud-cost-model.mjs
 *   node scripts/cloud-cost-model.mjs --plan-price 25 --bandwidth-gb 500 --storage-gb 100
 *   node scripts/cloud-cost-model.mjs --ceiling-gb 25      # test a fair-use ceiling
 */

// ── measured constants ──────────────────────────────────────────────────────
const BYTES = {
  settingsFixed: 4926,
  perOrder: 1557,
  perPrintFile: 660,
  perInventoryItem: 111,
  perClient: 200,      // not in the sampled store; conservative, small either way
};

/**
 * Wire bytes per plaintext byte, measured end to end on a real push — the JSON
 * body of PUT /v1/shops/{id}/store, base64 ciphertext and all.
 *   off: 59175/44305   on: 9590/44305
 */
const WIRE_UNCOMPRESSED = 1.336;
const WIRE_COMPRESSED = 0.216;
/** What compression actually bought, like for like. */
const GZIP_SAVING = WIRE_UNCOMPRESSED / WIRE_COMPRESSED;   // 6.17×

/**
 * What ONE changed record costs on the wire if push were entity-level, measured
 * the same way: a single printLog record, gzipped, encrypted, base64, in the
 * request body = 1,134 B. It is dominated by the crypto/base64 envelope rather
 * than by the record, which is the whole point — it does not grow with the store.
 */
const DELTA_WIRE_BYTES = 1134;

// ── shop profiles ───────────────────────────────────────────────────────────
// `savesPerDay` is the one number here that is judgement rather than measurement,
// and it is also the one the answer is most sensitive to — hence --saves and the
// sensitivity table at the end. A save is any change that survives the 2.5s
// debounce in renderer/cloud-sync.js: adding an order, moving a kanban card,
// receiving stock, editing a quote.
const PROFILES = [
  { name: 'Hobbyist',   ordersPerMonth: 5,   savesPerDay: 5,   years: 2, files: 20,  inventory: 10 },
  { name: 'Side shop',  ordersPerMonth: 40,  savesPerDay: 30,  years: 2, files: 150, inventory: 30 },
  { name: 'Busy shop',  ordersPerMonth: 250, savesPerDay: 150, years: 2, files: 600, inventory: 80 },
  { name: 'Small farm', ordersPerMonth: 800, savesPerDay: 400, years: 2, files: 2000, inventory: 200 },
];

const arg = (flag, dflt) => {
  const i = process.argv.indexOf(flag);
  return i > -1 && process.argv[i + 1] ? Number(process.argv[i + 1]) : dflt;
};

// Plan shape. Defaults are placeholders, NOT a quote — pass the real ones.
const PLAN = {
  price: arg('--plan-price', 25),
  bandwidthGb: arg('--bandwidth-gb', 500),
  storageGb: arg('--storage-gb', 100),
  currency: 'USD',
};
/** Fair-use bandwidth ceiling per shop per month, in GB. */
const CEILING_GB = arg('--ceiling-gb', 25);

const fmtBytes = (b) => b >= 1e9 ? (b / 1e9).toFixed(2) + ' GB'
  : b >= 1e6 ? (b / 1e6).toFixed(1) + ' MB'
  : (b / 1e3).toFixed(0) + ' KB';

function modelShop(p) {
  const orders = p.ordersPerMonth * 12 * p.years;
  const storeBytes = BYTES.settingsFixed
    + orders * BYTES.perOrder
    + p.files * BYTES.perPrintFile
    + p.inventory * BYTES.perInventoryItem
    + Math.round(orders * 0.3) * BYTES.perClient;
  const pushes = p.savesPerDay * 30;
  // Today: every save pushes the whole store, gzipped.
  const perPush = storeBytes * WIRE_COMPRESSED;
  const monthlyBandwidth = perPush * pushes;
  // Was: the same thing before beta.18, kept to show what compression bought.
  const monthlyUncompressed = storeBytes * WIRE_UNCOMPRESSED * pushes;
  // Would be: entity-level push — cost tracks ACTIVITY, not store size.
  const monthlyDelta = DELTA_WIRE_BYTES * pushes;
  return { ...p, orders, storeBytes, perPush, pushes,
    monthlyBandwidth, monthlyUncompressed, monthlyDelta };
}

console.log('Khayt Cloud — measured cost model');
console.log('Plan assumed: ' + PLAN.price + ' ' + PLAN.currency + '/mo · '
  + PLAN.bandwidthGb + ' GB bandwidth · ' + PLAN.storageGb + ' GB storage');
console.log('Compression:  ON since v3.6.0-beta.18 — measured ' + GZIP_SAVING.toFixed(2) + '× like-for-like\n');

const rows = PROFILES.map(modelShop);
console.log(
  'profile'.padEnd(12), 'orders'.padStart(7), 'store'.padStart(9),
  'per push'.padStart(9), 'was (no gzip)'.padStart(14), 'bw/month NOW'.padStart(13),
  'if deltas'.padStart(10),
);
for (const r of rows) {
  console.log(
    r.name.padEnd(12), String(r.orders).padStart(7), fmtBytes(r.storeBytes).padStart(9),
    fmtBytes(r.perPush).padStart(9), fmtBytes(r.monthlyUncompressed).padStart(14),
    fmtBytes(r.monthlyBandwidth).padStart(13), fmtBytes(r.monthlyDelta).padStart(10),
  );
}

// ── the finding the docs got wrong ──────────────────────────────────────────
const lightest = rows[0], heaviest = rows[rows.length - 1];
const spread = (a, b, key) => (b[key] / a[key]);
console.log('\nSpread between the lightest and heaviest shop — who pay the SAME subscription:\n');
console.log('  before compression :', Math.round(spread(lightest, heaviest, 'monthlyUncompressed')).toLocaleString() + '×');
console.log('  after compression  :', Math.round(spread(lightest, heaviest, 'monthlyBandwidth')).toLocaleString() + '×',
  ' <-- UNCHANGED. gzip is a uniform multiplier.');
console.log('  with entity deltas :', Math.round(spread(lightest, heaviest, 'monthlyDelta')).toLocaleString() + '×',
  '      <-- collapses to the ratio of ACTIVITY (saves/day), which is all it should ever have been.');

console.log('\nHow many shops fit on one plan, and what that makes a shop cost:\n');
console.log('profile'.padEnd(12), 'by bandwidth'.padStart(13), 'by storage'.padStart(11),
  'binding'.padStart(10), 'cost/shop'.padStart(10), 'if deltas'.padStart(10));
for (const r of rows) {
  const byBw = Math.floor((PLAN.bandwidthGb * 1e9) / r.monthlyBandwidth);
  const bySt = Math.floor((PLAN.storageGb * 1e9) / r.storeBytes);
  const fits = Math.max(1, Math.min(byBw, bySt));
  const binding = byBw <= bySt ? 'bandwidth' : 'storage';
  const byBwD = Math.floor((PLAN.bandwidthGb * 1e9) / r.monthlyDelta);
  const fitsD = Math.max(1, Math.min(byBwD, bySt));
  console.log(
    r.name.padEnd(12), String(byBw).padStart(13), String(bySt).padStart(11),
    binding.padStart(10), (PLAN.price / fits).toFixed(2).padStart(10),
    (PLAN.price / fitsD).toFixed(2).padStart(10),
  );
}

// ── what a fair-use ceiling has to be set to, and who it touches ────────────
console.log(`\nA fair-use bandwidth ceiling of ${CEILING_GB} GB/shop/month — who it actually touches:\n`);
console.log('profile'.padEnd(12), 'bw/month'.padStart(10), 'vs ceiling'.padStart(11), 'verdict'.padStart(24));
for (const r of rows) {
  const pct = r.monthlyBandwidth / (CEILING_GB * 1e9);
  const verdict = pct <= 0.5 ? 'clear'
    : pct <= 1 ? 'under, but in sight'
    : 'OVER — needs deltas';
  console.log(r.name.padEnd(12), fmtBytes(r.monthlyBandwidth).padStart(10),
    (pct * 100).toFixed(0).padStart(10) + '%', verdict.padStart(24));
}
const worstUnderCeiling = Math.floor((PLAN.bandwidthGb * 1e9) / (CEILING_GB * 1e9));
console.log(`\n  Worst case with the ceiling enforced: ${worstUnderCeiling} shops per plan,`);
console.log(`  i.e. a floor price of ${(PLAN.price / worstUnderCeiling).toFixed(2)} ${PLAN.currency}/shop if EVERY shop pinned the ceiling.`);
console.log('  Nobody does — the ceiling exists to cap the tail, not to describe the median.');

// ── compaction: how long a delta chain may grow before a full push ─────────
//
// A chain has to be reset by a full push eventually, or a cold device pays for
// the base PLUS every delta ever appended. Let R be the ratio at which we
// compact: chain bytes ≤ R × base bytes.
//
// Per cycle a shop sends N = R × base / DELTA deltas, then one base. So:
//
//   push bytes/month = saves × DELTA + (saves × DELTA / R)
//                    = saves × DELTA × (1 + 1/R)
//
// The store size CANCELS. That is the useful result: the push cost of a policy
// is a fixed multiple of the ideal delta cost, the same multiple for a hobbyist
// and a farm, and R alone picks it. What R trades against is the COLD pull,
// which is bounded by base × (1 + R).
console.log('\nCompaction — chain bytes ≤ R × base bytes, then one full push:\n');
console.log('R'.padStart(4), 'push vs ideal'.padStart(14), 'cold pull vs blob'.padStart(18),
  'deltas/cycle (busy)'.padStart(20), 'busy shop/mo'.padStart(13));
const busyForCompaction = rows.find((r) => r.name === 'Busy shop');
for (const R of [0.5, 1, 2, 4, 10]) {
  const pushMult = 1 + 1 / R;
  const perCycle = Math.round((R * busyForCompaction.perPush) / DELTA_WIRE_BYTES);
  console.log(
    String(R).padStart(4),
    (pushMult.toFixed(2) + '×').padStart(14),
    ((1 + R).toFixed(1) + '×').padStart(18),
    String(perCycle).padStart(20),
    fmtBytes(busyForCompaction.monthlyDelta * pushMult).padStart(13),
  );
}
console.log('\n  Warm pulls only stay cheap if GET carries `?since=<rev>` — without it every');
console.log('  launch re-downloads the base and the whole chain, and a chain makes pulls');
console.log('  WORSE than blob-only. That is a contract requirement, not an optimisation.');
console.log('  Fold cost is the other bound: every delta in a cold pull is one decrypt,');
console.log('  so a count cap belongs alongside the ratio.');

console.log('\nSensitivity — the model turns on saves/day, so vary only that (Busy shop):\n');
const busy = PROFILES.find((p) => p.name === 'Busy shop');
console.log('saves/day'.padStart(9), 'bw/month'.padStart(10), 'shops/plan'.padStart(11), 'cost/shop'.padStart(10));
for (const saves of [25, 50, 100, 150, 300, 600]) {
  const r = modelShop({ ...busy, savesPerDay: saves });
  const fits = Math.max(1, Math.floor((PLAN.bandwidthGb * 1e9) / r.monthlyBandwidth));
  console.log(String(saves).padStart(9), fmtBytes(r.monthlyBandwidth).padStart(10),
    String(fits).padStart(11), (PLAN.price / fits).toFixed(2).padStart(10));
}

const busyRow = rows.find((r) => r.name === 'Busy shop');
console.log('\nWhere the remaining win is:\n');
console.log('  gzip before encrypting : SHIPPED in v3.6.0-beta.18 —',
  fmtBytes(busyRow.monthlyUncompressed), '→', fmtBytes(busyRow.monthlyBandwidth),
  `(${GZIP_SAVING.toFixed(1)}× less)`);
console.log('  entity deltas on push  : NOT SHIPPED —',
  fmtBytes(busyRow.monthlyBandwidth), '→', fmtBytes(busyRow.monthlyDelta),
  `(${Math.round(busyRow.monthlyBandwidth / busyRow.monthlyDelta)}× less, and it stops`);
console.log('                           scaling with store SIZE at all: a shop pays for what');
console.log('                           changed, not for its whole history, so the bill stops');
console.log('                           growing as the shop gets older.');
console.log('\nNumbers are per shop per month. Plan figures are inputs: pass --plan-price,');
console.log('--bandwidth-gb and --storage-gb from the real Hostinger plan to get real answers.');
