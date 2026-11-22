'use strict';

/**
 * lib/makerrun-catalog.js — browsing the public MakerRun catalogue, and the two-step download.
 * Plus the pure vocabularies in lib/makerrun-terms.js, which are copies of the MakerRun repository's
 * lists and are pinned here so a change to them is deliberate.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const cat = require('../lib/makerrun-catalog');
const terms = require('../lib/makerrun-terms');
const lib = require('../lib/makerrun-library');

const BASE = 'https://93.184.216.34'; // literal public IP: the host guard needs no DNS
const res = (status, body, headers = {}) => ({
  status, ok: status >= 200 && status < 300,
  headers: { get: (h) => headers[String(h).toLowerCase()] ?? null },
  json: async () => body, body: null,
  arrayBuffer: async () => (Buffer.isBuffer(body) ? body : Buffer.from('')),
});
function withFetch(stub, fn) {
  const real = global.fetch;
  global.fetch = stub;
  return Promise.resolve().then(fn).finally(() => { global.fetch = real; });
}

const DTO = (over) => Object.assign({
  id: 'u1', slug: 'desk-hook-a1b2c3', title: 'Desk hook', description: 'A hook', creator: null,
  license: 'CC-BY-4.0', category: 'household', subcategory: null, material: 'rigid', colorCount: 1,
  nsfw: false, createdAt: '2026-08-08T00:00:00Z', downloadCount: 3,
  url: 'https://makerrun.com/designs/desk-hook-a1b2c3',
  cover: { url: 'https://abc.supabase.co/storage/v1/object/public/design-images/x.jpg', aiGenerated: false, aiSource: null },
  external: false, listingKind: 'hosted', sourceUrl: null,
  verification: { badge: true, fileChecked: true, printPhotoConfirmed: false, printer: { brand: 'Prusa', model: 'MK4S' } },
  sale: { kind: null, url: null, provider: null, price: null, currency: null, platform: 'external' },
}, over || {});

/* ---- query building ---------------------------------------------------- */

test('buildListQuery: defaults to 24, clamps limit to 100, and drops unknown filters', () => {
  assert.equal(cat.buildListQuery({}), 'limit=24');
  assert.equal(new URLSearchParams(cat.buildListQuery({ limit: 500 })).get('limit'), '100');
  assert.equal(new URLSearchParams(cat.buildListQuery({ limit: -3 })).get('limit'), '24');
  const p = new URLSearchParams(cat.buildListQuery({ category: 'weapons', material: 'resin', offset: -5 }));
  assert.equal(p.has('category'), false);
  assert.equal(p.has('material'), false);
  assert.equal(p.has('offset'), false);
});

test('buildListQuery: q, category, material, verified, forSale true/false and offset', () => {
  const p = new URLSearchParams(cat.buildListQuery({
    q: '  gridfinity bin ', category: 'household', material: 'flexible', verified: true, forSale: false, offset: 48,
  }));
  assert.equal(p.get('q'), 'gridfinity bin');
  assert.equal(p.get('category'), 'household');
  assert.equal(p.get('material'), 'flexible');
  assert.equal(p.get('verified'), 'true');
  assert.equal(p.get('forSale'), 'false');
  assert.equal(p.get('offset'), '48');
  assert.equal(new URLSearchParams(cat.buildListQuery({ forSale: true })).get('forSale'), 'true');
  assert.equal(new URLSearchParams(cat.buildListQuery({ forSale: null })).has('forSale'), false);
  assert.equal(new URLSearchParams(cat.buildListQuery({ verified: 'yes' })).has('verified'), false);
});

/* ---- listDesigns / getDesign ----------------------------------------------- */

