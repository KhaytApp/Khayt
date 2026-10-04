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

test('getStatus finds the listing among the user\'s own, and says so when it is gone', async () => {
  let url;
  await withFetch(async (u) => { url = u; return res(200, { user: { id: 'u', displayName: 'T', trusted: false }, designs: [{ slug: 'desk-hook-a1b2c3', title: 'Desk hook', status: 'pending', verification: { badge: false, fileChecked: true } }] }); }, async () => {
    assert.deepEqual(await P.getStatus('T', 'desk-hook-a1b2c3', { baseUrl: BASE }), { found: true, status: 'pending', verification: { badge: false, fileChecked: true } });
    assert.deepEqual(await P.getStatus('T', 'other-a1b2c3', { baseUrl: BASE }), { found: false, status: null, verification: null });
  });
  assert.equal(url, BASE + '/api/v1/me?limit=100');
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
