/**
 * The library over the LAN (docs/LAN_API.md "GET /api/library, its thumbnails,
 * and POST /api/library/{id}/estimate"): a phone paired with this computer
 * searches the library and has a model priced without the file leaving here.
 * The paging and search rules are lib/lan-library.js; the routes are proven
 * here over real HTTP, because who may ask is the point.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));
const LanLibrary = require(path.join(ROOT, 'lib/lan-library.js'));

const PORT = 3962;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const OWNER = { 'x-khayt-pin': PIN };
const noop = () => {};
const handlers = new Map();
let tmp;

const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a4c50000000049454e44ae426082', 'hex');

/** A closed cube, `s` mm on a side, as ASCII STL. */
function cubeStl(s) {
  const v = [[0, 0, 0], [s, 0, 0], [s, s, 0], [0, s, 0], [0, 0, s], [s, 0, s], [s, s, s], [0, s, s]];
  const faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]];
  const tri = (f) => `facet normal 0 0 0\nouter loop\n${f.map((i) => `vertex ${v[i].join(' ')}`).join('\n')}\nendloop\nendfacet`;
  return `solid cube\n${faces.map(tri).join('\n')}\nendsolid cube\n`;
}

const rec = (id, extra = {}) => ({ id, name: id, sourceFile: { filename: `${id}.stl`, ext: 'stl', size: 1000 }, ...extra });

const baseStore = () => ({
  inventory: [
    { id: 'S-pla', material: 'PLA Basic', cost: 80, spoolWeight: 1000 },
    { id: 'S-petg', material: 'PETG HF', cost: 120, spoolWeight: 1000 },
  ],
  settings: {
    currency: 'SAR',
    // The customer intake form is NOT set up: the owner's price does not need it.
    lanApi: { intakeToken: 'tok' },
  },
  printLog: [], machines: [], clients: [],
  printFiles: [
    rec('PF-lantern', { name: 'Lantern', folder: 'Home', tags: ['gift'], favorite: false, timesPrinted: 6,
      parsed: { printTimeMins: 318, filamentGrams: 154, slicer: 'OrcaSlicer', filamentType: 'PETG',
        plates: [{ index: 1, name: 'Body', printTimeMins: 205, filamentGrams: 112 }, { index: 2, printTimeMins: 113, filamentGrams: 42 }] },
      colors: [{ hex: '#0F5257', grams: 88 }], thumbFile: 'thumb.png' }),
    rec('PF-cube', { name: 'Cube', folder: 'Saudi Kings/Large' }),
    rec('PF-étagère', { name: 'Étagère', folder: 'Saudi Kings', favorite: true, category: 'Decor' }),
    rec('PF-zeta', { name: 'Zeta', folder: 'Saudi Kings' }),
    rec('PF-top', { name: 'Top', folder: '', thumb: `data:image/png;base64,${PNG.toString('base64')}` }),
    rec('PF-nofile', { name: 'No file', sourceFile: null }),
    rec('PF-step', { name: 'Step', sourceFile: { filename: 'a.step', ext: 'step' } }),
    rec('PF-missing', { name: 'Missing on disk' }),
    rec('PF-big', { name: 'Big' }),
  ],
});
let store = baseStore();

before(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-lan-lib-'));
  const dir = (id) => path.join(tmp, encodeURIComponent(id));
  for (const id of ['PF-lantern', 'PF-cube', 'PF-big']) fs.mkdirSync(dir(id));
  fs.writeFileSync(path.join(dir('PF-lantern'), 'thumb.png'), PNG);
  fs.writeFileSync(path.join(dir('PF-cube'), 'PF-cube.stl'), cubeStl(20));
  // Past the estimate cap without writing 32 MB: a sparse file.
  const fd = fs.openSync(path.join(dir('PF-big'), 'PF-big.stl'), 'w');
  fs.ftruncateSync(fd, 33 * 1024 * 1024); fs.closeSync(fd);
  registerLanServer({
    fs,
    ipcMain: { handle: (n, f) => handlers.set(n, f) },
    BrowserWindow: class { static getAllWindows() { return []; } },
    safeJsonParse: (s, f) => { try { return JSON.parse(s); } catch { return f; } },
    syncLanServerStoreFromDisk: noop,
    resolveStoreSecret: (v) => v,
    isStoreSecretMasked: () => false,
    migrateLanApiSecrets: noop,
    ensureLanIntakeToken: () => ({ token: 'tok', generated: false }),
    ensureLanIntakePin: () => ({ pin: '1234', generated: false }),
    ensureLanCalendarToken: () => ({ token: 'cal', generated: false }),
    writeStoreToDisk: async () => {},
    persistLanStoreUpdate: async (s) => { store = s; },
    updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => null,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
    printLibrary: { itemDir: dir, rehydrate: async () => ({ ok: true }) },
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, JSON.stringify(r));
});
after(async () => {
  await handlers.get('hub:stop-lan-server')?.(null, {});
  fs.rmSync(tmp, { recursive: true, force: true });
});