test('listDesigns calls GET /api/v1/designs without a token and narrows each design', async () => {
  let seen;
  await withFetch(async (url, init) => {
    seen = { url, init };
    return res(200, { designs: [DTO({ sale: { kind: 'file', url: 'https://buy.stripe.com/x', provider: 'stripe', price: 15, currency: 'SAR', platform: 'external' } })], page: { limit: 24, offset: 0, total: 1, returned: 1 } });
  }, async () => {
    const r = await cat.listDesigns({ q: 'hook' }, { baseUrl: BASE });
    assert.equal(r.page.total, 1);
    const d = r.designs[0];
    assert.equal(d.slug, 'desk-hook-a1b2c3');
    assert.equal(d.commercialUse, true, 'worked out from the licence — the v1 DTO does not carry it');
    assert.equal(d.cover, 'https://abc.supabase.co/storage/v1/object/public/design-images/x.jpg');
    assert.deepEqual(d.sale, { kind: 'file', price: 15, currency: 'SAR', provider: 'stripe' });
    assert.equal(JSON.stringify(d).includes('buy.stripe.com'), false, 'the payment URL never reaches the renderer');
    assert.deepEqual(d.verification.printer, { brand: 'Prusa', model: 'MK4S' });
  });
  assert.equal(seen.url, BASE + '/api/v1/designs?q=hook&limit=24');
  assert.equal(seen.init.headers.authorization, undefined, 'browsing is public');
});

test('listDesigns refuses a renamed field instead of showing an empty catalogue', async () => {
  for (const body of [{ items: [] }, { designs: [] }, { designs: {}, page: { total: 0 } }, [DTO()]]) {
    await withFetch(async () => res(200, body), () =>
      assert.rejects(() => cat.listDesigns({}, { baseUrl: BASE }), (e) => e.code === 'bad_response'));
  }
});

test('listDesigns refuses a row that is not a design rather than dropping it', async () => {
  await withFetch(async () => res(200, { designs: [DTO(), { title: 'no slug' }], page: { total: 2 } }), () =>
    assert.rejects(() => cat.listDesigns({}, { baseUrl: BASE }), (e) => e.code === 'bad_response'));
});

test('an empty page with a real total is an empty page, not an error', async () => {
  await withFetch(async () => res(200, { designs: [], page: { limit: 24, offset: 999, total: 37, returned: 0 } }), async () => {
    const r = await cat.listDesigns({ offset: 999 }, { baseUrl: BASE });
    assert.deepEqual(r.designs, []);
    assert.equal(r.page.total, 37);
  });
});

test('getDesign validates the slug before any request and percent-encodes a non-ASCII one', async () => {
  let calls = 0;
  await withFetch(async () => { calls++; return res(200, {}); }, async () => {
    for (const bad of ['', '../me', 'a/b', 'a.b', 'a b', '%2e%2e', null, 'x'.repeat(201)]) {
      await assert.rejects(() => cat.getDesign(bad, { baseUrl: BASE }), (e) => e.code === 'bad_request');
    }
  });
  assert.equal(calls, 0);

  let url;
  await withFetch(async (u) => {
    url = u;
    return res(200, { design: DTO({ slug: 'حامل-a1b2c3' }), files: [{ filename: 'part.3mf', sizeBytes: 812344, hosted: true }], images: [{ url: 'https://x.supabase.co/i.jpg', kind: 'cover' }, { url: 'javascript:alert(1)' }], profiles: [{ printerBrand: 'Prusa', printerModel: 'MK4S', filamentType: 'PLA', colorCount: 4, badge: true, fileChecked: true, settings: { secret: 1 } }] });
  }, async () => {
    const r = await cat.getDesign('حامل-a1b2c3', { baseUrl: BASE });
    assert.deepEqual(r.files, [{ filename: 'part.3mf', sizeBytes: 812344, hosted: true }]);
    assert.equal(r.images.length, 1, 'a non-https image URL is dropped');
    assert.equal(r.profiles[0].printerModel, 'MK4S');
    assert.equal('settings' in r.profiles[0], false);
  });
  assert.equal(url, BASE + '/api/v1/designs/' + encodeURIComponent('حامل-a1b2c3'));
});

test('getDesign refuses a body without files/images/profiles arrays', async () => {
  await withFetch(async () => res(200, { design: DTO() }), () =>
    assert.rejects(() => cat.getDesign('desk-hook-a1b2c3', { baseUrl: BASE }), (e) => e.code === 'bad_response'));
});

test('a 404 from getDesign is not_found', async () => {
  await withFetch(async () => res(404, { error: { code: 'not_found', message: 'No published design with that slug.' } }), () =>
    assert.rejects(() => cat.getDesign('gone-a1b2c3', { baseUrl: BASE }), (e) => e.code === 'not_found'));
});

