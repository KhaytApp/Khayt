/**
 * Driving the Bed Ready MakerRun panel (renderer/bedready-makerrun.js) in a real DOM.
 *
 * lib/makerrun-*.js prove the requests are right. This proves what only goes wrong once there IS a
 * document: a search is debounced into one request, a filter resets paging, the download button names
 * the licence and creates a record carrying where it came from, error codes become the right next step,
 * and a publish that fails half-way can be finished — or removed — without starting over.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..');
const TERMS = fs.readFileSync(path.join(ROOT, 'lib/makerrun-terms.js'), 'utf8');
const LICENCE = fs.readFileSync(path.join(ROOT, 'lib/model-licence.js'), 'utf8');
const PANEL = fs.readFileSync(path.join(ROOT, 'renderer/bedready-makerrun.js'), 'utf8');

const DESIGNS = [
  { slug: 'desk-hook-a1b2c3', title: 'Desk hook', license: 'CC-BY-4.0', commercialUse: true, category: 'household', material: 'rigid',
    url: 'https://makerrun.com/designs/desk-hook-a1b2c3', cover: 'https://x.supabase.co/a.jpg', creator: 'Ada',
    verification: { badge: true, fileChecked: true, printPhotoConfirmed: false, printer: { brand: 'Prusa', model: 'MK4S' } }, sale: null, nsfw: false },
  { slug: 'vase-b2c3d4', title: 'Vase', license: 'CC-BY-NC-4.0', commercialUse: false, category: 'art', material: 'rigid',
    url: 'https://makerrun.com/designs/vase-b2c3d4', cover: null, creator: null,
    verification: { badge: false, fileChecked: false, printPhotoConfirmed: false, printer: null }, sale: { kind: 'file', price: 15, currency: 'SAR' }, nsfw: false },
];

const tick = async (w, n = 8) => { for (let i = 0; i < n; i++) await new Promise((r) => w.setTimeout(r, 0)); };
const wait = (w, ms) => new Promise((r) => w.setTimeout(r, ms));

async function boot(over = {}) {
  const dom = new JSDOM('<!doctype html><html data-app="bedready"><body></body></html>', { pretendToBeVisual: true });
  const { window } = dom;
  const calls = { browse: [], design: [], download: [], imported: [], cover: [], create: [], file: [], images: [], status: [], del: [], age: 0, signin: 0 };
  let linked = over.linked !== undefined ? over.linked : true;
  window.hubAPI = Object.assign({
    bedreadyLinked: async () => ({ ok: true, linked }),
    bedreadyOpenSignIn: () => { calls.signin++; },
    onBedreadyLinked: () => {},
    bedreadyCover: async (u) => { calls.cover.push(u); return { ok: false }; },
    makerrunBrowse: async (o) => { calls.browse.push(o); return { ok: true, designs: DESIGNS, page: { limit: 24, offset: o.offset || 0, total: 30, returned: 2 } }; },
    makerrunDesign: async (slug) => { calls.design.push(slug); const d = DESIGNS.find((x) => x.slug === slug); return { ok: true, design: d, files: [{ filename: 'hook.3mf', sizeBytes: 812344, hosted: true }], images: [], profiles: [{ printerBrand: 'Prusa', printerModel: 'MK4S', filamentType: 'PLA', colorCount: 1, badge: true }] }; },
    makerrunDownloadToLib: async (slug, filename, vaultId, title) => { calls.download.push({ slug, filename, vaultId, title }); return { ok: true, filename: 'Desk_hook.3mf', ext: '3mf', size: 9 }; },
    makerrunPublishCreate: async (input) => { calls.create.push(input); return { ok: true, slug: 'my-part-z9y8x7', status: 'pending' }; },
    makerrunPublishFile: async (slug, vaultId, filename) => { calls.file.push({ slug, vaultId, filename }); return { ok: true, verification: { verified: true, printer: 'MK4S', brand: 'Prusa', reason: null }, status: 'pending' }; },
    makerrunPublishImages: async (o) => { calls.images.push(o); return { ok: true, stored: 1, coverSet: 'https://x', failures: [] }; },
    makerrunStatus: async (slug) => { calls.status.push(slug); return { ok: true, found: true, status: 'published', verification: { badge: true, fileChecked: true } }; },
    makerrunDelete: async (slug) => { calls.del.push(slug); return { ok: true, deleted: true }; },
    makerrunOpenAge: async () => { calls.age++; return { ok: true }; },
    makerrunOpenPage: async () => ({ ok: true }),
  }, over.api || {});
  window.importConvertedAsNew = async (meta) => { calls.imported.push(meta); };
  window.uid = (p) => p + '-TEST';
  window.printFiles = over.printFiles || [];
  window.saveAll = () => { calls.saved = (calls.saved || 0) + 1; };

  const lctx = vm.createContext({});
  lctx.globalThis = lctx;
  vm.runInContext(fs.readFileSync(path.join(ROOT, 'renderer/locales/en.js'), 'utf8'), lctx);
  const strings = lctx.KhaytLocales.en;
  window.t = (key, vars) => {
    let s = strings[key] || key;
    if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
    return s;
  };
  const ctx = vm.createContext(window);
  vm.runInContext(LICENCE, ctx, { filename: 'model-licence.js' });
  vm.runInContext(TERMS, ctx, { filename: 'makerrun-terms.js' });
  vm.runInContext(PANEL, ctx, { filename: 'bedready-makerrun.js' });
  return { window, doc: window.document, calls, setLinked: (v) => { linked = v; }, strings };
}
const $ = (doc, sel) => doc.querySelector(sel);
const click = (doc, sel) => { const el = $(doc, sel); assert.ok(el, 'no element for ' + sel); el.click(); };
/** Objects made inside the jsdom realm have another Object.prototype; compare their data. */
const plain = (v) => JSON.parse(JSON.stringify(v));
const text = (doc) => doc.querySelector('.mr-body').textContent.replace(/\s+/g, ' ');

