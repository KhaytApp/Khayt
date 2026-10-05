'use strict';

/**
 * lib/makerrun-publish.js — create a listing, upload the model, upload a picture.
 *
 * The rule most worth pinning: everything MakerRun would refuse that we can know in advance is refused
 * HERE, with no request made. And the multipart bodies use the exact field names, filenames and Blob
 * types the server reads (makerrun/src/app/api/v1/designs/[slug]/{files,images}/route.ts).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/makerrun-publish');

const BASE = 'https://93.184.216.34';
const res = (status, body) => ({ status, ok: status >= 200 && status < 300, headers: { get: () => null }, json: async () => body });
function withFetch(stub, fn) {
  const real = global.fetch;
  global.fetch = stub;
  return Promise.resolve().then(fn).finally(() => { global.fetch = real; });
}
/** A fetch that fails the test if it is ever called. */
const noNetwork = async () => { throw new Error('preflight should have refused before any request'); };

const GOOD = { title: 'Desk hook', description: 'Holds a headset.', category: 'household', material: 'rigid', license: 'CC-BY-4.0', nsfw: false };
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]);

/* ---- create ---------------------------------------------------------------- */

test('validateCreateInput builds exactly the whitelisted body — no sale fields, no status', () => {
  const { errors, body } = P.validateCreateInput({ ...GOOD, saleUrl: 'https://buy.stripe.com/x', salePrice: 5, status: 'published', title: '  Desk hook  ' });
  assert.deepEqual(errors, []);
  assert.deepEqual(body, { title: 'Desk hook', description: 'Holds a headset.', category: 'household', material: 'rigid', license: 'CC-BY-4.0', nsfw: false });
});

test('validateCreateInput refuses each bad field by name', () => {
  const fields = (input) => P.validateCreateInput(input).errors.map((e) => e.field).sort();
  assert.deepEqual(fields({ ...GOOD, title: '' }), ['title']);
  assert.deepEqual(fields({ ...GOOD, title: 'x'.repeat(121) }), ['title']);
  assert.deepEqual(fields({ ...GOOD, description: 'x'.repeat(20001) }), ['description']);
  assert.deepEqual(fields({ ...GOOD, category: 'weapons' }), ['category']);
  assert.deepEqual(fields({ ...GOOD, material: 'resin' }), ['material']);
  assert.deepEqual(fields({ ...GOOD, license: 'GPL-3.0' }), ['license']);
  assert.deepEqual(fields({ ...GOOD, material: null }), []);
  assert.equal(P.validateCreateInput({ ...GOOD, nsfw: 'yes' }).body.nsfw, false, 'only a real true marks 18+');
});

test('createDesign refuses invalid input with no request', async () => {
  await withFetch(noNetwork, () =>
    assert.rejects(() => P.createDesign('T', { ...GOOD, license: '' }, { baseUrl: BASE }),
      (e) => e.code === 'invalid' && e.details[0].field === 'license'));
});

test('createDesign POSTs JSON and returns the slug', async () => {
  let seen;
  await withFetch(async (url, init) => { seen = { url, init }; return res(201, { design: { slug: 'desk-hook-a1b2c3', url: 'https://makerrun.com/designs/desk-hook-a1b2c3' }, status: 'pending' }); }, async () => {
    const r = await P.createDesign('TOK', GOOD, { baseUrl: BASE });
    assert.deepEqual(r, { slug: 'desk-hook-a1b2c3', status: 'pending', url: 'https://makerrun.com/designs/desk-hook-a1b2c3' });
  });
  assert.equal(seen.url, BASE + '/api/v1/designs');
  assert.equal(seen.init.method, 'POST');
  assert.equal(seen.init.headers.authorization, 'Bearer TOK');
  assert.deepEqual(JSON.parse(seen.init.body), GOOD);
});

test('createDesign: a 422 from the server keeps its details for the form', async () => {
  await withFetch(async () => res(422, { error: { code: 'invalid', message: 'Some fields were rejected.', details: [{ field: 'title', message: 'title is required.' }] } }), () =>
    assert.rejects(() => P.createDesign('T', GOOD, { baseUrl: BASE }), (e) => e.code === 'invalid' && e.details[0].field === 'title'));
});

/* ---- model upload ------------------------------------------------------------ */

