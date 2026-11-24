'use strict';
/**
 * Bed Ready under "Make no internet calls": a blocked call sends NOTHING.
 *
 * Bed Ready's window cannot reach the internet itself (its CSP is
 * default-src 'self'; its only fetches are files inside the app), so every
 * call it makes goes through main, and main's gate is the same in both
 * flavours (main.js sets lib/outbound-hook.js once). The wiring test in
 * outbound-gate.test.js proves each of these files SAYS ask('makerrun') /
 * ask('catalogues'); this proves the asking happens before anything leaves:
 * no fetch, and no DNS lookup either. A lookup is a call out, and
 * makerrun-library's download guard used to resolve the design's host
 * before asking the gate (~/Khayt-proposals/bedready-outbound-audit.md).
 *
 * The gate here is the real one (lib/main/outbound-fetch.js) reading a book
 * whose switch is on, not a stub that always throws.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const dns = require('dns');

const { createOutboundGate } = require('../lib/main/outbound-fetch.js');
const Hook = require('../lib/outbound-hook.js');
const library = require('../lib/makerrun-library.js');
const account = require('../lib/makerrun-account.js');
const v1 = require('../lib/makerrun-v1.js');
const catalog = require('../lib/makerrun-catalog.js');
const publish = require('../lib/makerrun-publish.js');
const orca = require('../lib/orca-filament-install.js');
const TERMS = require('../lib/makerrun-terms.js');

/** Run fn with the switch on, counting every fetch and every DNS lookup. */
/** The gate as main.js builds it, `lookup` included (a `lan` answer resolves the name), read at call time. */
const mainLikeGate = (network) => createOutboundGate({
  getSettings: () => ({ network }), readLocal: () => ({}),
  lookup: (host) => dns.promises.lookup(host, { all: true, verbatim: true }),
});

async function offline(fn) {
  const sent = { fetch: [], dns: [] };
  const gate = mainLikeGate({ offline: true });
  const realFetch = globalThis.fetch;
  const realLookup = dns.promises.lookup;
  globalThis.fetch = async (url) => { sent.fetch.push(String(url)); throw new Error('a blocked call reached fetch'); };
  dns.promises.lookup = async (host) => { sent.dns.push(String(host)); throw new Error('a blocked call reached DNS'); };
  Hook.setOutboundGate((purpose, url) => gate.gateFor(purpose, url));
  // Each test file runs in its own process, and nothing else sets the hook here.
  try { await fn(gate); } finally {
    Hook.setOutboundGate(null);
    globalThis.fetch = realFetch;
    dns.promises.lookup = realLookup;
  }
  return sent;
}

async function refused(promise, purpose) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, 'outbound.blocked', String(e && e.message));
    assert.equal(e.purpose, purpose);
    assert.equal(e.reason, 'offline');
    return true;
  });
}

