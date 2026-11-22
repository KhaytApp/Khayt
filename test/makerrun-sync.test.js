'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const lib = require('../lib/makerrun-library');
const State = require('../lib/makerrun-sync-state');

/**
 * Khayt re-downloaded a shop's whole MakerRun library on every sync, because the
 * payload gave it nothing to compare against. It now carries a per-file checksum
 * and a cursor. These pin the two things that are easy to get wrong about using
 * them: what the cursor may be trusted to prove, and what counts as "I already
 * have this".
 */

const dir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'mr-sync-'));
const md5 = (b) => crypto.createHash('md5').update(b).digest('hex');

const item = (over = {}) => ({
  designId: 'd1', slug: 'thing', title: 'Thing', filename: 'Thing.3mf', fileType: '3mf',
  checksum: 'abc', checksumAlgo: 'md5', fileUpdatedAt: '2026-06-30T00:00:00Z',
  downloadUrl: 'https://example.test/f.3mf', ...over,
});

// ── The cursor ──────────────────────────────────────────────────────────────

test('with no cursor yet, one full fetch and the cursor is kept', async () => {
  const calls = [];
  const fake = async (_t, o) => { calls.push(o.since || null); return { items: [item()], count: 1, filtered: false, syncedAt: 'T1' }; };
  const r = await lib.syncLibrary('tok', { state: State.EMPTY, fetchLibrary: fake });
  assert.deepStrictEqual(calls, [null]);
  assert.strictEqual(r.syncedAt, 'T1');
  assert.strictEqual(r.unchanged, false);
});

test('"nothing changed" is answered from cache, with no second request', async () => {
  // The one answer `?since=` gives that is safe to act on alone. This is the
  // common case, and it costs one small response and NO signed URLs.
  const calls = [];
  const fake = async (_t, o) => { calls.push(o.since || null); return { items: [], count: 0, filtered: true, syncedAt: 'T2' }; };
  const cached = { syncedAt: 'T1', items: [item(), item({ designId: 'd2' })], files: {} };
  const r = await lib.syncLibrary('tok', { state: cached, fetchLibrary: fake });
  assert.deepStrictEqual(calls, ['T1']);
  assert.strictEqual(r.unchanged, true);
  assert.strictEqual(r.items.length, 2, 'the cached listing is served');
  assert.strictEqual(r.syncedAt, 'T1', 'the older cursor is kept — it can only widen the next question');
  assert.strictEqual(r.fetched, 1);
});

test('anything OTHER than "nothing changed" triggers a full fetch', async () => {
  /* `?since=` cannot report an UNSAVE: removing a design changes no row it would
     return. So its results are never merged into the cache — a positive answer
     only means "go ask properly", and the full list reflects removals because it
     is the whole list. This is the test that would fail if someone made the
     delta authoritative, which is the tempting optimisation. */
  const calls = [];
  const fake = async (_t, o) => {
    calls.push(o.since || null);
    return o.since
      ? { items: [item({ designId: 'd9' })], count: 1, filtered: true, syncedAt: 'T2' }
      : { items: [item()], count: 1, filtered: false, syncedAt: 'T3' };
  };
  const cached = { syncedAt: 'T1', items: [item(), item({ designId: 'gone' })], files: {} };
  const r = await lib.syncLibrary('tok', { state: cached, fetchLibrary: fake });
  assert.deepStrictEqual(calls, ['T1', null], 'the probe, then an authoritative full fetch');
  assert.strictEqual(r.fetched, 'full');
  assert.strictEqual(r.items.length, 1, 'the full list replaces the cache, so an unsaved design disappears');
  assert.strictEqual(r.syncedAt, 'T3');
});

// ── What counts as already holding a file ───────────────────────────────────

test('a matching checksum on a file that still exists is a skip', () => {
  const d = dir();
  const f = path.join(d, 'Thing.3mf');
  fs.writeFileSync(f, 'bytes');
  const st = State.remember(State.EMPTY, item(), f);
  assert.strictEqual(State.alreadyHave(st, item()), f);
});

test('a manifest entry whose file was deleted is not a skip', () => {
  // Believing it would leave the shop with a library entry and no file, which
  // looks like it worked.
  const st = State.remember(State.EMPTY, item(), '/nowhere/gone.3mf');
  assert.strictEqual(State.alreadyHave(st, item()), null);
});