const estimate = (id, qs = '') => fetch(`${BASE}/api/library/${encodeURIComponent(id)}/estimate${qs}`, { method: 'POST', headers: OWNER });

test('all three routes are the owner\'s', async () => {
  assert.equal((await fetch(`${BASE}/api/library`)).status, 401);
  assert.equal((await fetch(`${BASE}/api/library/PF-lantern/thumb`)).status, 401);
  assert.equal((await fetch(`${BASE}/api/library/PF-cube/estimate`, { method: 'POST' })).status, 401);
  assert.equal((await fetch(`${BASE}/api/library`, { headers: { 'x-khayt-pin': 'wrong-pin' } })).status, 401);
});

test('the top folder: its own models, and its sub-folders counted to the bottom', async () => {
  const res = await fetch(`${BASE}/api/library`, { headers: OWNER });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body.folders, [
    { path: 'Home', name: 'Home', count: 1 },
    { path: 'Saudi Kings', name: 'Saudi Kings', count: 3 },
  ]);
  assert.ok(body.items.every((i) => i.folder === ''));
  assert.equal(body.total, 5);
});

test('a folder: favourites first, then by name; sub-folders by path', async () => {
  const body = await (await fetch(`${BASE}/api/library?folder=${encodeURIComponent('Saudi Kings')}`, { headers: OWNER })).json();
  assert.deepEqual(body.items.map((i) => i.id), ['PF-étagère', 'PF-zeta']);
  assert.deepEqual(body.folders, [{ path: 'Saudi Kings/Large', name: 'Large', count: 1 }]);
});

test('a search covers every folder, ignores case and accents, and needs every word', async () => {
  const one = await (await fetch(`${BASE}/api/library?q=ETAGERE&folder=Home`, { headers: OWNER })).json();
  assert.deepEqual(one.items.map((i) => i.id), ['PF-étagère']);
  assert.deepEqual(one.folders, []);
  const tagAndFolder = await (await fetch(`${BASE}/api/library?q=gift%20home`, { headers: OWNER })).json();
  assert.deepEqual(tagAndFolder.items.map((i) => i.id), ['PF-lantern']);
  const none = await (await fetch(`${BASE}/api/library?q=gift%20kings`, { headers: OWNER })).json();
  assert.equal(none.total, 0);
});

test('paged on the server, limit held to 1–200', () => {
  const many = Array.from({ length: 450 }, (_, i) => ({ id: `M${i}`, name: `M${String(i).padStart(3, '0')}` }));
  const p = LanLibrary.list(many, { offset: 400, limit: 500 });
  assert.equal(p.total, 450);
  assert.equal(p.items.length, 50);
  assert.equal(p.items[0].id, 'M400');
  assert.equal(LanLibrary.list(many, { limit: 0 }).items.length, 1);
  assert.equal(LanLibrary.list(many, {}).items.length, 50);
});