test('the panel only exists in Bed Ready, and exposes open + publish', async () => {
  const dom = new JSDOM('<!doctype html><html><body></body></html>');
  dom.window.hubAPI = { makerrunBrowse: async () => ({}) };
  vm.runInContext(PANEL, vm.createContext(dom.window));
  assert.equal(dom.window.BedReadyMakerRun, undefined, 'Khayt (no data-app="bedready") never gets the panel');
  const { window } = await boot();
  assert.equal(typeof window.BedReadyMakerRun.open, 'function');
  assert.equal(typeof window.BedReadyMakerRun.publish, 'function');
});

test('open() loads the first page of 24 and renders a card per design, covers via the proxy', async () => {
  const { window, doc, calls } = await boot();
  window.BedReadyMakerRun.open();
  await tick(window);
  assert.equal(calls.browse.length, 1);
  assert.equal(calls.browse[0].limit, 24);
  assert.equal(calls.browse[0].offset, 0);
  assert.equal(doc.querySelectorAll('.mr-card').length, 2);
  assert.deepEqual(calls.cover, ['https://x.supabase.co/a.jpg']);
  assert.match(text(doc), /1–2 of 30/);
  assert.match(text(doc), /For sale · 15 SAR/);
  assert.ok(doc.querySelector('[role="dialog"][aria-modal="true"]'));
});

test('typing is debounced into one request, and a filter resets to the first page', async () => {
  const { window, doc, calls } = await boot();
  window.BedReadyMakerRun.open();
  await tick(window);
  click(doc, '.mr-btn[data-mr="next"]');
  await tick(window);
  assert.equal(calls.browse.at(-1).offset, 24);

  const q = $(doc, '.mr-q');
  for (const v of ['g', 'gr', 'grid']) { q.value = v; q.dispatchEvent(new window.Event('input', { bubbles: true })); }
  await wait(window, 450);
  await tick(window);
  const searches = calls.browse.filter((b) => b.q);
  assert.equal(searches.length, 1, 'three keystrokes, one request');
  assert.equal(searches[0].q, 'grid');
  assert.equal(searches[0].offset, 0, 'a new search starts at the top');

  const cat = $(doc, '.mr-cat');
  cat.value = 'tools';
  cat.dispatchEvent(new window.Event('change', { bubbles: true }));
  await tick(window);
  assert.equal(calls.browse.at(-1).category, 'tools');

  const sale = $(doc, '.mr-sale');
  sale.value = 'free';
  sale.dispatchEvent(new window.Event('change', { bubbles: true }));
  await tick(window);
  assert.equal(calls.browse.at(-1).forSale, false);
});

test('the drawer names the licence on the download button, and the record keeps its provenance', async () => {
  const { window, doc, calls } = await boot();
  window.BedReadyMakerRun.open();
  await tick(window);
  click(doc, '.mr-card[data-arg="0"]');
  await tick(window);
  const drawer = $(doc, '.mr-drawer').textContent;
  assert.match(drawer, /CC-BY-4\.0/);
  assert.match(drawer, /Selling prints is allowed by the licence/);
  assert.match(drawer, /Original design by Ada/);
  assert.match(drawer, /hook\.3mf/);
  assert.match(drawer, /793 KB/);
  assert.match(drawer, /Prusa MK4S/);
  const dl = $(doc, '.mr-btn[data-mr="download"]');
  assert.equal(dl.textContent, 'Download under CC-BY-4.0');
  dl.click();
  await tick(window);
  assert.deepEqual(plain(calls.download), [{ slug: 'desk-hook-a1b2c3', filename: 'hook.3mf', vaultId: 'PF-TEST', title: 'Desk hook' }]);
  assert.equal(calls.imported.length, 1);
  const meta = calls.imported[0];
  assert.equal(meta.vaultId, 'PF-TEST');
  assert.equal(meta.source, 'https://makerrun.com/designs/desk-hook-a1b2c3');
  assert.equal(meta.licence, 'cc-by');
  assert.deepEqual(plain(meta.makerrun), { slug: 'desk-hook-a1b2c3', license: 'CC-BY-4.0', creator: 'Ada' });
  assert.match($(doc, '.mr-dl-result').textContent, /Added “Desk hook”/);
});