test('a missing checksum is never a match', () => {
  // The API returns null for a gated design deliberately, and elsewhere null
  // means "could not be determined". Treating absence as agreement is how a
  // stale file survives for ever.
  const d = dir(); const f = path.join(d, 'a.3mf'); fs.writeFileSync(f, 'x');
  const st = State.remember(State.EMPTY, item(), f);
  assert.strictEqual(State.alreadyHave(st, item({ checksum: null })), null);
  const noneStored = State.remember(State.EMPTY, item({ checksum: null }), f);
  assert.strictEqual(State.alreadyHave(noneStored, item()), null);
});

test('the same digest under a different algorithm is not the same claim', () => {
  const d = dir(); const f = path.join(d, 'a.3mf'); fs.writeFileSync(f, 'x');
  const st = State.remember(State.EMPTY, item(), f);
  assert.strictEqual(State.alreadyHave(st, item({ checksumAlgo: 'sha256' })), null);
});

test('moved bytes are not a skip, even at the same checksum', () => {
  const d = dir(); const f = path.join(d, 'a.3mf'); fs.writeFileSync(f, 'x');
  const st = State.remember(State.EMPTY, item(), f);
  assert.strictEqual(State.alreadyHave(st, item({ fileUpdatedAt: '2026-08-01T00:00:00Z' })), null);
});

test('a retitled design is still the same file', () => {
  // Keyed on designId, not the slug or the path: a retitle moves both and moves
  // no bytes. Keying on either would re-download every rename.
  const d = dir(); const f = path.join(d, 'a.3mf'); fs.writeFileSync(f, 'x');
  const st = State.remember(State.EMPTY, item(), f);
  assert.strictEqual(State.alreadyHave(st, item({ slug: 'renamed', title: 'Renamed' })), f);
});

// ── Verification ────────────────────────────────────────────────────────────

test('the checksum algorithm is read, not assumed', () => {
  const body = Buffer.from('hello');
  assert.strictEqual(lib.verifyChecksum(body, { checksum: md5(body), checksumAlgo: 'md5' }), true);
  assert.strictEqual(lib.verifyChecksum(body, { checksum: 'nope', checksumAlgo: 'md5' }), false);
  const sha = crypto.createHash('sha256').update(body).digest('hex');
  assert.strictEqual(lib.verifyChecksum(body, { checksum: sha, checksumAlgo: 'sha256' }), true,
    'a move to sha256 must not fail every download');
});

test('nothing to verify against is null — not false', () => {
  // null means unverified and the file is kept. Returning false would refuse a
  // gated design's file, or every file on a Node build without the algorithm,
  // which breaks the feature to protect against nothing.
  const body = Buffer.from('hello');
  assert.strictEqual(lib.verifyChecksum(body, { checksum: null, checksumAlgo: 'md5' }), null);
  assert.strictEqual(lib.verifyChecksum(body, { checksum: 'abc', checksumAlgo: null }), null);
  assert.strictEqual(lib.verifyChecksum(body, { checksum: 'abc', checksumAlgo: 'not-a-hash' }), null);
});

// ── State file ──────────────────────────────────────────────────────────────

test('a corrupt state file costs a full sync, never an error', () => {
  const d = dir();
  fs.writeFileSync(State.fileFor(d), '{ not json');
  assert.deepStrictEqual(State.read(d), State.EMPTY);
});

test('a state file from an older shape is discarded, not migrated', () => {
  const d = dir();
  fs.writeFileSync(State.fileFor(d), JSON.stringify({ version: 0, syncedAt: 'T1', items: [1, 2] }));
  assert.strictEqual(State.read(d).syncedAt, null);
});

test('what is written is what comes back', () => {
  const d = dir();
  State.write(d, { syncedAt: 'T1', items: [item()], files: { d1: { path: '/a' } } });
  const back = State.read(d);
  assert.strictEqual(back.syncedAt, 'T1');
  assert.strictEqual(back.items.length, 1);
  assert.strictEqual(back.files.d1.path, '/a');
});

// ── The licence and the designer's numbers, as the card reads them ──────────
//
// These live in the renderer, which is not loadable here, so the FUNCTIONS are
// pulled out of the source and evaluated with the small surface they use. That
// is weaker than driving the real UI and it is not nothing: the branch that
// matters is a three-state one where the middle state is a non-answer, and the
// expensive mistake is collapsing it into a boolean.