test('an item carries what the book has, null slicer figures, and nothing made up', async () => {
  const body = await (await fetch(`${BASE}/api/library?q=lantern`, { headers: OWNER })).json();
  assert.deepEqual(body.items[0], {
    id: 'PF-lantern', name: 'Lantern', folder: 'Home', tags: ['gift'], ext: 'stl', size: 1000,
    favorite: false, timesPrinted: 6, thumb: true, estimable: true,
    printTimeMins: 318, grams: 154,
    plates: [{ index: 1, name: 'Body', printTimeMins: 205, grams: 112 }, { index: 2, printTimeMins: 113, grams: 42 }],
    colors: [{ hex: '#0F5257', grams: 88 }],
  });
  const cube = LanLibrary.itemOf(store.printFiles[1]);
  assert.equal(cube.printTimeMins, null);
  assert.equal(cube.grams, null);
  assert.equal(LanLibrary.itemOf(store.printFiles[6]).estimable, false, 'a STEP cannot be measured');
  assert.equal(LanLibrary.itemOf(store.printFiles[5]).estimable, false, 'nothing in the vault');
});

test('thumbnails: from beside the model, or from the book, else 404', async () => {
  const disk = await fetch(`${BASE}/api/library/PF-lantern/thumb`, { headers: OWNER });
  assert.equal(disk.status, 200);
  assert.equal(disk.headers.get('content-type'), 'image/png');
  assert.equal(disk.headers.get('cache-control'), 'private, max-age=86400');
  assert.ok(Buffer.from(await disk.arrayBuffer()).equals(PNG));
  const inBook = await fetch(`${BASE}/api/library/PF-top/thumb`, { headers: OWNER });
  assert.equal(inBook.status, 200);
  assert.ok(Buffer.from(await inBook.arrayBuffer()).equals(PNG));
  assert.equal((await fetch(`${BASE}/api/library/PF-cube/thumb`, { headers: OWNER })).status, 404);
  assert.equal((await fetch(`${BASE}/api/library/nope/thumb`, { headers: OWNER })).status, 404);
});

test('recorded slicer figures are priced as they are, exact', async () => {
  const res = await estimate('PF-lantern', '?qty=2');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.exact, true);
  assert.equal(body.qty, 2);
  assert.equal(body.hours, 5.3, 'per piece');
  assert.equal(body.grams, 154, 'per piece');
  assert.equal(body.reliable, true);
  assert.equal(body.currency, 'SAR');
  assert.ok(body.price > 0);
  const plate = await (await estimate('PF-lantern', '?plate=2')).json();
  assert.equal(plate.ok, true);
  assert.equal(plate.grams, 42);
  assert.ok(plate.price < body.price);
  assert.equal((await estimate('PF-lantern', '?plate=9')).status, 404);
});

test('without figures the file in the vault is measured', async () => {
  const body = await (await estimate('PF-cube')).json();
  assert.equal(body.ok, true, JSON.stringify(body));
  assert.equal(body.exact, false);
  assert.ok(body.grams > 0 && body.hours > 0 && body.price > 0);
});

test('refusals say why', async () => {
  const cases = [
    ['nope', 404, 'not-found'],
    ['PF-nofile', 409, 'no-file'],
    ['PF-missing', 409, 'no-file'],
    ['PF-step', 415, 'unsupported'],
    ['PF-big', 413, 'too-large'],
  ];
  for (const [id, status, reason] of cases) {
    const res = await estimate(id);
    assert.equal(res.status, status, id);
    const body = await res.json();
    assert.equal(body.ok, false, id);
    assert.equal(body.reason, reason, id);
    assert.equal(body.price, null, id);
  }
});

