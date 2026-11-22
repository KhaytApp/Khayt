#!/usr/bin/env node
/**
 * Measure what a sync push actually costs on the wire — through the shipped code
 * path, not a model of it.
 *
 * The constants in scripts/cloud-cost-model.mjs come from here. Re-run this
 * against a real store whenever the store shape or the crypto changes, and copy
 * the numbers across rather than adjusting them by hand: every previous attempt
 * to reason about compression from memory got the ratio wrong in one direction
 * or another, because there are three plausible ratios and only one of them is
 * the one that matters.
 *
 *   plaintext → wire uncompressed   is the base64/JSON envelope  (~1.34×)
 *   plaintext → wire compressed     is what a push costs today   (~0.22×)
 *   wire uncompressed → compressed  is what gzip BOUGHT          (~6.2×)
 *
 * The third is the only honest way to state "compression saved N×", because it
 * compares like with like. Quoting the first two against each other mixes
 * plaintext with wire bytes and overstates the win.
 *
 * Usage:
 *   node scripts/measure-push-cost.mjs
 *   node scripts/measure-push-cost.mjs /path/to/khayt-store.json
 */
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const require = createRequire(import.meta.url);
const sync = require('../lib/sync-crypto.js');

/** Where Electron puts userData for each platform (app name: "khayt"). */
function defaultStorePath() {
  const home = os.homedir();
  if (process.platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'khayt', 'khayt-store.json');
  if (process.platform === 'win32') return path.join(process.env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'khayt', 'khayt-store.json');
  return path.join(process.env.XDG_CONFIG_HOME || path.join(home, '.config'), 'khayt', 'khayt-store.json');
}

const storePath = process.argv[2] || defaultStorePath();
if (!fs.existsSync(storePath)) {
  console.error(`No store at ${storePath}`);
  console.error('Pass one explicitly: node scripts/measure-push-cost.mjs /path/to/khayt-store.json');
  process.exit(1);
}

const store = JSON.parse(fs.readFileSync(storePath, 'utf8'));
const dek = crypto.randomBytes(32);
const plaintext = Buffer.byteLength(JSON.stringify(store), 'utf8');

/** Exactly the body lib/cloud-backend.js:57 PUTs to /v1/shops/{id}/store. */
const push = (obj, compress) =>
  Buffer.byteLength(JSON.stringify({ ciphertext: sync.encryptStore(obj, dek, { compress }), baseRev: 1 }), 'utf8');

const wireOff = push(store, false);
const wireOn = push(store, true);

console.log(`store: ${storePath}\n`);
console.log('=== one full push ===');
console.log('plaintext JSON      :', plaintext.toLocaleString(), 'B');
console.log('wire, compress OFF  :', wireOff.toLocaleString(), 'B', `(${(wireOff / plaintext).toFixed(3)}× plaintext)`);
console.log('wire, compress ON   :', wireOn.toLocaleString(), 'B', `(${(wireOn / plaintext).toFixed(3)}× plaintext)`);
console.log('gzip bought         :', (wireOff / wireOn).toFixed(2) + '×', '← like-for-like, the only honest form');

console.log('\n=== collections, largest first ===');
console.log('collection'.padEnd(22), 'count'.padStart(6), 'bytes'.padStart(8), 'per rec'.padStart(8));
const rows = Object.entries(store).map(([k, v]) => {
  const bytes = Buffer.byteLength(JSON.stringify(v), 'utf8');
  const n = Array.isArray(v) ? v.length : null;
  return { k, n, bytes, per: n ? Math.round(bytes / n) : null };
}).sort((a, b) => b.bytes - a.bytes);
for (const r of rows.slice(0, 12)) {
  console.log(String(r.k).padEnd(22), String(r.n ?? '—').padStart(6),
    String(r.bytes).padStart(8), (r.per != null ? String(r.per) : '—').padStart(8));
}

// What an entity-level push would cost: one changed record, same pipeline.
// This is the number that decides whether a flat per-shop price is safe, because
// it does not grow with the store — the envelope dominates it.
const biggest = rows.find((r) => r.n && r.n > 0 && Array.isArray(store[r.k]));
if (biggest) {
  const arr = store[biggest.k];
  const one = { [biggest.k]: [arr[arr.length - 1]] };
  const dOn = push(one, true);
  console.log(`\n=== one changed record (${biggest.k}), if push were entity-level ===`);
  console.log('wire, compress ON   :', dOn.toLocaleString(), 'B',
    '← envelope-dominated, so it does NOT grow with the store');
  console.log('whole-store push    :', wireOn.toLocaleString(), 'B',
    `(${(wireOn / dOn).toFixed(0)}× more, and that multiple grows every month the shop operates)`);
}