const vm = require('node:vm');

function cardHelpers() {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'bedready-library.js'), 'utf8');
  const grab = (name) => {
    const i = src.indexOf(`  function ${name}(`);
    assert.ok(i > 0, `${name} not found — this guard has rotted`);
    const end = src.indexOf('\n  }\n', i);
    return src.slice(i, end + 4);
  };
  const ctx = {
    t: (k) => k,
    esc: (v) => String(v),
    assert,
  };
  vm.createContext(ctx);
  vm.runInContext(`${grab('printFacts')}\n${grab('licenceLine')}`, ctx);
  return ctx;
}

test('a licence that cannot be read says so, rather than guessing either way', () => {
  const { licenceLine } = cardHelpers();
  // null is a job for the shop, not a verdict. Guessing false blocks a print they
  // may sell; guessing true tells them to sell one they may not.
  assert.match(licenceLine({ commercialUse: null, license: 'Custom terms' }), /brl\.lic_check/);
  assert.match(licenceLine({ commercialUse: true, license: 'CC0-1.0' }), /brl\.lic_commercial/);
  assert.match(licenceLine({ commercialUse: false, license: 'CC-BY-NC-4.0' }), /brl\.lic_noncommercial/);
  // The licence's own name stays reachable, so the shop can read the actual terms.
  assert.match(licenceLine({ commercialUse: null, license: 'Custom terms' }), /title="Custom terms"/);
});

test('an API that has not sent commercialUse renders nothing at all', () => {
  // Absent is not the same as null. An older server, or a payload shape change,
  // must not make every design read as "check the licence".
  const { licenceLine } = cardHelpers();
  assert.strictEqual(licenceLine({ license: 'CC0-1.0' }), '');
  assert.strictEqual(licenceLine(null), '');
});

test('a missing print number is a silence, never a zero', () => {
  const { printFacts } = cardHelpers();
  // A shop quoting from this would read 0 mm as a number rather than as nothing
  // having been said.
  assert.strictEqual(printFacts({ print: { layerHeightMm: 0, colorCount: 0, filamentTypes: [] } }), '');
  assert.strictEqual(printFacts({ print: null }), '');
  assert.strictEqual(printFacts({}), '');
  const full = printFacts({ print: { layerHeightMm: 0.12, filamentTypes: ['PLA'], colorCount: 2, fromVerifiedProfile: true } });
  assert.match(full, /0\.12 mm/);
  assert.match(full, /PLA/);
  assert.match(full, /2 conv\.colours/);
});

test('numbers a designer typed are marked apart from numbers read off a file', () => {
  // fromVerifiedProfile is the difference between a measurement and a claim, and
  // a shop pricing a job should be able to tell which it is looking at.
  const { printFacts } = cardHelpers();
  const measured = printFacts({ print: { layerHeightMm: 0.2, fromVerifiedProfile: true } });
  const stated = printFacts({ print: { layerHeightMm: 0.2, fromVerifiedProfile: false } });
  assert.match(measured, /brl\.print_from_file/);
  assert.match(stated, /brl\.print_from_designer/);
  assert.ok(!/\*/.test(measured), 'a measured figure carries no caveat mark');
  assert.match(stated, /\*/, 'a stated figure is marked, not silently equal to a measured one');
});

// ── Paging, and what absence is allowed to mean ─────────────────────────────
//
// The endpoint capped at 200 and said nothing about it until 2026-08-28. A shop
// with 250 saved designs received 200 and had no way to know — harmless while
// nobody mirrored the list, and data loss the moment somebody did, because the
// 50 never received look exactly like 50 that were removed.

/** A fake endpoint over a fixed library, honouring since/offset like the real one. */
function server(library, opts = {}) {
  const calls = [];
  const page = opts.pageSize || 200;
  const fn = async (_t, o = {}) => {
    calls.push({ since: o.since || null, offset: o.offset || 0 });
    const src = o.since ? (opts.changed || []) : library;
    const slice = src.slice(o.offset || 0, (o.offset || 0) + page);
    return {
      items: slice,
      count: slice.length,
      filtered: !!o.since,
      syncedAt: opts.syncedAt || 'T2',
      total: src.length,
      offset: o.offset || 0,
      truncated: (o.offset || 0) + slice.length < src.length,
      removed: o.since ? (opts.removed || []) : null,
      removalsCompleteSince: 'removalsCompleteSince' in opts ? opts.removalsCompleteSince : '2026-01-01T00:00:00Z',
    };
  };
  fn.calls = calls;
  return fn;
}

