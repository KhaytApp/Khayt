'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const lib = require('../lib/makerrun-library');

// Literal public IP as the initial host so the SSRF guard passes without a DNS lookup (offline-safe).
const PUBLIC = 'https://93.184.216.34/f.3mf';
function withFetch(stub, fn) {
  const real = global.fetch;
  global.fetch = stub;
  return Promise.resolve().then(fn).finally(() => { global.fetch = real; });
}
// A minimal Response-ish object for a 200 with a small buffered body (no streaming branch).
const okBody = (bytes) => ({ ok: true, status: 200, headers: { get: () => null }, body: null, arrayBuffer: async () => bytes });

test('safeBase sanitizes and caps titles', () => {
  assert.equal(lib.safeBase('Hello World!'), 'Hello_World'); // trailing separator stripped
  assert.equal(lib.safeBase('a/b/c'), 'a_b_c'); // path separators never survive
  assert.ok(!lib.safeBase('../../etc/passwd').includes('/'));
  assert.equal(lib.safeBase(''), 'design');
  assert.equal(lib.safeBase(null), 'design');
  assert.ok(lib.safeBase('x'.repeat(200)).length <= 60);
});

test('extFor prefers declared fileType, then filename, then .3mf', () => {
  assert.equal(lib.extFor({ fileType: '3mf' }), '.3mf');
  assert.equal(lib.extFor({ fileType: 'STL' }), '.stl');
  assert.equal(lib.extFor({ filename: 'model.obj' }), '.obj');
  assert.equal(lib.extFor({ fileType: 'weird', filename: 'a.step' }), '.step');
  assert.equal(lib.extFor({}), '.3mf');
});

test('extFor never returns a non-model extension from a hostile filename', () => {
  // A renderer-supplied filename must not be able to land e.g. a .command/.bat in ~/Downloads.
  assert.equal(lib.extFor({ filename: 'payload.command' }), '.3mf');
  assert.equal(lib.extFor({ filename: 'x.bat' }), '.3mf');
  assert.equal(lib.extFor({ fileType: 'exe', filename: 'run.sh' }), '.3mf');
  assert.equal(lib.extFor({ filename: 'model.STL' }), '.stl'); // allowlisted, case-insensitive
});

test('downloadItem returns null when the item has no downloadUrl (no network)', async () => {
  assert.equal(await lib.downloadItem({ title: 'x' }, '/tmp/nope'), null);
  assert.equal(await lib.downloadItem(null, '/tmp/nope'), null);
});

test('downloadAll skips file-less items without hitting the network', async () => {
  const items = [
    { title: 'A' }, // no downloadUrl → skipped
    { slug: 'b', downloadUrl: null }, // explicit null → skipped
  ];
  const r = await lib.downloadAll(items, '/tmp/should-not-be-created');
  assert.deepEqual(r.saved, []);
  assert.deepEqual(r.failed, []);
  assert.equal(r.skipped.length, 2);
});

test('downloadItem refuses a non-HTTPS download URL (SSRF guard, no network)', async () => {
  await assert.rejects(
    () => lib.downloadItem({ title: 'x', downloadUrl: 'http://makerrun.com/f.3mf' }, '/tmp/nope'),
    /HTTPS/);
});

test('downloadItem refuses a URL resolving to a loopback/private address (SSRF guard, no network)', async () => {
  await assert.rejects(
    () => lib.downloadItem({ title: 'x', downloadUrl: 'https://127.0.0.1/f.3mf' }, '/tmp/nope'),
    /private|internal/);
});

test('downloadItem re-validates a redirect hop and refuses one pointing at a private address (SSRF)', async () => {
  let calls = 0, fetchedInternal = false;
  await withFetch(async (url) => {
    calls++;
    if (String(url).includes('127.0.0.1')) { fetchedInternal = true; return okBody(Buffer.from('x')); }
    // First hop (the public host) 302s to loopback — the classic redirect-based SSRF bypass.
    return { status: 302, ok: false, headers: { get: (h) => (String(h).toLowerCase() === 'location' ? 'https://127.0.0.1/secret' : null) } };
  }, async () => {
    await assert.rejects(
      () => lib.downloadItem({ title: 'x', downloadUrl: PUBLIC }, path.join(os.tmpdir(), 'nope')),
      /private|internal/);
  });
  assert.equal(fetchedInternal, false, 'the internal redirect target must never be fetched');
  assert.equal(calls, 1, 'only the initial public host is fetched; the loopback hop is rejected pre-fetch');
});

