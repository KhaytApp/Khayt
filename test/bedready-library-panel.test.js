/**
 * Driving the Bed Ready library panel in a real DOM.
 *
 * lib/library-browse.js already proves which designs match a query. What this
 * covers is everything that only goes wrong once there IS a document: does
 * typing keep the caret, does a chip repaint the grid, and does a per-design
 * button send exactly one design to the bridge.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..');
const BROWSE = fs.readFileSync(path.join(ROOT, 'lib/library-browse.js'), 'utf8');
const PANEL = fs.readFileSync(path.join(ROOT, 'renderer/bedready-library.js'), 'utf8');

const ITEMS = [
  { title: 'Étagère bracket', slug: 'etagere-bracket', fileType: 'stl', downloadUrl: 'https://x/1' },
  { title: 'Vase spiral', slug: 'vase-spiral', fileType: '3mf', downloadUrl: 'https://x/2' },
  { title: 'bracket v2', slug: 'bracket-v2', fileType: 'stl', downloadUrl: 'https://x/3' },
  { title: 'Gear set', slug: 'gear-set', fileType: 'step' },   // link only
];

/** Boot the panel against a jsdom document with a recording bridge. */
async function boot({ items = ITEMS, canImport = true, folder = 'MakerRun-Library' } = {}) {
  const dom = new JSDOM('<!doctype html><html data-app="bedready"><body></body></html>',
    { pretendToBeVisual: true });
  const { window } = dom;
  const calls = { downloadAll: [], importToLib: [], imported: [] };

  window.hubAPI = {
    bedreadyLinked: async () => ({ ok: true, linked: true }),
    bedreadyLibrary: async () => ({ ok: true, items }),
    bedreadyDownloadAll: async (list) => {
      calls.downloadAll.push(list);
      // `folder` is what main actually wrote to — a shop that downloaded designs
      // before the MakerRun rename keeps its existing BedReady-Library folder.
      return { ok: true, folder, saved: list.map((i) => i.slug), failed: [], skipped: [] };
    },
    bedreadyImportToLib: canImport
      ? async (item, vaultId) => {
        calls.importToLib.push({ item, vaultId });
        return { ok: true, filename: 'f.3mf', ext: '3mf', size: 1 };
      }
      : undefined,
    bedreadyCover: async () => ({ ok: false }),
    bedreadyOpenSignIn: () => {},
    bedreadyUnlink: async () => ({ ok: true }),
  };
  if (canImport) window.importConvertedAsNew = async (rec) => { calls.imported.push(rec); };
  // English strings, so an assertion on visible text is an assertion on what a
  // user reads rather than on a key name.
  const strings = {};
  const locale = new vm.Script(fs.readFileSync(path.join(ROOT, 'renderer/locales/en.js'), 'utf8'));
  const lctx = vm.createContext({ globalThis: null });
  lctx.globalThis = lctx;
  locale.runInContext(lctx);
  Object.assign(strings, lctx.KhaytLocales.en);
  window.t = (key, vars) => {
    let s = strings[key] || key;
    if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
    return s;
  };

  const ctx = vm.createContext(window);
  vm.runInContext(BROWSE, ctx, { filename: 'library-browse.js' });
  vm.runInContext(PANEL, ctx, { filename: 'bedready-library.js' });

  window.BedReadyLibrary.open();
  await tick(window);
  // The panel opens on the "linked" view but only fills the grid after a sync.
  click(window, '.brl-btn[data-act="sync"]');
  await tick(window);
  return { window, calls, doc: window.document };
}

const tick = async (w) => { for (let i = 0; i < 6; i++) await new Promise((r) => w.setTimeout(r, 0)); };
const $ = (w, sel) => w.document.querySelector(sel);
const $$ = (w, sel) => Array.from(w.document.querySelectorAll(sel));
const click = (w, sel) => { const el = $(w, sel); assert.ok(el, `no element for ${sel}`); el.click(); };
const cardNames = (w) => $$(w, '.brl-card').map((c) => c.querySelector('div[title]').getAttribute('title'));

async function type(w, text) {
  const q = $(w, '.brl-q');
  q.focus();
  q.value = text;
  q.dispatchEvent(new w.Event('input', { bubbles: true }));
  await tick(w);
  return q;
}

test('the library renders as a grid of cards, one per design', async () => {
  const { window } = await boot();
  assert.equal($$(window, '.brl-card').length, 4);
  assert.deepEqual(cardNames(window).sort(), ['Gear set', 'Vase spiral', 'bracket v2', 'Étagère bracket'].sort());
});