/* ---- download ------------------------------------------------------------ */

test('requestDownloadUrl encodes the filename, sends the token, and refuses a bad filename unsent', async () => {
  let seen;
  await withFetch(async (url, init) => { seen = { url, init }; return res(200, { url: BASE + '/signed', expiresInSeconds: 300, filename: 'My part #1.3mf', sizeBytes: 5 }); }, async () => {
    const r = await cat.requestDownloadUrl('TOK', 'desk-hook-a1b2c3', 'My part #1.3mf', { baseUrl: BASE });
    assert.equal(r.url, BASE + '/signed');
  });
  assert.equal(seen.url, BASE + '/api/v1/designs/desk-hook-a1b2c3/files/My%20part%20%231.3mf/download');
  assert.equal(seen.init.headers.authorization, 'Bearer TOK');

  let calls = 0;
  await withFetch(async () => { calls++; return res(200, {}); }, async () => {
    for (const bad of ['../x.3mf', 'a/b.3mf', 'a\\b.3mf', '..', '']) {
      await assert.rejects(() => cat.requestDownloadUrl('T', 'desk-hook-a1b2c3', bad, { baseUrl: BASE }), (e) => e.code === 'bad_request');
    }
  });
  assert.equal(calls, 0);
});

test('requestDownloadUrl refuses a non-https signed URL', async () => {
  await withFetch(async () => res(200, { url: 'http://x/signed' }), () =>
    assert.rejects(() => cat.requestDownloadUrl('T', 'desk-hook-a1b2c3', 'a.3mf', { baseUrl: BASE }), (e) => e.code === 'bad_response'));
});

test('age_required from the download door keeps its code', async () => {
  await withFetch(async () => res(403, { error: { code: 'age_required', message: 'Confirm your age at makerrun.com/age' } }), () =>
    assert.rejects(() => cat.requestDownloadUrl('T', 'nsfw-a1b2c3', 'a.3mf', { baseUrl: BASE }), (e) => e.code === 'age_required'));
});

test('downloadDesignFile: two steps — signed URL, then the guarded fetch — and .stp lands as .step', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mr-cat-'));
  const urls = [];
  await withFetch(async (url) => {
    urls.push(String(url));
    if (String(url).includes('/api/v1/')) return res(200, { url: BASE + '/signed/bracket.stp', filename: 'bracket.stp', sizeBytes: 4 });
    return res(200, Buffer.from('STEP'));
  }, async () => {
    const out = await cat.downloadDesignFile('TOK', { slug: 'bracket-a1b2c3', filename: 'bracket.stp', title: 'Bracket' }, dir, { baseUrl: BASE });
    assert.equal(path.basename(out), 'Bracket.step');
    assert.equal(fs.readFileSync(out, 'utf8'), 'STEP');
  });
  assert.equal(urls.length, 2);
  assert.ok(urls[0].endsWith('/files/bracket.stp/download'));
  assert.equal(urls[1], BASE + '/signed/bracket.stp');
});

test('downloadDesignFile refuses a signed URL that redirects to a private address', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mr-cat-'));
  let fetchedInternal = false;
  await withFetch(async (url) => {
    const u = String(url);
    if (u.includes('/api/v1/')) return res(200, { url: BASE + '/signed/a.3mf', filename: 'a.3mf' });
    if (u.includes('169.254.169.254')) { fetchedInternal = true; return res(200, Buffer.from('secret')); }
    return { status: 302, ok: false, headers: { get: (h) => (String(h).toLowerCase() === 'location' ? 'https://169.254.169.254/latest/meta-data' : null) } };
  }, async () => {
    await assert.rejects(
      () => cat.downloadDesignFile('TOK', { slug: 'a-a1b2c3', filename: 'a.3mf', title: 'A' }, dir, { baseUrl: BASE }),
      /private|internal/);
  });
  assert.equal(fetchedInternal, false);
  assert.deepEqual(fs.readdirSync(dir), []);
});

test('extFor: .stp is STEP, written as .step — not the .3mf default', () => {
  assert.equal(lib.extFor({ filename: 'bracket.stp' }), '.step');
  assert.equal(lib.extFor({ filename: 'BRACKET.STP' }), '.step');
  assert.equal(lib.extFor({ fileType: 'stp' }), '.step');
  assert.equal(lib.extFor({ fileType: 'other', filename: 'x.stp' }), '.step');
});

