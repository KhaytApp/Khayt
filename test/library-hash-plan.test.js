'use strict';
/**
 * Library Health's duplicate check: which models are hashed (lib/library-hash-plan.js),
 * how (lib/main/stream-hash.js, the same digest as lib/model-identity.js), and that the
 * window writes contentHash and nothing else — and that no duplicate group offers a
 * delete of its own (the Sep 27 hidden-selection incident: deletes stay explicit).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const P = require('../lib/library-hash-plan.js');
const { hashFile } = require('../lib/main/stream-hash.js');
const { contentHash } = require('../lib/model-identity.js');

const here = (id, size, extra) => Object.assign({ id, filename: id + '.stl', size, presence: 'here', addedAt: 0 }, extra);

test('plans only unhashed models whose bytes are on this computer, newest first', () => {
  const out = P.plan([
    here('old', 10, { addedAt: 1 }),
    here('new', 10, { addedAt: 9 }),
    here('hashed', 10, { contentHash: 'a'.repeat(64) }),
    here('archived', 10, { archived: true }),
    here('online', 10, { presence: 'online' }),
    here('missing', 10, { presence: 'missing' }),
    here('linked', 10, { linked: true }),
    here('big', P.MAX_FILE_BYTES + 1),
    here('empty', 0),
    { id: 'nofile', presence: 'here', size: 5 },
    here('new', 10, { addedAt: 9 }),   // listed twice: planned once
    null,
  ]);
  assert.deepEqual(out.todo.map((t) => t.id), ['new', 'old']);
  assert.deepEqual(out.skipped, { tooBig: 1, notHere: 2, linked: 1 });
  assert.equal(out.later, 0);
});

test('a run is capped by files and by bytes; the rest is counted for next time', () => {
  const many = Array.from({ length: 7 }, (_, i) => here('m' + i, 100, { addedAt: i }));
  const byFiles = P.plan(many, { maxFiles: 3 });
  assert.deepEqual(byFiles.todo.map((t) => t.id), ['m6', 'm5', 'm4']);
  assert.equal(byFiles.later, 4);
  const byBytes = P.plan(many, { maxBytes: 250 });
  assert.equal(byBytes.todo.length, 2);
  assert.equal(byBytes.later, 5);
});

test('resumable: once a model has its hash it is never planned again', () => {
  const lib = [here('a', 5, { addedAt: 2 }), here('b', 5, { addedAt: 1 })];
  const first = P.plan(lib, { maxFiles: 1 });
  assert.deepEqual(first.todo.map((t) => t.id), ['a']);
  lib[0].contentHash = 'b'.repeat(64);       // the stopped run had done this one
  assert.deepEqual(P.plan(lib).todo.map((t) => t.id), ['b']);
});

test('patchFor writes contentHash only, and only onto the file that was read and an unhashed record', () => {
  const h = 'c'.repeat(64);
  const rec = { id: 'a', name: 'Bracket', sourceFile: { filename: 'a.stl' } };
  assert.deepEqual(P.patchFor(rec, { contentHash: h, filename: 'a.stl' }), { contentHash: h });
  assert.equal(P.patchFor(rec, { contentHash: h, filename: 'other.stl' }), null, 'the file changed meanwhile');
  assert.equal(P.patchFor(Object.assign({}, rec, { contentHash: 'd'.repeat(64) }), { contentHash: h, filename: 'a.stl' }), null);
  assert.equal(P.patchFor(rec, { contentHash: 'NOT-HEX', filename: 'a.stl' }), null);
  assert.equal(P.patchFor(null, { contentHash: h, filename: 'a.stl' }), null);
});

test('the streamed hash is model-identity\'s contentHash, chunk boundaries and all', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-hash-'));
  try {
    const big = Buffer.alloc((9 << 20) + 123);     // over two 4 MB chunks
    for (let i = 0; i < big.length; i++) big[i] = (i * 31 + 7) & 0xff;
    const f = path.join(dir, 'model.stl');
    fs.writeFileSync(f, big);
    const r = await hashFile(f);
    assert.deepEqual(r, { ok: true, contentHash: contentHash(big), size: big.length });
    // A renamed copy is the same file.
    fs.copyFileSync(f, path.join(dir, 'renamed copy.stl'));
    assert.equal((await hashFile(path.join(dir, 'renamed copy.stl'))).contentHash, r.contentHash);

    fs.writeFileSync(path.join(dir, 'empty.stl'), '');
    assert.deepEqual(await hashFile(path.join(dir, 'empty.stl')), { ok: false, error: 'empty' });
    assert.deepEqual(await hashFile(f, { maxBytes: 1024 }), { ok: false, error: 'too-big' });
    assert.deepEqual(await hashFile(dir), { ok: false, error: 'not-a-file' });
    assert.deepEqual(await hashFile(path.join(dir, 'nope.stl')), { ok: false, error: 'unreadable' });
    const ctl = new AbortController(); ctl.abort();
    assert.deepEqual(await hashFile(f, { signal: ctl.signal }), { ok: false, error: 'aborted' });
    const late = new AbortController();
    const p = hashFile(f, { signal: late.signal });
    late.abort();
    assert.equal((await p).error, 'aborted', 'Stop stops the file being read');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('the main process reads only inside the library, never a placeholder, never over the cap', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const body = src.slice(src.indexOf("ipcMain.handle('hub:printlib-hash'"), src.indexOf("ipcMain.handle('hub:printlib-hash-stop'"));
  assert.match(body, /path\.basename\(String\(filename/);
  assert.match(body, /PLT\.isSidecar\(name\) \|\| PLT\.isOnlineMarker\(name\)/);
  assert.match(body, /if \(!printLibContains\(full\)\)/);
  assert.match(body, /maxBytes: PRINT_FILE_MAX_BYTES/);
});

test('the window writes contentHash and nothing else, and saves as it goes', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'printfiles.js'), 'utf8');
  const body = src.slice(src.indexOf('async function runHashCheck('), src.indexOf('function stopHashCheck('));
  const writes = body.match(/rec\.[A-Za-z]+ =/g) || [];
  assert.deepEqual(writes.sort(), ['rec.contentHash =', 'rec.updatedAt =']);
  assert.match(body, /HP\.patchFor\(rec,/);
  assert.match(body, /if \(unsaved\) saveAll\(\);/);
  assert.doesNotMatch(body, /delete|remove|splice|archive/i);
});

test('no Library Health group, duplicates included, offers a delete of its own', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'printfiles.js'), 'utf8');
  const start = src.indexOf('function hashLineHtml(');
  const end = src.indexOf('function showHealthGroup(');
  assert.ok(start > 0 && end > start);
  const health = src.slice(start, end);
  const acts = (health.match(/data-act="([^"]+)"/g) || []).map((a) => a.slice(10, -1));
  assert.ok(acts.includes('pf-health-show'));
  for (const a of acts) assert.doesNotMatch(a, /del|remove|trash|merge|archive/i, `${a} in Library Health`);
});

test('both entry points load the plan', () => {
  for (const f of ['index.html', 'bedready.html']) {
    const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');
    assert.match(html, /<script src="\.\.\/lib\/library-hash-plan\.js"><\/script>/, f);
  }
});