test('typing filters the grid WITHOUT stealing the caret', async () => {
  // The whole reason the shell renders once and paint() updates in place. If a
  // keystroke re-rendered the panel, the <input> would be replaced mid-word and
  // the user would be typing into nothing.
  const { window } = await boot();
  const q = await type(window, 'bracket');
  assert.equal(window.document.activeElement, q, 'search box still focused');
  assert.equal(q.value, 'bracket', 'and still holds what was typed');
  assert.deepEqual(cardNames(window).sort(), ['bracket v2', 'Étagère bracket'].sort());

  // Typing more narrows further, still without losing focus.
  await type(window, 'bracket v2');
  assert.equal(window.document.activeElement, $(window, '.brl-q'));
  assert.deepEqual(cardNames(window), ['bracket v2']);
});

test('a search with no hits says so instead of showing an empty box', async () => {
  const { window } = await boot();
  await type(window, 'zzzz');
  assert.equal($$(window, '.brl-card').length, 0);
  assert.match($(window, '.brl-grid').textContent, /No designs match/);
});

test('the count reads "showing N of total" only while filtered', async () => {
  const { window } = await boot();
  assert.match($(window, '.brl-count').textContent, /4 saved designs/);
  await type(window, 'bracket');
  assert.match($(window, '.brl-count').textContent, /Showing 2 of 4/);
  await type(window, '');
  assert.match($(window, '.brl-count').textContent, /4 saved designs/);
});

test('a type chip toggles, and its count comes from the whole library', async () => {
  const { window } = await boot();
  const stl = $$(window, '.brl-chip').find((c) => c.textContent.startsWith('STL'));
  assert.ok(stl, 'an STL chip exists');
  assert.match(stl.textContent, /STL \(2\)/);

  stl.click();
  await tick(window);
  assert.equal(stl.getAttribute('aria-pressed'), 'true');
  assert.deepEqual(cardNames(window).sort(), ['bracket v2', 'Étagère bracket'].sort());
  // Still (2) — the chip must not renumber to match its own filter.
  assert.match(stl.textContent, /STL \(2\)/);

  stl.click();
  await tick(window);
  assert.equal(stl.getAttribute('aria-pressed'), 'false');
  assert.equal($$(window, '.brl-card').length, 4);
});

test('Clear resets the search box as well as the filters', async () => {
  // Emptying `view` but leaving text in the input would show all four designs
  // under a search box that still says "bracket".
  const { window } = await boot();
  await type(window, 'bracket');
  $$(window, '.brl-chip').find((c) => c.textContent.startsWith('STL')).click();
  await tick(window);
  assert.equal($$(window, '.brl-card').length, 2);

  $$(window, '.brl-chip').find((c) => c.textContent === 'Clear').click();
  await tick(window);
  assert.equal($(window, '.brl-q').value, '', 'the box is empty too');
  assert.equal($$(window, '.brl-card').length, 4);
});

test('Escape in a filled search box clears it rather than closing the panel', async () => {
  const { window } = await boot();
  const q = await type(window, 'bracket');
  q.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  await tick(window);
  assert.equal(q.value, '');
  assert.equal($$(window, '.brl-card').length, 4);
  assert.notEqual($(window, '.brl-overlay').style.display, 'none', 'panel still open');
});

test('a link-only design offers no download button', async () => {
  const { window } = await boot();
  const gear = $$(window, '.brl-card').find((c) => c.querySelector('div[title]').getAttribute('title') === 'Gear set');
  assert.equal(gear.querySelectorAll('.brl-one').length, 0);
  assert.match(gear.textContent, /link only/);
});

test('the per-design Download button sends exactly that design', async () => {
  const { window, calls } = await boot();
  const card = $$(window, '.brl-card').find((c) => c.querySelector('div[title]').getAttribute('title') === 'Vase spiral');
  card.querySelector('.brl-one[data-act="one-download"]').click();
  await tick(window);
  assert.equal(calls.downloadAll.length, 1);
  assert.equal(calls.downloadAll[0].length, 1, 'one design, not the whole library');
  assert.equal(calls.downloadAll[0][0].slug, 'vase-spiral');
  assert.match($(window, '.brl-result').textContent, /Vase spiral/);
});

test('the per-design Add button imports that design into Print Files', async () => {
  const { window, calls } = await boot();
  const card = $$(window, '.brl-card').find((c) => c.querySelector('div[title]').getAttribute('title') === 'bracket v2');
  card.querySelector('.brl-one[data-act="one-import"]').click();
  await tick(window);
  assert.equal(calls.importToLib.length, 1);
  assert.equal(calls.importToLib[0].item.slug, 'bracket-v2');
  assert.equal(calls.imported.length, 1);
  assert.equal(calls.imported[0].displayName, 'bracket v2');
  assert.equal(calls.imported[0].vaultId, calls.importToLib[0].vaultId, 'same vault id both sides');
});

