// "Save to Khayt": which finished download belongs to a page just saved
// (`extension-khayt/background.js` `matchDownload`), what the background
// sends for it, and which browser's manifest may ask for downloads at all.
//
// background.js is a classic script, so it is run here in a sandbox with a
// stand-in `chrome` that records what it is asked — no browser, no network,
// and no real native host.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const EXT = path.join(here, '..', 'extension-khayt');
const SWIFT = path.join(here, '..', 'mac', 'KhaytCore', 'Sources', 'KhaytWebSave', 'WebSave.swift');

/** background.js in a sandbox, with a fake extension API. */
function loadBackground({ downloads = true } = {}) {
  const listeners = {};
  const sent = [];
  const store = {};
  const on = (name) => ({ addListener: (f) => { listeners[name] = f; } });
  const chrome = {
    runtime: {
      onMessage: on('message'),
      sendNativeMessage: async (host, message) => { sent.push({ host, message }); return { ok: true, state: message.kind === 'save' ? 'saved' : 'offered' }; },
    },
    storage: { session: {
      get: async (k) => ({ [k]: store[k] }),
      set: async (o) => { Object.assign(store, o); },
    } },
    tabs: { query: async () => [{ id: 7 }] },
  };
  if (downloads) {
    chrome.downloads = {
      onCreated: on('created'), onChanged: on('changed'),
      search: async ({ id }) => [items.get(id)],
    };
  }
  const items = new Map();
  const context = vm.createContext({ chrome, URL, Date, console, Map, setTimeout });
  vm.runInContext(fs.readFileSync(path.join(EXT, 'background.js'), 'utf8'), context);
  return { context, listeners, sent, store, items };
}

const NOW = Date.parse('2026-10-25T12:00:00Z');
const SAVE = { url: 'https://www.printables.com/model/123456-dragon', files: ['https://files.printables.com/media/dragon.3mf'], tabId: 4, at: NOW - 60_000 };
const item = (o = {}) => ({
  id: 1, state: 'complete', exists: true, filename: '/Users/shop/Downloads/dragon.3mf',
  url: 'https://files.printables.com/media/dragon.3mf', referrer: 'https://www.printables.com/model/123456-dragon',
  startTime: new Date(NOW - 30_000).toISOString(), ...o,
});

test('a finished model download from the page just saved is matched — by tab, referrer, file link or site', () => {
  const { context: bg } = loadBackground();
  assert.equal(bg.matchDownload(item(), [SAVE], null, NOW), SAVE, 'the referrer is the page');
  assert.equal(bg.matchDownload(item({ referrer: '', url: 'https://cdn.example/x.3mf' }), [SAVE], 4, NOW), SAVE, 'the same tab');
  assert.equal(bg.matchDownload(item({ referrer: '' }), [SAVE], null, NOW), SAVE, 'one of the page’s file links');
  assert.equal(bg.matchDownload(item({ referrer: 'https://printables.com/model/123456-dragon/files', url: 'https://cdn.example/x.3mf' }), [SAVE], null, NOW), SAVE,
    'another page of the same site');
  assert.equal(bg.matchDownload(item({ referrer: 'https://www.printables.com/model/123456-dragon/?lang=en#files' }), [SAVE], null, NOW), SAVE,
    'the query and fragment do not make it another page');
});

test('not matched: unfinished, not a model, too late, too early, from somewhere else, or a relative path', () => {
  const { context: bg } = loadBackground();
  const other = { referrer: 'https://www.thingiverse.com/thing:1', url: 'https://cdn.example/x.3mf' };
  assert.equal(bg.matchDownload(item({ state: 'in_progress' }), [SAVE], null, NOW), null);
  assert.equal(bg.matchDownload(item({ exists: false }), [SAVE], null, NOW), null);
  assert.equal(bg.matchDownload(item({ filename: '/Users/shop/Downloads/invoice.pdf' }), [SAVE], null, NOW), null);
  assert.equal(bg.matchDownload(item({ filename: 'dragon.3mf' }), [SAVE], null, NOW), null);
  assert.equal(bg.matchDownload(item(), [SAVE], null, SAVE.at + 10 * 60_000 + 1), null, 'over ten minutes after the save');
  assert.equal(bg.matchDownload(item({ startTime: new Date(SAVE.at - 3 * 60_000).toISOString() }), [SAVE], null, NOW), null,
    'begun well before the save');
  assert.equal(bg.matchDownload(item(other), [SAVE], 9, NOW), null, 'another site, another tab');
  assert.equal(bg.matchDownload(item(), [], null, NOW), null, 'no save at all');
});