test('signed out: download asks to connect and sends nothing', async () => {
  const { window, doc, calls } = await boot({ linked: false });
  window.BedReadyMakerRun.open();
  await tick(window);
  click(doc, '.mr-card[data-arg="0"]');
  await tick(window);
  click(doc, '.mr-btn[data-mr="download"]');
  await tick(window);
  assert.equal(calls.download.length, 0);
  click(doc, '.mr-dl-result .mr-btn[data-mr="connect"]');
  assert.equal(calls.signin, 1);
});

test('age_required offers the age page; maintenance says when to come back', async () => {
  const { window, doc, calls } = await boot({ api: { makerrunDownloadToLib: async () => ({ ok: false, code: 'age_required', error: 'x' }) } });
  window.BedReadyMakerRun.open();
  await tick(window);
  click(doc, '.mr-card[data-arg="0"]');
  await tick(window);
  click(doc, '.mr-btn[data-mr="download"]');
  await tick(window);
  assert.match($(doc, '.mr-dl-result').textContent, /marked 18\+/);
  click(doc, '.mr-dl-result .mr-btn[data-mr="age"]');
  assert.equal(calls.age, 1);

  const b = await boot({ api: { makerrunBrowse: async () => ({ ok: false, code: 'maintenance', retryAfter: 180, error: 'x' }) } });
  b.window.BedReadyMakerRun.open();
  await tick(b.window);
  assert.match(text(b.doc), /maintenance.*about 3 min/);
});

const REC = () => ({
  id: 'PF-1', name: 'My part', licence: 'cc-by-nd', material: 'PLA',
  sourceFile: { filename: 'my-part.3mf', ext: '3mf', size: 10 }, userPhoto: null, thumbFile: 'thumb.jpg',
});

