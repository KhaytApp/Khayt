'use strict';
/**
 * "Save to Khayt" — the site readers, over pages written for the test.
 *
 * The fixtures in `test/fixtures/webext/` are small HTML files written by hand
 * in the shape each site's model pages take: canonical link, Open Graph,
 * JSON-LD, MakerWorld's `__NEXT_DATA__`, tag and creator links. Nothing here
 * fetches a live site. When a site changes its markup the reader is fixed
 * against a new fixture, and this file says what the old one still gives.
 *
 * The readers are the extension's own module, imported unchanged: the popup
 * runs exactly these functions over the page it was handed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const FIX = path.join(__dirname, 'fixtures', 'webext');
const EXT = path.join(__dirname, '..', 'extension-khayt');
const load = () => import(path.join(EXT, 'src', 'adapters.js'));
const page = (name) => new JSDOM(fs.readFileSync(path.join(FIX, name), 'utf8')).window.document;

test('Printables: title off the h1, creator off the @ link, CC licence as an id, tags de-duplicated', async () => {
  const { extract } = await load();
  const r = extract(page('printables.html'), 'https://www.printables.com/model/123456-articulated-dragon/files');
  assert.equal(r.url, 'https://www.printables.com/model/123456-articulated-dragon');
  assert.equal(r.site, 'printables');
  assert.equal(r.title, 'Articulated Dragon');
  assert.equal(r.creator, 'Maker Bob');
  assert.equal(r.licence, 'cc-by-nc-sa');
  assert.deepEqual(r.tags, ['dragon', 'flexi', 'print-in-place']);
  assert.equal(r.cover, 'https://media.printables.com/media/prints/123456/images/cover.webp');
  // The direct .3mf, and NOT the javascript: link beside it.
  assert.deepEqual(r.files, [{ url: 'https://files.printables.com/media/prints/123456/stls/dragon_body.3mf', name: 'dragon_body.3mf' }]);
});

test('MakerWorld: the page data wins, markup in the summary becomes plain lines, BY-SA is cc-by-sa', async () => {
  const { extract } = await load();
  const r = extract(page('makerworld.html'), 'https://makerworld.com/en/models/88231?from=search#profileId-1');
  assert.equal(r.url, 'https://makerworld.com/en/models/88231');
  assert.equal(r.site, 'makerworld');
  assert.equal(r.title, 'Gridfinity Bin 2x3');
  assert.equal(r.creator, 'Grid Maker');
  assert.equal(r.licence, 'cc-by-sa');
  assert.equal(r.description, 'A stackable bin.\nFits the 42 mm grid.');
  assert.ok(!/onerror|<|alert/.test(r.description), 'no markup survives into the excerpt');
  assert.deepEqual(r.tags, ['gridfinity', 'storage', 'organiser']);
  assert.equal(r.cover, 'https://makerworld.bblmw.com/makerworld/model/cover.png');
});

test('Thingiverse: "Name by user - Thingiverse" split, /tag: links, the CC link, one direct .stl', async () => {
  const { extract } = await load();
  const r = extract(page('thingiverse.html'), 'https://www.thingiverse.com/thing:4711/files');
  assert.equal(r.url, 'https://www.thingiverse.com/thing:4711');
  assert.equal(r.title, 'Cable Clip');
  assert.equal(r.creator, 'printguy');
  assert.equal(r.licence, 'cc-by');
  assert.deepEqual(r.tags, ['cable', 'desk']);
  // `download:9988` is a page, not a model file.
  assert.deepEqual(r.files.map((f) => f.name), ['clip.stl']);
});

test('Thangs: the title cut at its first site segment, the designer link, keywords as tags', async () => {
  const { extract } = await load();
  const r = extract(page('thangs.html'), 'https://thangs.com/designer/gearhead/3d-model/Planetary%20Gear%20Box-998877');
  assert.equal(r.site, 'thangs');
  assert.equal(r.title, 'Planetary Gear Box');
  assert.equal(r.creator, 'gearhead');
  assert.deepEqual(r.tags, ['gear', 'planetary', 'mechanism']);
  assert.equal(r.licence, '');
});

test('Cults3D: the Product inside an @graph, the brand as creator, CC BY-ND', async () => {
  const { extract } = await load();
  const r = extract(page('cults3d.html'), 'https://cults3d.com/en/3d-model/art/low-poly-fox');
  assert.equal(r.title, 'Low Poly Fox 🦊');
  assert.equal(r.creator, 'FoxStudio');
  assert.equal(r.licence, 'cc-by-nd');
  assert.equal(r.cover, 'https://images.cults3d.com/fox.png');
  assert.deepEqual(r.tags, ['fox', 'lowpoly']);
});

test('MyMiniFactory: "Name by studio" split, the /users/ link; no licence on the page is no licence', async () => {
  const { extract } = await load();
  const r = extract(page('myminifactory.html'), 'https://www.myminifactory.com/object/3d-print-knight-bust-301234');
  assert.equal(r.title, 'Knight Bust');
  assert.equal(r.creator, 'Studio North');
  assert.equal(r.licence, '');
  assert.deepEqual(r.tags, ['knight']);
});

test('any other site: JSON-LD 3DModel, a broken block skipped, relative links resolved, http dropped', async () => {
  const { extract } = await load();
  const r = extract(page('generic-jsonld.html'), 'https://models.example.com/item/desk-organiser');
  assert.equal(r.site, 'web');
  assert.equal(r.title, 'Desk Organiser');
  assert.equal(r.creator, 'Rana');
  assert.equal(r.licence, 'cc-by-nc');
  assert.equal(r.cover, 'https://models.example.com/img/organiser.jpg');
  assert.ok(!r.url.includes('#'), 'the fragment is not part of the address');
  assert.deepEqual(r.files, [{ url: 'https://models.example.com/files/organiser.stl', name: 'organiser.stl' }]);
});

test('Open Graph only, in Arabic: kept as written; an http picture is not a picture', async () => {
  const { extract } = await load();
  const r = extract(page('generic-og.html'), 'https://example.sa/models/falcon?x=1');
  assert.equal(r.url, 'https://example.sa/models/falcon');
  assert.equal(r.title, 'تمثال صقر');
  assert.equal(r.creator, 'سارة');
  assert.deepEqual(r.tags, ['صقر', 'ديكور']);
  assert.equal(r.cover, '');
});

test('a page with no title, or not on https, gives nothing to save', async () => {
  const { extract } = await load();
  const blank = new JSDOM('<!doctype html><title></title><p>nothing</p>').window.document;
  assert.equal(extract(blank, 'https://example.com/'), null);
  const insecure = new JSDOM('<!doctype html><title>Thing</title>').window.document;
  assert.equal(extract(insecure, 'http://example.com/thing'), null);
});

test('the site is the address, never what the page calls itself', async () => {
  const { extract, siteOf } = await load();
  const doc = new JSDOM('<!doctype html><title>Dragon | Printables.com</title><link rel="canonical" href="https://evil.example/model/1">').window.document;
  assert.equal(extract(doc, 'https://evil.example/model/1').site, 'web');
  assert.equal(siteOf('https://printables.com.evil.example/model/1'), 'web');
  assert.equal(siteOf('https://www.makerworld.com/en/models/1'), 'makerworld');
});

test('licence words become Khayt ids only when they are Creative Commons; anything else is passed as written', async () => {
  const { licenceId } = await load();
  assert.equal(licenceId('Creative Commons — Attribution — Noncommercial — Share Alike'), 'cc-by-nc-sa');
  assert.equal(licenceId('CC BY-NC 4.0'), 'cc-by-nc');
  assert.equal(licenceId('https://creativecommons.org/licenses/by-nd/4.0/'), 'cc-by-nd');
  assert.equal(licenceId('https://creativecommons.org/publicdomain/zero/1.0/'), 'cc0');
  assert.equal(licenceId('BY-NC-SA'), 'cc-by-nc-sa');
  assert.equal(licenceId('Standard Digital File License'), 'Standard Digital File License');
  assert.equal(licenceId(''), '');
});

test('caps: a page cannot send an essay, a hundred tags or a hundred links', async () => {
  const { extract, MAX_TAGS, MAX_FILES, MAX_DESCRIPTION, MAX_TITLE } = await load();
  const tags = Array.from({ length: 60 }, (_, i) => `<meta property="article:tag" content="t${i}">`).join('');
  const links = Array.from({ length: 60 }, (_, i) => `<a href="https://x.example/f${i}.stl">f</a>`).join('');
  const html = `<!doctype html><title>${'T'.repeat(900)}</title>
    <meta property="og:url" content="https://x.example/m/1">
    <meta property="og:description" content="${'word '.repeat(800)}">${tags}${links}`;
  const r = extract(new JSDOM(html).window.document, 'https://x.example/m/1');
  assert.ok(r.title.length <= MAX_TITLE);
  assert.ok(r.description.length <= MAX_DESCRIPTION);
  assert.equal(r.tags.length, MAX_TAGS);
  assert.equal(r.files.length, MAX_FILES);
});

test('what the popup says for each answer Khayt can give', async () => {
  const { describe } = await import(path.join(EXT, 'src', 'states.js'));
  assert.deepEqual(describe({ state: 'saved' }), { key: 'resultSaved', tone: 'good' });
  assert.deepEqual(describe({ state: 'updated' }), { key: 'resultUpdated', tone: 'good' });
  assert.deepEqual(describe({ state: 'queued' }), { key: 'resultQueued', tone: 'wait' });
  assert.deepEqual(describe({ state: 'refused', reason: 'off' }), { key: 'resultRefusedOff', tone: 'bad' });
  assert.deepEqual(describe({ state: 'refused', reason: 'not-allowed' }), { key: 'resultRefusedLock', tone: 'bad' });
  assert.deepEqual(describe({ state: 'refused', reason: 'sample' }), { key: 'resultRefusedSample', tone: 'bad' });
  assert.deepEqual(describe({ state: 'no-host' }), { key: 'resultNoHost', tone: 'bad' });
  assert.deepEqual(describe(undefined), { key: 'resultNoHost', tone: 'bad' });
});

test('the two languages carry the same keys, and every key the popup uses exists', () => {
  const read = (l) => JSON.parse(fs.readFileSync(path.join(EXT, '_locales', l, 'messages.json'), 'utf8'));
  const en = read('en'); const ar = read('ar');
  assert.deepEqual(Object.keys(ar).sort(), Object.keys(en).sort());
  for (const [k, v] of Object.entries(ar)) {
    assert.ok(v.message && v.message !== en[k].message, `${k} is translated`);
    assert.equal((v.message.match(/\$1/g) || []).length, (en[k].message.match(/\$1/g) || []).length, `${k} keeps its $1`);
  }
  const used = new Set();
  for (const f of ['popup.html', 'popup.js', 'src/states.js']) {
    const text = fs.readFileSync(path.join(EXT, f), 'utf8');
    for (const m of text.matchAll(/data-i18n="(\w+)"|say\('(\w+)'/g)) used.add(m[1] || m[2]);
    if (f === 'src/states.js') for (const m of text.matchAll(/'(result\w+)'/g)) used.add(m[1]);
  }
  const manifest = fs.readFileSync(path.join(EXT, 'manifest.json'), 'utf8');
  for (const m of manifest.matchAll(/__MSG_(\w+)__/g)) used.add(m[1]);
  for (const k of used) assert.ok(en[k], `${k} is in _locales/en`);
});

test('the manifest asks for the page only when pressed: no host permissions, no content scripts', () => {
  const m = JSON.parse(fs.readFileSync(path.join(EXT, 'manifest.json'), 'utf8'));
  assert.equal(m.manifest_version, 3);
  assert.deepEqual([...m.permissions].sort(), ['activeTab', 'nativeMessaging', 'scripting'].sort()
    .concat(m.permissions.includes('downloads') ? ['downloads'] : []).sort());
  assert.equal(m.host_permissions, undefined);
  assert.equal(m.content_scripts, undefined);
  assert.equal(m.optional_host_permissions, undefined);
});

test('the packager writes each browser its own background, and ships no tests', async () => {
  const { manifestFor, FILES } = await import(path.join(EXT, 'pack.mjs'));
  assert.deepEqual(manifestFor('chrome').background, { service_worker: 'background.js' });
  assert.deepEqual(manifestFor('firefox').background, { scripts: ['background.js'] });
  assert.ok(manifestFor('firefox').browser_specific_settings.gecko.id);
  assert.deepEqual(manifestFor('safari').background, { scripts: ['background.js'], persistent: false });
  assert.ok(!FILES.includes('package.json') && !FILES.includes('pack.mjs'));
});

test('nothing in the extension talks to the network or to localhost', () => {
  const files = ['popup.js', 'background.js', ...fs.readdirSync(path.join(EXT, 'src')).map((f) => 'src/' + f)];
  for (const f of files) {
    const code = fs.readFileSync(path.join(EXT, f), 'utf8').replace(/\/\/.*$/gm, '');
    assert.ok(!/\bfetch\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon/.test(code), `${f} makes no request`);
    assert.ok(!/localhost|127\.0\.0\.1|khayt:\/\//.test(code), `${f} names no local server and no khayt:// link`);
  }
});