test('downloadAll gives same-named designs distinct files instead of clobbering', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'brl-dedup-'));
  try {
    await withFetch(async () => okBody(Buffer.from('data')), async () => {
      const items = [
        { title: 'Vase', downloadUrl: PUBLIC, fileType: '3mf' },
        { title: 'Vase', downloadUrl: PUBLIC, fileType: '3mf' }, // same title → would collide
        { title: 'Vase!', downloadUrl: PUBLIC, fileType: '3mf' }, // safeBase collapses "Vase!" → "Vase" too
      ];
      const r = await lib.downloadAll(items, dir);
      assert.equal(r.saved.length, 3, 'every design is saved');
      assert.equal(new Set(r.saved).size, 3, 'each to a unique path — no silent overwrite');
      for (const p of r.saved) assert.ok(fs.existsSync(p), 'file actually exists on disk');
      assert.equal(fs.readdirSync(dir).length, 3, 'three real files, not one clobbered');
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('fetchCoverDataUrl returns a data: URI for an image response', async () => {
  await withFetch(async () => ({
    ok: true, status: 200,
    headers: { get: (h) => { h = String(h).toLowerCase(); return h === 'content-type' ? 'image/png' : (h === 'content-length' ? '3' : null); } },
    body: null, arrayBuffer: async () => Buffer.from([1, 2, 3]),
  }), async () => {
    const d = await lib.fetchCoverDataUrl(PUBLIC);
    assert.match(d, /^data:image\/png;base64,/);
  });
});

test('fetchCoverDataUrl rejects a non-image, and a redirect to a private address (SSRF)', async () => {
  await withFetch(async () => ({ ok: true, status: 200, headers: { get: (h) => (String(h).toLowerCase() === 'content-type' ? 'text/html' : null) }, body: null, arrayBuffer: async () => Buffer.from('x') }),
    async () => { await assert.rejects(() => lib.fetchCoverDataUrl(PUBLIC), /not an image/); });
  await withFetch(async (url) => {
    if (String(url).includes('127.0.0.1')) return { ok: true, status: 200, headers: { get: () => null }, body: null, arrayBuffer: async () => Buffer.from('x') };
    return { status: 302, ok: false, headers: { get: (h) => (String(h).toLowerCase() === 'location' ? 'https://127.0.0.1/c.png' : null) } };
  }, async () => { await assert.rejects(() => lib.fetchCoverDataUrl(PUBLIC), /private|internal/); });
});

test('fetchLibrary rejects an empty token before any request', async () => {
  await assert.rejects(() => lib.fetchLibrary(''), /Sign in to MakerRun/);
  await assert.rejects(() => lib.fetchLibrary('   '), /Sign in to MakerRun/);
});

test('signInUrl points at the MakerRun app-link page', () => {
  assert.equal(lib.signInUrl(), 'https://makerrun.com/app-link');
});

test('downloadsDir keeps a pre-rename BedReady-Library folder, else uses the new name', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'brl-dl-'));
  try {
    // Nothing downloaded before the rename → the new name.
    assert.equal(lib.downloadsDir(root), path.join(root, 'MakerRun-Library'));

    // A shop that downloaded designs before the rename keeps writing where its
    // existing designs already are, rather than scattering one library over two
    // folders with no hint that the older half exists.
    fs.mkdirSync(path.join(root, lib.LEGACY_LIBRARY_FOLDER));
    assert.equal(lib.downloadsDir(root), path.join(root, 'BedReady-Library'));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('downloadsDir falls back to the new name when Downloads cannot be read', () => {
  // An unreadable Downloads must not throw out of an IPC handler — it just means
  // "no legacy folder that we can see", and the new name is the safe answer.
  const real = fs.existsSync;
  fs.existsSync = () => { throw new Error('EACCES'); };
  try {
    assert.equal(lib.downloadsDir('/some/downloads'), path.join('/some/downloads', 'MakerRun-Library'));
  } finally { fs.existsSync = real; }
});

test('the library listing is fetched from makerrun.com, not the old host', async () => {
  // fetchLibrary takes an injectable base for tests, so the production path — no opts —
  // is the one that has to be pinned. bedready.io still answers /api/*, so a regression
  // here fails no test AND keeps working in production until the alias goes away.
  let seen = null;
  await withFetch(async (url, opts) => {
    seen = { url: String(url), auth: opts && opts.headers && opts.headers.authorization };
    return { ok: true, status: 200, headers: { get: () => null }, json: async () => ({ items: [] }) };
  }, async () => {
    await lib.fetchLibrary('TOKEN');
  });
  assert.equal(seen.url, 'https://makerrun.com/api/library');
  assert.equal(new URL(seen.url).host, 'makerrun.com', 'never bedready.io, which is the converter now');
  assert.equal(seen.auth, 'Bearer TOKEN', 'and the user token rides the same request');
});

test('the shared host is https and has no trailing slash', () => {
  // Every URL here is built by concatenation ('.../api' + '/library'), so a trailing
  // slash silently yields //api/library and https is what the SSRF guard assumes.
  const { BASE } = require('../lib/makerrun');
  assert.equal(BASE, 'https://makerrun.com');
  assert.ok(!BASE.endsWith('/'), 'no trailing slash — paths are concatenated onto it');
  assert.equal(new URL(BASE).protocol, 'https:');
});

/*
 * ── An unreadable answer is not an empty library ───────────────────────────
 *
 * `fetchLibrary` used to end
 *
 *     return data && Array.isArray(data.items) ? data.items : [];
 *
 * so every 200 whose shape it did not recognise became zero designs and no
 * error. A shop with forty saved designs opens the library, sees nothing, and is
 * told nothing — indistinguishable from a shop that has saved none.
 *
 * That is the carrier-webhook defect (#777) on a different integration:
 * answering "received, handled" to something you could not read hides a broken
 * integration completely. It is also a two-repo contract with nothing comparing
 * the halves — makerrun.com owns the response shape, this file owns the reader —
 * which is the Medusa field list again.
 */

/** A JSON response with a chosen status and body; `undefined` body = unparseable. */
const jsonRes = (body, status = 200) => ({
  status,
  ok: status < 400,
  headers: { get: () => null },
  json: async () => { if (body === undefined) throw new Error('bad json'); return body; },
});

test('a library with designs comes back', () => withFetch(
  async () => jsonRes({ items: [{ slug: 'a' }, { slug: 'b' }] }),
  async () => {
    // The ENVELOPE, not a bare array: `filtered` and `syncedAt` are load-bearing.
    const res = await lib.fetchLibrary('tok', { baseUrl: 'https://x' });
    assert.strictEqual(res.items.length, 2);
    assert.strictEqual(res.count, 2);
    assert.strictEqual(res.filtered, false);
  }));

test('a genuinely empty library is still empty, not an error', () => withFetch(
  async () => jsonRes({ items: [] }),
  async () => {
    const res = await lib.fetchLibrary('tok', { baseUrl: 'https://x' });
    assert.deepStrictEqual(res.items, []);
    // `filtered: false` is what makes this "you have saved nothing" rather than
    // "nothing changed". The two are the same `count: 0` and mean opposite things.
    assert.strictEqual(res.filtered, false);
  }));

test('a renamed field is refused, not flattened to empty', () => withFetch(
  // The realistic server change: `items` becomes `designs`. Before this, the
  // shop's whole library silently vanished.
  async () => jsonRes({ designs: [{ slug: 'a' }] }),
  async () => {
    await assert.rejects(
      () => lib.fetchLibrary('tok', { baseUrl: 'https://x' }),
      /not with a library Khayt recognises/);
  }));

test('a body that is not JSON at all is refused', () => withFetch(
  async () => jsonRes(undefined),
  async () => {
    await assert.rejects(
      () => lib.fetchLibrary('tok', { baseUrl: 'https://x' }),
      /not with a library Khayt recognises/);
  }));

test('a bare array is accepted — it cannot be mistaken for anything else', () => withFetch(
  // Tolerated deliberately although the server does not send it today. Accepting
  // an unambiguous shape can never produce a WRONG answer, only avoid a false
  // failure; that is the line between tolerance and the guessing #777 removed.
  async () => jsonRes([{ slug: 'a' }]),
  async () => {
    const res = await lib.fetchLibrary('tok', { baseUrl: 'https://x' });
    assert.strictEqual(res.items.length, 1);
    // A bare array carries neither field, and says so rather than inventing them.
    assert.strictEqual(res.filtered, false);
    assert.strictEqual(res.syncedAt, null);
  }));

test('an ordinary failing status says what it means, not what number it was', () => {
  // Same rule as lib/updater.js's explainUpdateError: `HTTP 502` names a number a
  // print shop cannot act on, and none of these is a fault of theirs.
  assert.match(lib.explainLibraryStatus(500), /having trouble right now/i);
  assert.match(lib.explainLibraryStatus(502), /having trouble right now/i);
  // 503 is deliberately NOT folded in with the rest. A planned window is caught
  // earlier, on error.code; a 503 reaching here is `unavailable` — a
  // misconfigured server that retrying will not fix — so it keeps its number and
  // says it needs reporting. See test/makerrun-maintenance.test.js, which caught
  // a first draft that told the shop to wait for something that would not clear.
  assert.match(lib.explainLibraryStatus(503), /HTTP 503/);
  assert.doesNotMatch(lib.explainLibraryStatus(503), /nothing is wrong/i);
  assert.match(lib.explainLibraryStatus(429), /slow down/i);
  assert.match(lib.explainLibraryStatus(403), /sign in again/i);
  assert.match(lib.explainLibraryStatus(404), /needs an update/i);
  // Unrecognised keeps its number: a reassuring sentence over an unclassified
  // fault hides a real one.
  assert.match(lib.explainLibraryStatus(418), /HTTP 418/);
});

test('a 401 still says the session expired, before anything else is read', () => withFetch(
  async () => jsonRes({ error: 'auth' }, 401),
  async () => {
    await assert.rejects(
      () => lib.fetchLibrary('tok', { baseUrl: 'https://x' }),
      /session expired/i);
  }));