test('the owner\'s price is the calculator\'s: the shop\'s rates, its spool of the material, its margin', async () => {
  const L = LanLibrary;
  const deps = {
    partPatch: require(path.join(ROOT, 'lib/part-from-print-file.js')).partPatch,
    ratesFor: require(path.join(ROOT, 'lib/print-rates.js')).ratesFor,
    computePartBaseCost: require(path.join(ROOT, 'lib/calculator-cost.js')).computePartBaseCost,
    quoteTotal: require(path.join(ROOT, 'lib/pricing.js')).quoteTotal,
    overheadPerHour: 0,
  };
  const lantern = store.printFiles[0];
  assert.equal(L.spoolFor('PETG', store.inventory).id, 'S-petg', 'the material it was sliced for');
  assert.equal(L.spoolFor('ASA', store.inventory).id, 'S-pla', 'else the first spool with a cost');
  assert.equal(L.spoolFor('PLA', [{ id: 'x', material: 'PLA', cost: 0 }]), null);
  const at = (margin) => L.ownerQuote({ rec: lantern, plate: null, measured: null, qty: 1, deps,
    store: { ...store, settings: { ...store.settings, ...(margin == null ? {} : { defaultMargin: margin }) } } });
  const thirty = at(null), zero = at(0);
  assert.ok(thirty.ok && zero.ok);
  assert.equal(Math.round((thirty.price / zero.price) * 1000) / 1000, 1.3, 'thirty per cent when the shop has said nothing');
  assert.ok(Math.abs(at(50).price - zero.price * 1.5) <= 0.01, 'the shop\'s own margin');
  // Over HTTP, the same number.
  const http = await (await estimate('PF-lantern')).json();
  assert.equal(http.price, thirty.price);
  // Multi-colour weights are the slicer's, as the calculator reads them.
  const multi = L.ownerQuote({ rec: { id: 'm', colors: [{ hex: '#000', grams: 30 }, { hex: '#fff', grams: 20 }], parsed: { printTimeMins: 90 } },
    plate: null, measured: null, qty: 1, deps, store });
  assert.equal(multi.grams, 50);
  assert.equal(multi.exact, true);
});

test('no spool on the shelf is still a price (labour, power, wear), never 0 and never not-configured', async () => {
  const saved = store.inventory;
  store.inventory = [];
  try {
    const body = await (await estimate('PF-lantern')).json();
    assert.equal(body.ok, true);
    assert.ok(body.price > 0);
  } finally { store.inventory = saved; }
});

test('a model file is read only from its own folder', async () => {
  const saved = store.printFiles[1].sourceFile.filename;
  store.printFiles[1].sourceFile.filename = '../PF-cube/PF-cube.stl';
  try {
    // The base name still names the cube in its own folder; a path cannot lead out.
    assert.equal((await estimate('PF-cube')).status, 200);
    store.printFiles[1].sourceFile.filename = '..';
    assert.equal((await estimate('PF-cube')).status, 409);
  } finally { store.printFiles[1].sourceFile.filename = saved; }
});

// A model archived on the Mac (archivedAt — by the shop, or because its vault
// file was trashed elsewhere, #2071) is out of the phone's library from either
// computer: the Mac's own LAN listing filters it (Shop+PhoneLibrary.swift) and
// 404s its estimate.
test('a model archived on the Mac is not in the phone\'s library, and its picture and price are not found', async () => {
  const saved = store;
  store = baseStore();
  const lantern = store.printFiles.find((r) => r.id === 'PF-lantern');
  const cube = store.printFiles.find((r) => r.id === 'PF-cube');
  lantern.archivedAt = '2026-10-26T09:00:00Z';
  Object.assign(cube, { archivedAt: '2026-10-26T09:00:00Z', vaultArchived: true, vaultTrashedAt: '2026-10-26T08:00:00Z' });
  try {
    const top = await (await fetch(`${BASE}/api/library`, { headers: OWNER })).json();
    const ids = (top.items || []).map((i) => i.id);
    assert.ok(!ids.includes('PF-lantern'), 'archived is not listed');
    assert.ok(!(top.folders || []).some((f) => f.path === 'Home'), 'a folder holding only archived models is gone');
    const kings = (top.folders || []).find((f) => f.path === 'Saudi Kings');
    assert.equal(kings && kings.count, 2, 'folder counts leave the archived cube out');
    const found = await (await fetch(`${BASE}/api/library?q=lantern`, { headers: OWNER })).json();
    assert.deepEqual(found.items, [], 'search does not find it');
    assert.equal((await fetch(`${BASE}/api/library/PF-lantern/thumb`, { headers: OWNER })).status, 404);
    const est = await estimate('PF-cube');
    assert.equal(est.status, 404);
    assert.equal((await est.json()).reason, 'not-found');
    assert.deepEqual(LanLibrary.list(store.printFiles, { q: 'cube' }).items, []);
  } finally {
    store = saved;
  }
});