test('uploadModel preflight: extension and the 100 MB cap are refused with no request', async () => {
  await withFetch(noNetwork, async () => {
    for (const name of ['model.gcode', 'model.zip', 'model', 'model.3mf.exe']) {
      await assert.rejects(() => P.uploadModel('T', 'desk-hook-a1b2c3', { filename: name, bytes: Buffer.from('x') }, { baseUrl: BASE }),
        (e) => e.code === 'invalid' && e.details[0].field === 'file', name);
    }
    await assert.rejects(() => P.uploadModel('T', 'desk-hook-a1b2c3', { filename: 'empty.stl', bytes: Buffer.alloc(0) }, { baseUrl: BASE }), (e) => e.code === 'invalid');
    await assert.rejects(() => P.uploadModel('T', '../me', { filename: 'a.stl', bytes: Buffer.from('x') }, { baseUrl: BASE }), (e) => e.code === 'bad_request');
  });
  assert.match(P.checkModel('big.3mf', 100 * 1024 * 1024 + 1).message, /100 MB/);
  assert.equal(P.checkModel('ok.3mf', 100 * 1024 * 1024), null);
  for (const ext of ['.3mf', '.stl', '.obj', '.step', '.stp', '.STL']) assert.equal(P.checkModel('a' + ext, 10), null, ext);
});

test('uploadModel sends one `file` part with a storage-safe filename and returns verification', async () => {
  let seen;
  await withFetch(async (url, init) => {
    seen = { url, init };
    return res(201, { file: { filename: 'My_hook__v2_.3mf', sizeBytes: 3, url: 'https://x' }, verification: { verified: false, printer: null, brand: null, reason: 'no slicer profile in the file' }, status: 'pending' });
  }, async () => {
    const r = await P.uploadModel('TOK', 'desk-hook-a1b2c3', { filename: 'My hook (v2).3mf', bytes: Buffer.from('abc') }, { baseUrl: BASE });
    assert.equal(r.verification.verified, false);
    assert.match(r.verification.reason, /no slicer profile/);
    assert.equal(r.status, 'pending');
  });
  assert.equal(seen.url, BASE + '/api/v1/designs/desk-hook-a1b2c3/files');
  const form = seen.init.body;
  assert.ok(form instanceof FormData);
  const parts = [...form.entries()];
  assert.equal(parts.length, 1);
  assert.equal(parts[0][0], 'file');
  assert.equal(parts[0][1].name, 'My_hook__v2_.3mf');
  assert.equal(parts[0][1].size, 3);
  assert.equal(Object.keys(seen.init.headers).some((h) => h.toLowerCase() === 'content-type'), false);
});

test('uploadModel: a 409 conflict (external listing) keeps its code', async () => {
  await withFetch(async () => res(409, { error: { code: 'conflict', message: 'That listing links to a file hosted elsewhere' } }), () =>
    assert.rejects(() => P.uploadModel('T', 'desk-hook-a1b2c3', { filename: 'a.stl', bytes: Buffer.from('x') }, { baseUrl: BASE }), (e) => e.code === 'conflict'));
});

/* ---- images ---------------------------------------------------------------- */

const img = (n, type = 'image/png', bytes = PNG) => ({ filename: 'shot' + n + '.png', bytes, type });

test('uploadImages preflight: count, type, size and kind are refused with no request', async () => {
  await withFetch(noNetwork, async () => {
    await assert.rejects(() => P.uploadImages('T', 'a-b', [], {}, { baseUrl: BASE }), (e) => e.code === 'invalid');
    await assert.rejects(() => P.uploadImages('T', 'a-b', Array.from({ length: 9 }, (_, i) => img(i)), {}, { baseUrl: BASE }),
      (e) => e.code === 'invalid' && /8/.test(e.message));
    await assert.rejects(() => P.uploadImages('T', 'a-b', [img(1, 'image/gif')], {}, { baseUrl: BASE }), (e) => e.code === 'invalid');
    await assert.rejects(() => P.uploadImages('T', 'a-b', [img(1, 'image/png', Buffer.alloc(15 * 1024 * 1024 + 1))], {}, { baseUrl: BASE }), (e) => e.code === 'invalid');
    await assert.rejects(() => P.uploadImages('T', 'a-b', [img(1)], { kind: 'cover' }, { baseUrl: BASE }), (e) => e.code === 'invalid' && e.details[0].field === 'kind');
  });
});

test('uploadImages: up to 8 `images` parts with real Blob types, plus `kind`', async () => {
  let seen;
  await withFetch(async (url, init) => { seen = { url, init }; return res(201, { images: [{ url: 'https://x/1' }], coverSet: 'https://x/1', failures: [] }); }, async () => {
    const list = Array.from({ length: 8 }, (_, i) => img(i, i % 2 ? 'image/jpeg' : 'image/webp'));
    const r = await P.uploadImages('TOK', 'desk-hook-a1b2c3', list, { kind: 'print' }, { baseUrl: BASE });
    assert.equal(r.coverSet, 'https://x/1');
  });
  assert.equal(seen.url, BASE + '/api/v1/designs/desk-hook-a1b2c3/images');
  const form = seen.init.body;
  const images = form.getAll('images');
  assert.equal(images.length, 8);
  assert.deepEqual(images.map((b) => b.type), ['image/webp', 'image/jpeg', 'image/webp', 'image/jpeg', 'image/webp', 'image/jpeg', 'image/webp', 'image/jpeg']);
  assert.equal(images[0].name, 'shot0.png');
  assert.equal(form.get('kind'), 'print');
});