/* ---- vocabularies ---------------------------------------------------------- */

test('the 14 MakerRun categories, in MakerRun order', () => {
  assert.deepEqual(terms.CATEGORY_VALUES, ['art', 'toys-games', 'gadgets', 'household', 'tools', 'miniatures',
    'fashion', 'hobby-diy', 'sports-outdoors', 'education', 'printer', 'models', 'seasonal', 'other']);
  assert.ok(terms.CATEGORIES.every((c) => typeof c.label === 'string' && c.label));
  assert.equal(cat.CATEGORIES, terms.CATEGORIES);
});

test('the licences MakerRun\'s own upload form offers', () => {
  assert.deepEqual(terms.LICENCES, ['CC-BY-4.0', 'CC-BY-SA-4.0', 'CC-BY-NC-4.0', 'CC-BY-NC-SA-4.0', 'CC0-1.0',
    'Standard Digital File (MakerWorld)', 'All rights reserved']);
});

test('toRecordLicence reads Creative Commons with certainty and leaves the rest unrecorded', () => {
  assert.equal(terms.toRecordLicence('CC-BY-4.0'), 'cc-by');
  assert.equal(terms.toRecordLicence('CC-BY'), 'cc-by');
  assert.equal(terms.toRecordLicence('cc-by-nc-sa-4.0'), 'cc-by-nc-sa');
  assert.equal(terms.toRecordLicence('CC-BY-NC-ND-3.0'), 'cc-by-nc-nd');
  assert.equal(terms.toRecordLicence('CC0-1.0'), 'cc0');
  assert.equal(terms.toRecordLicence('All rights reserved'), null);
  assert.equal(terms.toRecordLicence('Standard Digital File (MakerWorld)'), null);
  assert.equal(terms.toRecordLicence('CC-BY-XX-4.0'), null);
  assert.equal(terms.toRecordLicence(''), null);
  // Every id it produces is one the print-file edit modal offers.
  const ids = require('../lib/model-licence').list().map((l) => l.id);
  for (const l of terms.LICENCES) { const r = terms.toRecordLicence(l); if (r) assert.ok(ids.includes(r), r); }
});

test('toMakerRunLicence maps what MakerRun offers and refuses to guess the rest', () => {
  assert.equal(terms.toMakerRunLicence('cc0'), 'CC0-1.0');
  assert.equal(terms.toMakerRunLicence('cc-by'), 'CC-BY-4.0');
  assert.equal(terms.toMakerRunLicence('cc-by-sa'), 'CC-BY-SA-4.0');
  assert.equal(terms.toMakerRunLicence('cc-by-nc'), 'CC-BY-NC-4.0');
  assert.equal(terms.toMakerRunLicence('cc-by-nc-sa'), 'CC-BY-NC-SA-4.0');
  for (const id of ['own', 'commercial', 'cc-by-nd', 'cc-by-nc-nd', '', null, 'cc-by-4.0']) {
    assert.equal(terms.toMakerRunLicence(id), null, String(id));
  }
  // Round trip for every mapped one.
  for (const id of ['cc0', 'cc-by', 'cc-by-sa', 'cc-by-nc', 'cc-by-nc-sa']) {
    assert.equal(terms.toRecordLicence(terms.toMakerRunLicence(id)), id);
    assert.ok(terms.LICENCES.includes(terms.toMakerRunLicence(id)));
  }
});

test('commercialUse mirrors MakerRun\'s three answers', () => {
  assert.equal(terms.commercialUse('CC0-1.0'), true);
  assert.equal(terms.commercialUse('CC-BY-SA-4.0'), true);
  assert.equal(terms.commercialUse('CC-BY-NC-4.0'), false);
  assert.equal(terms.commercialUse('CC-BY-NC-2.0'), false);
  assert.equal(terms.commercialUse('CC-BY-3.0'), true);
  assert.equal(terms.commercialUse('All rights reserved'), false);
  assert.equal(terms.commercialUse('Standard Digital File (MakerWorld)'), null);
  assert.equal(terms.commercialUse(null), null);
});