test('MakerRun library: sync, download and covers send nothing while offline', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'br-outbound-'));
  try {
    const sent = await offline(async () => {
      await refused(library.fetchLibrary('tok'), 'makerrun');
      await refused(library.syncLibrary('tok', { state: {} }), 'makerrun');
      // A hostname, not an IP literal: before the fix this one was looked up first.
      await refused(library.downloadItem({ slug: 's', title: 't', downloadUrl: 'https://files.example.com/a.3mf' }, dir), 'makerrun');
      await refused(library.fetchCoverDataUrl('https://covers.example.com/c.png'), 'makerrun');
    });
    assert.deepEqual(sent, { fetch: [], dns: [] });
    assert.deepEqual(fs.readdirSync(dir), [], 'nothing written');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('MakerRun catalogue and publishing (lib/makerrun-v1) send nothing while offline', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'br-outbound-'));
  try {
    const sent = await offline(async () => {
      await refused(v1.request('GET', '/designs'), 'makerrun');
      await refused(catalog.listDesigns({}), 'makerrun');
      await refused(catalog.getDesign('a-design'), 'makerrun');
      await refused(catalog.downloadDesignFile('tok', { slug: 'a-design', filename: 'a.3mf' }, dir), 'makerrun');
      await refused(publish.createDesign('tok', { title: 'A design', category: TERMS.CATEGORY_VALUES[0], license: TERMS.LICENCES[0] }), 'makerrun');
    });
    assert.deepEqual(sent, { fetch: [], dns: [] });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('MakerRun account: a refresh the switch blocks sends nothing and keeps the link', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'br-outbound-'));
  try {
    assert.ok(account.link(dir, { access: 'old', refresh: 'r1', expires: 1 }));   // long expired: must refresh
    const sent = await offline(async () => {
      await refused(account.getAccessToken(dir), 'makerrun');
    });
    assert.deepEqual(sent, { fetch: [], dns: [] });
    assert.equal(account.isLinked(dir), true, 'offline is not a dead link: no reconnect asked for');
    assert.equal(account.read(dir).refresh, 'r1', 'the refresh token was not spent');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('Filament library (bedready.io catalogue) sends nothing while offline', async () => {
  const sent = await offline(async () => {
    await refused(orca.fetchManifest(), 'catalogues');
  });
  assert.deepEqual(sent, { fetch: [], dns: [] });
});

test('kept while offline: the same calls are let through, so the test above is the switch and not a broken client', async () => {
  const gate = createOutboundGate({ getSettings: () => ({ network: { offline: true, keep: ['makerrun'] } }), readLocal: () => ({}) });
  const realFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (url) => { seen.push(String(url)); return { ok: true, status: 200, headers: { get: () => null }, json: async () => ({ items: [] }) }; };
  Hook.setOutboundGate((purpose, url) => gate.gateFor(purpose, url));
  try {
    await library.fetchLibrary('tok');
  } finally { Hook.setOutboundGate(null); globalThis.fetch = realFetch; }
  assert.equal(seen.length, 1);
  assert.match(seen[0], /\/api\/library$/);
});

test('a design URL on the LAN, or malformed, is refused by its text: no gate, no DNS, nothing counted as blocked (review of #2689)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'br-outbound-'));
  try {
    let gate;
    const sent = await offline(async (g) => {
      gate = g;
      for (const [url, words] of [
        ['https://files/a.3mf', /private\/internal/],          // a single-label name: resolved by a search domain
        ['https://nas.local/a.3mf', /private\/internal/],
        ['https://10.0.0.5/a.3mf', /private\/internal/],
        ['https://localhost/a.3mf', /private\/internal/],
        ['http://files.example.com/a.3mf', /non-HTTPS/],
        ['not a url', /invalid download URL/],
      ]) {
        await assert.rejects(library.downloadItem({ slug: 's', title: 't', downloadUrl: url }, dir), (e) => {
          assert.notEqual(e.code, 'outbound.blocked', url);
          assert.match(e.message, words, url);
          return true;
        });
      }
      await assert.rejects(library.fetchCoverDataUrl('https://printer.lan/c.png'), /private\/internal/);
    });
    assert.deepEqual(sent, { fetch: [], dns: [] });
    assert.equal((gate.blocked().makerrun || { count: 0 }).count, 0, 'a call that could never be made is not a blocked call');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('kept while offline, the download path itself goes out: the shape check, the gate, DNS, then fetch', async () => {
  const gate = mainLikeGate({ offline: true, keep: ['makerrun'] });
  const order = [];
  const realFetch = globalThis.fetch;
  const realLookup = dns.promises.lookup;
  dns.promises.lookup = async (host) => { order.push('dns ' + host); return [{ address: '93.184.216.34', family: 4 }]; };
  globalThis.fetch = async (url) => {
    order.push('fetch ' + new URL(String(url)).hostname);
    const png = new Uint8Array([137, 80, 78, 71]);
    return { ok: true, status: 200, headers: { get: (k) => (/content-type/i.test(k) ? 'image/png' : null) }, arrayBuffer: async () => png.buffer };
  };
  Hook.setOutboundGate((purpose, url) => gate.gateFor(purpose, url));
  try {
    const data = await library.fetchCoverDataUrl('https://covers.example.com/c.png');
    assert.match(data, /^data:image\/png;base64,/);
  } finally { Hook.setOutboundGate(null); globalThis.fetch = realFetch; dns.promises.lookup = realLookup; }
  assert.deepEqual(order, ['dns covers.example.com', 'fetch covers.example.com']);
});