test('with no import bridge, cards offer Download only', async () => {
  // An older/other build without importConvertedAsNew must not show a button
  // that cannot work.
  const { window } = await boot({ canImport: false });
  assert.equal($$(window, '.brl-one[data-act="one-import"]').length, 0);
  assert.ok($$(window, '.brl-one[data-act="one-download"]').length > 0);
});

test('"Download to folder" downloads what is on screen, not the whole library', async () => {
  // The button sits directly under a filtered grid. Sending all four designs
  // while three are hidden is not what it appears to do.
  const { window, calls } = await boot();
  await type(window, 'bracket');
  click(window, '.brl-btn[data-act="download"]');
  await tick(window);
  assert.equal(calls.downloadAll.length, 1);
  assert.deepEqual(calls.downloadAll[0].map((i) => i.slug).sort(), ['bracket-v2', 'etagere-bracket']);
});

test('"Add all" likewise follows the filter and skips link-only designs', async () => {
  const { window, calls } = await boot();
  const stl = $$(window, '.brl-chip').find((c) => c.textContent.startsWith('STL'));
  stl.click();
  await tick(window);
  click(window, '.brl-btn[data-act="import"]');
  await tick(window);
  assert.deepEqual(calls.importToLib.map((c) => c.item.slug).sort(), ['bracket-v2', 'etagere-bracket']);
});

test('a re-sync keeps the search box and the grid telling the same story', async () => {
  // Sync rebuilds the whole shell while `view` survives. If the box came back
  // empty, the user would see a filtered grid with no visible reason for the
  // missing designs.
  const { window } = await boot();
  await type(window, 'bracket');
  assert.equal($$(window, '.brl-card').length, 2);

  click(window, '.brl-btn[data-act="sync"]');
  await tick(window);
  assert.equal($(window, '.brl-q').value, 'bracket', 'the query is still shown');
  assert.equal($$(window, '.brl-card').length, 2, 'and still applied');

  // Chip counts still describe the whole library, not the two on screen.
  const stl = $$(window, '.brl-chip').find((c) => c.textContent.startsWith('STL'));
  assert.match(stl.textContent, /STL \(2\)/);
  const step = $$(window, '.brl-chip').find((c) => c.textContent.startsWith('STEP'));
  assert.ok(step, 'the STEP chip survives a re-sync even though nothing STEP matches the filter');
  assert.match(step.textContent, /STEP \(1\)/);
});

test('sorting reorders the grid', async () => {
  const { window } = await boot();
  const sort = $(window, '.brl-sort');
  assert.deepEqual(cardNames(window), ['bracket v2', 'Étagère bracket', 'Gear set', 'Vase spiral']);
  sort.value = 'name-desc';
  sort.dispatchEvent(new window.Event('change', { bubbles: true }));
  await tick(window);
  assert.deepEqual(cardNames(window), ['Vase spiral', 'Gear set', 'Étagère bracket', 'bracket v2']);
});

test('an empty library shows the hint and no controls', async () => {
  const { window } = await boot({ items: [] });
  assert.equal($$(window, '.brl-card').length, 0);
  assert.equal($(window, '.brl-q'), null, 'no search box over nothing');
  assert.match($(window, '.brl-result').textContent, /No saved designs yet/);
});

test('every design name is escaped, not injected', async () => {
  const { window } = await boot({
    items: [{ title: '<img src=x onerror=alert(1)>', slug: 'evil', fileType: 'stl', downloadUrl: 'https://x/1' }],
  });
  assert.equal($$(window, '.brl-card img[src="x"]').length, 0, 'no injected element');
  assert.equal(cardNames(window)[0], '<img src=x onerror=alert(1)>', 'shown as text');
});

test('the visible heading is the translated title, not a hardcoded name', async () => {
  // It used to be a hardcoded English "My BedReady library" next to an aria-label
  // built from t('brl.title'), so a translated build showed one name and announced
  // another — and only the announced one would have followed the MakerRun rename.
  const { window } = await boot();
  const modal = $(window, '.brl-modal');
  const heading = modal.querySelector('b').textContent;
  assert.equal(heading, 'MakerRun library');
  assert.equal(modal.getAttribute('aria-label'), heading, 'what is shown is what is announced');
});

test('the download message names the folder that was actually written to', async () => {
  // Not the folder this file thinks it should be. A shop that downloaded designs
  // before the rename keeps saving into Downloads/BedReady-Library, and a message
  // hardcoding either name would be wrong for half of them.
  const { window } = await boot({ folder: 'BedReady-Library' });
  click(window, '.brl-btn[data-act="download"]');
  await tick(window);
  assert.match($(window, '.brl-result').textContent, /Downloads\/BedReady-Library folder/);

  const fresh = await boot({ folder: 'MakerRun-Library' });
  click(fresh.window, '.brl-btn[data-act="download"]');
  await tick(fresh.window);
  assert.match($(fresh.window, '.brl-result').textContent, /Downloads\/MakerRun-Library folder/);
});