test('uploadImages defaults to kind=gallery', async () => {
  let form;
  await withFetch(async (url, init) => { form = init.body; return res(201, { images: [], failures: [] }); }, () =>
    P.uploadImages('T', 'desk-hook-a1b2c3', [img(1)], undefined, { baseUrl: BASE }));
  assert.equal(form.get('kind'), 'gallery');
});

test('uploadImages: every image refused (422, no envelope) is invalid with the reasons', async () => {
  await withFetch(async () => res(422, { images: [], coverSet: null, failures: [{ field: 'images', message: 'shot1.png: 4000×3000 exceeds the 2048px longest edge.' }] }), () =>
    assert.rejects(() => P.uploadImages('T', 'desk-hook-a1b2c3', [img(1)], {}, { baseUrl: BASE }),
      (e) => e.code === 'invalid' && /2048px/.test(e.details[0].message)));
});

/* ---- status / delete ----------------------------------------------------------- */

const mine = (n, from = 0, over = {}) => Array.from({ length: n }, (_, i) => Object.assign({ slug: 'd-' + (from + i) + '-a1b2c3', title: 'D' + (from + i), status: 'published', createdAt: '2026-01-01T00:00:00Z' }, over));

test('getStatus finds the listing among the user\'s own, and says so when it is gone', async () => {
  const urls = [];
  await withFetch(async (u) => { urls.push(u); return res(200, { user: { id: 'u', displayName: 'T', trusted: false }, designs: [{ slug: 'desk-hook-a1b2c3', title: 'Desk hook', status: 'pending', verification: { badge: false, fileChecked: true } }] }); }, async () => {
    assert.deepEqual(await P.getStatus('T', 'desk-hook-a1b2c3', { baseUrl: BASE }), { found: true, status: 'pending', verification: { badge: false, fileChecked: true }, complete: true });
    const gone = await P.getStatus('T', 'other-a1b2c3', { baseUrl: BASE });
    assert.equal(gone.found, false);
    assert.equal(gone.complete, true, 'a short page means every listing was read');
  });
  assert.equal(urls[0], BASE + '/api/v1/me?limit=100');
});

test('getStatus pages through /me with offset until a short page', async () => {
  const urls = [];
  await withFetch(async (u) => {
    urls.push(u);
    const off = Number(new URL(u).searchParams.get('offset') || 0);
    return res(200, { user: { id: 'u' }, designs: off === 0 ? mine(100) : mine(30, 100) });
  }, async () => {
    const r = await P.getStatus('T', 'd-120-a1b2c3', { baseUrl: BASE });
    assert.equal(r.found, true);
  });
  assert.deepEqual(urls, [BASE + '/api/v1/me?limit=100', BASE + '/api/v1/me?limit=100&offset=100']);
});

test('getStatus that runs out of pages says "not in the latest N", not "gone"', async () => {
  await withFetch(async (u) => {
    const off = Number(new URL(u).searchParams.get('offset') || 0);
    return res(200, { user: { id: 'u' }, designs: mine(100, off) });
  }, async () => {
    const r = await P.getStatus('T', 'old-a1b2c3', { baseUrl: BASE }, { maxPages: 2 });
    assert.equal(r.found, false);
    assert.equal(r.complete, false);
    assert.equal(r.searched, 200);
  });
});

test('findRecentListing adopts only a pending listing with the same title from the window', async () => {
  const now = Date.parse('2026-10-04T12:00:00Z');
  const since = now - 15 * 60 * 1000;
  const designs = [
    { slug: 'desk-hook-new111', title: 'Desk hook', status: 'published', createdAt: '2026-10-04T11:59:00Z' },
    { slug: 'other-222222', title: 'Other', status: 'pending', createdAt: '2026-10-04T11:58:00Z' },
    { slug: 'desk-hook-abc333', title: 'Desk hook', status: 'pending', createdAt: '2026-10-04T11:55:00Z' },
    { slug: 'desk-hook-old444', title: 'Desk hook', status: 'pending', createdAt: '2026-10-04T10:00:00Z' },
  ];
  let calls = 0;
  await withFetch(async () => { calls++; return res(200, { user: { id: 'u' }, designs }); }, async () => {
    assert.deepEqual(await P.findRecentListing('T', ' Desk hook ', since, { baseUrl: BASE }), { slug: 'desk-hook-abc333', status: 'pending', createdAt: '2026-10-04T11:55:00Z' });
    assert.equal(await P.findRecentListing('T', 'Lamp', since, { baseUrl: BASE }), null);
    assert.equal(await P.findRecentListing('T', 'Desk hook', now, { baseUrl: BASE }), null, 'too old');
  });
  assert.equal(calls, 3, 'one page each — new listings sort first');
});