test('publish: an unmappable licence must be chosen, invalid fields are marked, then create → file run in order', async () => {
  const rec = REC();
  const { window, doc, calls } = await boot({ printFiles: [rec] });
  window.BedReadyMakerRun.publish('PF-1');
  await tick(window);
  assert.equal($(doc, '#mrTitleIn').value, 'My part');
  assert.equal($(doc, '#mrMatIn').value, 'rigid');
  assert.equal($(doc, '#mrLicIn').value, '', 'ND is not offered by MakerRun, so nothing is preselected');
  assert.match(text(doc), /This file's licence \(cc-by-nd\) is not one MakerRun offers/);

  click(doc, '.mr-btn[data-mr="review"]');
  await tick(window);
  assert.equal($(doc, '#mrCatIn').getAttribute('aria-invalid'), 'true');
  assert.equal($(doc, '#mrLicIn').getAttribute('aria-invalid'), 'true');
  assert.equal(calls.create.length, 0);

  const set = (sel, v) => { const el = $(doc, sel); el.value = v; el.dispatchEvent(new window.Event('change', { bubbles: true })); };
  set('#mrCatIn', 'tools');
  set('#mrLicIn', 'CC-BY-4.0');
  click(doc, '.mr-btn[data-mr="review"]');
  await tick(window);
  assert.match(text(doc), /public listing under your MakerRun account/);
  assert.equal(calls.create.length, 0, 'nothing is sent before the confirm');
  click(doc, '.mr-btn[data-mr="go"]');
  await tick(window, 20);

  assert.deepEqual(plain(calls.create), [{ title: 'My part', description: '', category: 'tools', material: 'rigid', license: 'CC-BY-4.0', nsfw: false }]);
  assert.deepEqual(plain(calls.file), [{ slug: 'my-part-z9y8x7', vaultId: 'PF-1', filename: 'my-part.3mf' }]);
  assert.equal(calls.images.length, 0, 'the picture is opt-in');
  assert.equal(rec.makerrunListing.slug, 'my-part-z9y8x7');
  assert.equal(rec.makerrunListing.step, 'done');
  assert.equal(rec.makerrunListing.verification.verified, true);
  assert.match(text(doc), /Pending review/);
  assert.match(text(doc), /Verified: slicer profile for Prusa MK4S/);

  click(doc, '.mr-btn[data-mr="status"]');
  await tick(window);
  assert.deepEqual(calls.status, ['my-part-z9y8x7']);
  assert.equal(rec.makerrunListing.status, 'published');
});

test('publish: a failed upload can be finished without re-creating, or the half listing deleted', async () => {
  const rec = REC();
  rec.licence = 'cc-by';
  let fail = true;
  const { window, doc, calls } = await boot({
    printFiles: [rec],
    api: {
      makerrunPublishFile: async (slug) => {
        calls.file.push(slug);
        if (fail) return { ok: false, code: 'rate_limited', retryAfter: 40, error: 'slow' };
        return { ok: true, verification: { verified: false, reason: 'no slicer profile' }, status: 'pending' };
      },
    },
  });
  window.BedReadyMakerRun.publish('PF-1');
  await tick(window);
  assert.equal($(doc, '#mrLicIn').value, 'CC-BY-4.0', 'a mappable licence is prefilled');
  $(doc, '#mrCatIn').value = 'tools';
  $(doc, '#mrCatIn').dispatchEvent(new window.Event('change', { bubbles: true }));
  // Opt in to the picture: the thumbnail, since there is no photo.
  const pic = $(doc, 'input[data-field="includePic"]');
  pic.checked = true;
  pic.dispatchEvent(new window.Event('change', { bubbles: true }));
  await tick(window);
  click(doc, '.mr-btn[data-mr="review"]');
  await tick(window);
  click(doc, '.mr-btn[data-mr="go"]');
  await tick(window, 20);
  assert.match(text(doc), /about 40 seconds/);
  assert.equal(rec.makerrunListing.step, 'created');

  fail = false;
  click(doc, '.mr-btn[data-mr="resume"]');
  await tick(window, 20);
  assert.equal(calls.create.length, 1, 'finishing never creates a second listing');
  assert.equal(calls.file.length, 2);
  assert.deepEqual(plain(calls.images), [{ slug: 'my-part-z9y8x7', vaultId: 'PF-1', kind: 'gallery', useThumb: true }]);
  assert.equal(rec.makerrunListing.step, 'done');
  assert.match(text(doc), /Not verified: no slicer profile/);

  // A record with a half listing opens on its status, with the delete behind a confirm.
  rec.makerrunListing.step = 'created';
  window.BedReadyMakerRun.publish('PF-1');
  await tick(window);
  assert.match(text(doc), /only partly uploaded/);
  click(doc, '.mr-btn[data-mr="delete"]');
  await tick(window);
  assert.equal(calls.del.length, 0, 'delete asks first');
  click(doc, '.mr-btn[data-mr="delete-go"]');
  await tick(window, 12);
  assert.deepEqual(calls.del, ['my-part-z9y8x7']);
  assert.equal(rec.makerrunListing, undefined);
});

test('publish: maintenance on create keeps the form as typed, and field errors map onto fields', async () => {
  const rec = REC();
  rec.licence = 'cc0';
  let answer = { ok: false, code: 'maintenance', retryAfter: 60, error: 'x' };
  const { window, doc } = await boot({ printFiles: [rec], api: { makerrunPublishCreate: async () => answer } });
  window.BedReadyMakerRun.publish('PF-1');
  await tick(window);
  const title = $(doc, '#mrTitleIn');
  title.value = 'Better title';
  title.dispatchEvent(new window.Event('input', { bubbles: true }));
  $(doc, '#mrCatIn').value = 'art';
  $(doc, '#mrCatIn').dispatchEvent(new window.Event('change', { bubbles: true }));
  click(doc, '.mr-btn[data-mr="review"]');
  await tick(window);
  click(doc, '.mr-btn[data-mr="go"]');
  await tick(window, 12);
  assert.match(text(doc), /maintenance/);
  assert.equal(rec.makerrunListing, undefined, 'nothing was created');
  click(doc, '.mr-btn[data-mr="edit"]');
  await tick(window);
  assert.equal($(doc, '#mrTitleIn').value, 'Better title');

  answer = { ok: false, code: 'invalid', error: 'x', details: [{ field: 'title', message: 'title must be 120 characters or fewer.' }] };
  click(doc, '.mr-btn[data-mr="review"]');
  await tick(window);
  click(doc, '.mr-btn[data-mr="go"]');
  await tick(window, 12);
  assert.equal($(doc, '#mrTitleIn').getAttribute('aria-invalid'), 'true');
  assert.match($(doc, '#mrErr-title').textContent, /120 characters/);
});

test('publish while signed out asks to connect first', async () => {
  const { window, doc, calls } = await boot({ linked: false, printFiles: [REC()] });
  window.BedReadyMakerRun.publish('PF-1');
  await tick(window);
  assert.match(text(doc), /Publishing needs your MakerRun account/);
  assert.equal($(doc, '#mrTitleIn'), null);
  click(doc, '.mr-btn[data-mr="connect"]');
  assert.equal(calls.signin, 1);
});