test('figures measured from older bytes (figuresStaleFor) are never priced as the model\'s', () => {
  const PartFromPrintFile = require(path.join(ROOT, 'lib/part-from-print-file.js'));
  const rec = {
    id: 'PF-stale', name: 'Hood', figuresStaleFor: 'abc',
    sourceFile: { filename: 'hood.stl' },
    parsed: { printTimeMins: 120, filamentGrams: 40, filamentType: 'PETG',
              plates: [{ index: 1, printTimeMins: 120, filamentGrams: 40 }] },
    colors: [{ hex: '#fff', grams: 40 }],
  };
  const patch = PartFromPrintFile.partPatch(rec);
  assert.equal(patch.stale, true);
  assert.equal(patch.fields.printWeight, undefined);
  assert.equal(patch.fields.printTime, undefined);
  assert.deepEqual(patch.missing.sort(), ['printTime', 'printWeight']);
  assert.equal(patch.fields.material, 'PETG', 'the material is still the file\'s');
  assert.equal(LanLibrary.recordedFigures(rec, null), null);
  assert.equal(LanLibrary.recordedFigures(rec, 1), null, 'a real plate: no figures, not unknown');
  assert.equal(LanLibrary.recordedFigures(rec, 7), false);
  const item = LanLibrary.itemOf(rec);
  assert.equal(item.printTimeMins, null);
  assert.equal(item.grams, null);
  assert.equal(item.plates, undefined);
  // The same record, current: figures as before.
  const fresh = { ...rec, figuresStaleFor: undefined };
  assert.equal(PartFromPrintFile.partPatch(fresh).fields.printWeight, 40);
  assert.equal(LanLibrary.recordedFigures(fresh, null).exact, true);
});

// ── The two filter menus: colour and file type ──────────────────────────────

const FILTERED = [
  { id: 'a', name: 'A', sourceFile: { filename: 'a.3mf' }, colors: [{ hex: '#ff0000' }, { hex: '#ffffff' }] },
  { id: 'b', name: 'B', sourceFile: { filename: 'b.stl' } },
  { id: 'c', name: 'C', sourceFile: { filename: 'c.3mf' }, colors: [{ hex: '#0000ff' }] },
  { id: 'd', name: 'D', sourceFile: { filename: 'd.gcode' }, colors: [{ hex: '#0000cc' }] },
  { id: 'e', name: 'E' },
  { id: 'f', name: 'F', folder: 'Deep', sourceFile: { filename: 'f.stl' }, colors: [{ hex: '#ff0000' }] },
];
const ids = (page) => page.items.map((i) => i.id);

test('colour and type narrow the list: OR within a menu, AND between them and with the search', () => {
  assert.deepEqual(ids(LanLibrary.list(FILTERED, {})), ['a', 'b', 'c', 'd', 'e'], 'nothing chosen: the folder as it was');
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: 'blue' })), ['c', 'd']);
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: 'blue,red' })), ['a', 'c', 'd'], 'red OR blue');
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: 'blue', type: '3mf' })), ['c'], 'blue AND 3MF');
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { type: 'stl,gcode' })), ['b', 'd']);
  // A multicolour model is under each of its families and under multi.
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: 'white' })), ['a']);
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: 'multi' })), ['a']);
  // No colour stored, and no file at all, are rows of their own.
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: 'none' })), ['b', 'e']);
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { type: 'nofile' })), ['e']);
  // With a search the whole library is covered, and still narrowed.
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { q: 'f', colour: 'red' })), ['f']);
  assert.equal(LanLibrary.list(FILTERED, { colour: 'red' }).total, 1);
  // A key nobody knows is ignored, not an error; case and spaces do not matter.
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: 'teal' })), ['a', 'b', 'c', 'd', 'e']);
  assert.deepEqual(ids(LanLibrary.list(FILTERED, { colour: ' Blue , teal ', type: '3MF' })), ['c']);
  // The sub-folders follow the menus: listed for what passes under them, at that count.
  assert.deepEqual(LanLibrary.list(FILTERED, {}).folders.map((f) => [f.path, f.count]), [['Deep', 1]]);
  assert.deepEqual(LanLibrary.list(FILTERED, { colour: 'red' }).folders.map((f) => [f.path, f.count]), [['Deep', 1]]);
  assert.deepEqual(LanLibrary.list(FILTERED, { colour: 'blue' }).folders, [], 'nothing blue under Deep: not offered');
  assert.deepEqual(LanLibrary.list(FILTERED, { colour: 'red', type: '3mf' }).folders, [], 'the red one under Deep is an STL');
  // "N of M" is counted over the folder AND everything under it, like the
  // sub-folders' counts; `total` pages the models listed here.
  const nOfM = (o) => { const p = LanLibrary.list(FILTERED, o); return [p.total, p.matchedTotal, p.unfilteredTotal]; };
  assert.deepEqual(nOfM({}), [5, 6, 6]);
  assert.deepEqual(nOfM({ colour: 'blue' }), [2, 2, 6]);
  assert.deepEqual(nOfM({ colour: 'red' }), [1, 2, 6], 'one red here, another under Deep');
  assert.deepEqual(nOfM({ folder: 'Deep', colour: 'red' }), [1, 1, 1]);
  assert.deepEqual(nOfM({ q: 'f', colour: 'blue' }), [0, 0, 1], 'for a search all three are over the search');
});