test('uploadTimeoutFor grows with size and is capped at 30 minutes', () => {
  const V1 = require('../lib/makerrun-v1');
  assert.equal(V1.uploadTimeoutFor(0), 120000);
  assert.equal(V1.uploadTimeoutFor(100 * 1024 * 1024), 120000 + 400000, '100 MB at 256 KiB/s');
  assert.equal(V1.uploadTimeoutFor(10 * 1024 * 1024 * 1024), 30 * 60 * 1000);
});

test('uploadModel and uploadImages pass a size-scaled timeout to the transport', async () => {
  const V1 = require('../lib/makerrun-v1');
  const real = V1.request;
  const seen = [];
  V1.request = async (method, p, opts) => { seen.push(opts.timeoutMs); return p.endsWith('/files') ? { verification: {}, status: 'pending' } : { images: [], failures: [] }; };
  try {
    await P.uploadModel('T', 'desk-hook-a1b2c3', { filename: 'a.3mf', bytes: Buffer.alloc(50 * 1024 * 1024) });
    await P.uploadImages('T', 'desk-hook-a1b2c3', [img(1, 'image/png', Buffer.alloc(2 * 1024 * 1024))], {});
  } finally { V1.request = real; }
  assert.deepEqual(seen, [V1.uploadTimeoutFor(50 * 1024 * 1024), V1.uploadTimeoutFor(2 * 1024 * 1024)]);
});

test('resolveVaultFile: plain files only, never a symlink, never outside the folder', async () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'mr-vault-'));
  const dir = path.join(base, 'PF-1');
  fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir, 'part.3mf'), 'model');
  fs.writeFileSync(path.join(base, 'secret.txt'), 'nope');
  fs.symlinkSync(path.join(base, 'secret.txt'), path.join(dir, 'link.3mf'));
  fs.symlinkSync(path.join(dir, 'part.3mf'), path.join(dir, 'inner.3mf'));
  fs.mkdirSync(path.join(dir, 'sub.3mf'));
  assert.deepEqual(P.resolveVaultFile(dir, 'part.3mf'), { full: path.join(dir, 'part.3mf'), size: 5 });
  for (const bad of ['link.3mf', 'inner.3mf', 'sub.3mf', '../secret.txt', 'x/part.3mf', 'missing.3mf', '..', '', null]) {
    assert.equal(P.resolveVaultFile(dir, bad), null, String(bad));
  }
  assert.equal((await P.readVaultFile(path.join(dir, 'part.3mf'))).toString(), 'model');
  // A symlink swapped in after resolving is still refused at open time.
  await assert.rejects(() => P.readVaultFile(path.join(dir, 'link.3mf')));
});

test('getMe refuses an unrecognised body', async () => {
  await withFetch(async () => res(200, { profile: {} }), () =>
    assert.rejects(() => P.getMe('T', { baseUrl: BASE }), (e) => e.code === 'bad_response'));
});

test('deleteDesign sends DELETE for a validated slug only', async () => {
  let seen;
  await withFetch(async (url, init) => { seen = { url, init }; return res(200, { deleted: true, slug: 'desk-hook-a1b2c3' }); }, async () => {
    assert.deepEqual(await P.deleteDesign('T', 'desk-hook-a1b2c3', { baseUrl: BASE }), { deleted: true });
  });
  assert.equal(seen.init.method, 'DELETE');
  assert.equal(seen.url, BASE + '/api/v1/designs/desk-hook-a1b2c3');
  await withFetch(noNetwork, () => assert.rejects(() => P.deleteDesign('T', 'a/../b', { baseUrl: BASE }), (e) => e.code === 'bad_request'));
});

test('sniffImageType names JPEG, PNG and WebP from the bytes and nothing else', () => {
  assert.equal(P.sniffImageType(Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(12)])), 'image/jpeg');
  assert.equal(P.sniffImageType(PNG), 'image/png');
  assert.equal(P.sniffImageType(Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WEBP'), Buffer.alloc(4)])), 'image/webp');
  assert.equal(P.sniffImageType(Buffer.from('GIF89a......')), null);
  assert.equal(P.sniffImageType(Buffer.alloc(3)), null);
});