const many = (n) => Array.from({ length: n }, (_, i) => item({ designId: 'd' + i, slug: 's' + i }));

test('a library larger than one page is fetched whole', async () => {
  const fake = server(many(250), { pageSize: 200 });
  const r = await lib.syncLibrary('tok', { state: State.EMPTY, fetchLibrary: fake });
  assert.strictEqual(r.items.length, 250, 'a shop with 250 designs must see 250');
  assert.strictEqual(r.complete, true);
  assert.deepStrictEqual(fake.calls.map((c) => c.offset), [0, 200]);
});

test('a sync that could not reach the end is reported incomplete', async () => {
  // So the caller does not store it — the pages never fetched would read as
  // removals on the next comparison.
  const endless = async () => ({
    items: [item()], count: 1, filtered: false, syncedAt: 'T2',
    total: 99999, offset: 0, truncated: true, removed: null, removalsCompleteSince: null,
  });
  const r = await lib.syncLibrary('tok', { state: State.EMPTY, fetchLibrary: endless });
  assert.strictEqual(r.complete, false, 'a server that never stops truncating must not look complete');
  assert.ok(r.items.length <= lib.MAX_PAGES, 'paging is bounded');
});

// ── Removals ────────────────────────────────────────────────────────────────

test('a delta that reports removals costs one request, not two', async () => {
  // The whole point of `removed`: a design that left is absent from a delta, and
  // so is one that did not change. Same absence, two meanings — until now.
  const cached = { syncedAt: '2026-06-01T00:00:00Z', items: many(3), files: {} };
  const fake = server(many(3), { changed: [item({ designId: 'd0', title: 'Renamed' })], removed: ['d1'] });
  const r = await lib.syncLibrary('tok', { state: cached, fetchLibrary: fake });
  assert.strictEqual(fake.calls.length, 1, 'the delta was authoritative, so no second request');
  assert.strictEqual(r.items.length, 2, 'd1 left');
  assert.ok(!r.items.some((i) => i.designId === 'd1'));
  assert.strictEqual(r.items.find((i) => i.designId === 'd0').title, 'Renamed', 'the changed item replaced its cached copy');
});

test('a cursor older than the tombstone window falls back to a full sync', async () => {
  // Tombstones are pruned at 180 days, so `removed` cannot be complete for a
  // cursor older than the boundary the server states. Believing a short list
  // would be the same lie as the absence it replaces.
  const cached = { syncedAt: '2025-01-01T00:00:00Z', items: many(3), files: {} };
  const fake = server(many(2), {
    changed: [item({ designId: 'd0' })], removed: [],
    removalsCompleteSince: '2026-03-01T00:00:00Z',
  });
  const r = await lib.syncLibrary('tok', { state: cached, fetchLibrary: fake });
  assert.strictEqual(fake.calls.length, 2, 'probe, then an authoritative full sync');
  assert.strictEqual(r.items.length, 2);
});

test('a truncated delta is never authoritative for deletion', async () => {
  // `removed` is computed per REQUEST, not per query, and the pages not fetched
  // are absent for the same reason a removed design is.
  const cached = { syncedAt: '2026-06-01T00:00:00Z', items: many(300), files: {} };
  const fake = server(many(300), { pageSize: 200, changed: many(250), removed: ['d1'] });
  const r = await lib.syncLibrary('tok', { state: cached, fetchLibrary: fake });
  assert.ok(fake.calls.length > 1, 'a truncated delta forces the full path');
  assert.strictEqual(r.items.length, 300, 'nothing was deleted on the strength of a partial answer');
});

test('a server that sends no removalsCompleteSince gets no delta trust', () => {
  // Absent is not "no boundary, trust everything". An older deployment that has
  // not got the field must not have its deltas treated as complete.
  const cached = { syncedAt: '2026-06-01T00:00:00Z', items: many(3), files: {} };
  const fake = server(many(2), { changed: [item()], removed: ['d1'], removalsCompleteSince: null });
  return lib.syncLibrary('tok', { state: cached, fetchLibrary: fake }).then((r) => {
    assert.strictEqual(fake.calls.length, 2, 'no boundary stated means no delta applied');
    assert.strictEqual(r.items.length, 2);
  });
});