test('the newest save of the same site wins', () => {
  const { context: bg } = loadBackground();
  const older = { ...SAVE, url: 'https://www.printables.com/model/1-old', files: [], at: NOW - 5 * 60_000 };
  const newer = { ...SAVE, url: 'https://www.printables.com/model/2-new', files: [], at: NOW - 60_000 };
  const it = item({ referrer: 'https://www.printables.com/', url: 'https://cdn.example/x.stl', filename: '/Users/s/Downloads/x.stl' });
  assert.equal(bg.matchDownload(it, [older, newer], null, NOW), newer);
  // But a download whose referrer IS the older page goes to that page, not to
  // the newer save on the same site.
  const fromOlder = item({ referrer: 'https://www.printables.com/model/1-old', url: 'https://cdn.example/y.stl',
    filename: '/Users/s/Downloads/y.stl' });
  assert.equal(bg.matchDownload(fromOlder, [older, newer], null, NOW), older);
});

test('end to end in the sandbox: a save is remembered, its download sends one attach, others send nothing', async () => {
  const { listeners, sent, store, items } = loadBackground();
  const page = { url: SAVE.url, title: 'Dragon', files: [{ url: SAVE.files[0], name: 'dragon.3mf' }] };
  const answer = await new Promise((done) => listeners.message({ type: 'khayt', message: { v: 1, kind: 'save', page }, tabId: 4 }, {}, done));
  assert.equal(answer.state, 'saved');
  assert.equal(store.saves.length, 1);
  assert.deepEqual(Object.keys(store.saves[0]).sort(), ['at', 'files', 'tabId', 'url'], 'only these are remembered');

  // A download from the page.
  items.set(1, item({ startTime: new Date().toISOString() }));
  await listeners.created({ id: 1 });
  await listeners.changed({ id: 1, state: { current: 'complete' } });
  // And one from nowhere near it.
  items.set(2, item({ id: 2, referrer: 'https://news.example/', url: 'https://news.example/a.stl', filename: '/Users/shop/Downloads/a.stl', startTime: new Date().toISOString() }));
  await listeners.changed({ id: 2, state: { current: 'complete' } });

  const attaches = sent.filter((s) => s.message.kind === 'attach');
  assert.equal(attaches.length, 1);
  assert.equal(attaches[0].host, 'app.khayt.mac');
  assert.deepEqual(JSON.parse(JSON.stringify(attaches[0].message)), { v: 1, kind: 'attach', attach: { page: SAVE.url, path: '/Users/shop/Downloads/dragon.3mf', name: 'dragon.3mf' } });
});

test('a message from a tab is not one of ours, and a browser without downloads loads the same script', async () => {
  const { listeners, sent } = loadBackground({ downloads: false });
  assert.equal(listeners.changed, undefined);
  assert.equal(listeners.message({ type: 'khayt', message: { v: 1, kind: 'ping' } }, { tab: { id: 1 } }, () => {}), false);
  assert.equal(sent.length, 0);
});

test('the model kinds are WebSave.modelKinds, word for word', () => {
  const { context: bg } = loadBackground();
  const swift = fs.readFileSync(SWIFT, 'utf8');
  const block = swift.slice(swift.indexOf('public static let modelKinds'), swift.indexOf(']', swift.indexOf('public static let modelKinds')));
  const kinds = [...block.matchAll(/"([a-z0-9]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual([...vm.runInContext('MODEL_KINDS', bg)].sort(), kinds);
});

test('downloads and storage: asked for by Chrome and Firefox, never by Safari', async () => {
  const { manifestFor, GECKO_ID } = await import(path.join(EXT, 'pack.mjs'));
  for (const b of ['chrome', 'firefox']) {
    const p = manifestFor(b).permissions;
    assert.ok(p.includes('downloads') && p.includes('storage'), b);
  }
  const safari = manifestFor('safari').permissions;
  assert.deepEqual([...safari].sort(), ['activeTab', 'nativeMessaging', 'scripting']);
  // The id the Mac's Firefox host manifest lets in (BrowserHosts.firefoxExtensionId).
  const hosts = fs.readFileSync(path.join(here, '..', 'mac', 'KhaytCore', 'Sources', 'KhaytWebSave', 'BrowserHosts.swift'), 'utf8');
  assert.equal(GECKO_ID, 'save@khaytapp.com');
  assert.ok(hosts.includes(`firefoxExtensionId = "${GECKO_ID}"`));
  assert.equal(manifestFor('firefox').browser_specific_settings.gecko.id, GECKO_ID);
  // The host name the background calls is the one the Mac writes manifests for.
  assert.ok(hosts.includes('hostName = "app.khayt.mac"'));
  assert.ok(fs.readFileSync(path.join(EXT, 'background.js'), 'utf8').includes("const HOST = 'app.khayt.mac'"));
});