test('each menu is counted over everything but its own choice, with every key present', () => {
  const ColourFamily = require(path.join(ROOT, 'lib/colour-family.js'));
  const ModelFileType = require(path.join(ROOT, 'lib/model-file-type.js'));
  const none = LanLibrary.list(FILTERED, {}).facets;
  assert.deepEqual(Object.keys(none.colour), ColourFamily.TOKENS, 'every colour key, in the menu\'s order');
  assert.deepEqual(Object.keys(none.type), ModelFileType.TYPES);
  // Counted over the top folder and everything under it: the red STL in Deep is in.
  assert.deepEqual(none.colour, { red: 2, orange: 0, yellow: 0, green: 0, blue: 2, purple: 0, pink: 0, brown: 0,
    black: 0, grey: 0, white: 1, multi: 1, none: 2 });
  assert.deepEqual(none.type, { '3mf': 2, stl: 2, step: 0, obj: 0, gcode: 1, other: 0, nofile: 1 });
  // THE CASE THIS SCOPE EXISTS FOR: two loose models, the reds all in folders.
  // The menu must not say Red 0 beside a folder that says it holds two.
  const nested = [
    { id: 'x', name: 'X', colors: [{ hex: '#00ff00' }] }, { id: 'y', name: 'Y' },
    { id: 'h1', name: 'H1', folder: 'Home', colors: [{ hex: '#ff0000' }] },
    { id: 'h2', name: 'H2', folder: 'Home/Deep', colors: [{ hex: '#ff0000' }] },
  ];
  const top = LanLibrary.list(nested, { colour: 'red' });
  assert.equal(top.facets.colour.red, 2);
  assert.deepEqual(top.folders.map((f) => [f.path, f.count]), [['Home', 2]]);
  assert.deepEqual([top.total, top.matchedTotal, top.unfilteredTotal, ids(top)], [0, 2, 4, []]);
  assert.equal(LanLibrary.list(nested, {}).facets.colour.red, 2, 'and with nothing chosen the row is not greyed');
  const home = LanLibrary.list(nested, { folder: 'Home', colour: 'red' });
  assert.deepEqual([ids(home), home.matchedTotal, home.folders.map((f) => f.count)], [['h1'], 2, [1]]);

  // Choosing Blue does not zero the other colours; it narrows the TYPE counts.
  const blue = LanLibrary.list(FILTERED, { colour: 'blue' }).facets;
  assert.deepEqual(blue.colour, none.colour);
  assert.deepEqual(blue.type, { '3mf': 1, stl: 0, step: 0, obj: 0, gcode: 1, other: 0, nofile: 0 });
  // And 3MF narrows the COLOUR counts, not its own.
  const threeMF = LanLibrary.list(FILTERED, { type: '3mf' }).facets;
  assert.deepEqual(threeMF.type, none.type);
  assert.equal(threeMF.colour.blue, 1);
  assert.equal(threeMF.colour.none, 0);
  // Both chosen: each still counted without itself.
  const both = LanLibrary.list(FILTERED, { colour: 'blue', type: '3mf' }).facets;
  assert.deepEqual(both.colour, threeMF.colour);
  assert.deepEqual(both.type, blue.type);
  // An empty library still names every row.
  assert.equal(Object.keys(LanLibrary.list([], {}).facets.colour).length, ColourFamily.TOKENS.length);
});
