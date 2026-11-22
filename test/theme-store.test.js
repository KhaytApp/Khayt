const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');

const S = require('../lib/theme-store.js');
const { inspectPackage } = require('../lib/theme-package.js');

const UD = '/Users/someone/Library/Application Support/khayt';
const ROOT = path.join(UD, 'themes');

const bundle = (over = {}) => JSON.stringify({
  manifest: { id: 'my-shop', name: 'My Shop', tokens: 'tokens.css', ...(over.manifest || {}) },
  files: { 'tokens.css': ':root{--accent:#0af}', ...(over.files || {}) },
});

test('a theme cannot be written outside its own folder', () => {
  // The check the whole design rests on. Everything else is convenience.
  assert.equal(S.isInsideRoot(ROOT, path.join(ROOT, 'ok')), true);
  assert.equal(S.isInsideRoot(ROOT, path.join(ROOT, 'a', 'b')), true);

  assert.equal(S.isInsideRoot(ROOT, ROOT), false, 'the root is not inside itself');
  assert.equal(S.isInsideRoot(ROOT, path.join(ROOT, '..', 'store.json')), false);
  assert.equal(S.isInsideRoot(ROOT, '/etc/passwd'), false);
  // A sibling whose name merely starts the same way. A prefix test alone passes
  // this and it must not: /…/themes-evil is not inside /…/themes.
  assert.equal(S.isInsideRoot(ROOT, `${ROOT}-evil/x`), false);
  for (const junk of [null, undefined, '', 42, {}]) {
    assert.equal(S.isInsideRoot(ROOT, junk), false);
    assert.equal(S.isInsideRoot(junk, ROOT), false);
  }
});

test('ids that could become paths are refused before they become paths', () => {
  for (const bad of ['../evil', 'a/b', '.', '..', '', 'A-Shop', '1shop', 'x', 'has space',
    'x'.repeat(33), '.hidden', 'sh\u0000op', null, undefined, 42]) {
    assert.equal(S.isValidId(bad), false, JSON.stringify(bad));
    assert.equal(S.themeDir(UD, bad), null, JSON.stringify(bad));
  }
  assert.equal(S.isValidId('my-shop'), true);
  assert.equal(S.themeDir(UD, 'my-shop'), path.join(ROOT, 'my-shop'));
});

test('a theme may not take the name of one Khayt ships', () => {
  // Otherwise installing a "nocturne" is indistinguishable from replacing it,
  // and the owner has no way to tell which one they are looking at.
  for (const id of ['workbench', 'nocturne', 'flow', 'meridian', 'default', 'base', 'custom']) {
    assert.equal(S.isValidId(id), false, id);
    const r = S.parseBundle(bundle({ manifest: { id } }));
    assert.equal(r.ok, false);
    assert.match(r.error, /already ships/);
  }
});

test('one JSON file, because an archive would mean owning zip-slip', () => {
  const r = S.parseBundle(bundle());
  assert.equal(r.ok, true);
  assert.equal(r.manifest.id, 'my-shop');
  assert.deepEqual(Object.keys(r.files), ['tokens.css']);

  // JSON has no notion of a path, so the traversal cases that would matter in an
  // archive arrive here as ordinary strings and are checked as filenames later.
  const nasty = S.parseBundle(JSON.stringify({
    manifest: { id: 'my-shop', name: 'X', tokens: 'tokens.css' },
    files: { '../../../../etc/cron.d/x': 'boom', 'tokens.css': 'a{}' },
  }));
  assert.equal(nasty.ok, true, 'parsing is shape-only; the plan is where this dies');
  assert.equal(S.planInstall(UD, nasty.manifest, nasty.files), null, 'and it does die there');
});

test('bad files are refused with something a person can act on', () => {
  const cases = [
    ['', /empty/i],
    ['not json at all', /not valid JSON/i],
    ['[]', /not a Khayt theme/i],
    ['{"files":{}}', /no manifest/i],
    ['{"manifest":{"id":"my-shop"}}', /no stylesheet/i],
    ['{"manifest":{"id":"BAD"},"files":{}}', /lowercase/i],
    ['{"manifest":{"id":"my-shop"},"files":{"a.css":5}}', /not text/i],
  ];
  for (const [text, re] of cases) {
    const r = S.parseBundle(text);
    assert.equal(r.ok, false, text);
    assert.match(r.error, re, text);
    assert.ok(!/undefined|\[object/.test(r.error), `unhelpful message for ${text}`);
  }
  for (const junk of [null, undefined, 42, {}]) assert.equal(S.parseBundle(junk).ok, false);
});

test('the install plan writes only inside the theme folder', () => {
  const { manifest, files } = S.parseBundle(bundle({ files: { 'compat.css': 'a{}' } }));
  const plan = S.planInstall(UD, { ...manifest, compat: 'compat.css' }, files);
  const dir = path.join(ROOT, 'my-shop');

  assert.equal(plan.dir, dir);
  assert.deepEqual(plan.writes.map((w) => w.path).sort(), [
    path.join(dir, 'compat.css'),
    path.join(dir, 'manifest.json'),
    path.join(dir, 'tokens.css'),
  ]);
  for (const w of plan.writes) {
    assert.equal(path.dirname(w.path), dir, `${w.path} escapes the folder`);
  }
  // The manifest is written back as it was accepted, so what runs later is what
  // was checked now — not whatever the file on disk becomes.
  const written = JSON.parse(plan.writes.find((w) => w.path.endsWith('manifest.json')).contents);
  assert.equal(written.id, 'my-shop');
});

test('a filename that is a path is refused however it is spelled', () => {
  const manifest = { id: 'my-shop', name: 'X', tokens: 'tokens.css' };
  for (const name of ['../x.css', 'a/b.css', '/abs.css', './x.css', '..']) {
    assert.equal(S.planInstall(UD, manifest, { [name]: 'a{}' }), null, name);
  }
  assert.equal(S.planInstall(UD, { ...manifest, id: '../evil' }, {}), null);
  assert.equal(S.planInstall('', manifest, {}), null);
});

test('the storage layer and the safety gate agree about a good theme', () => {
  // Two modules, one contract: parse decides the shape, inspect decides the
  // content, and a theme has to satisfy both. If these ever disagree, a file is
  // installable and unusable or the reverse.
  const parsed = S.parseBundle(bundle());
  assert.equal(parsed.ok, true);
  const judged = inspectPackage({ manifest: parsed.manifest, files: parsed.files });
  assert.equal(judged.ok, true, JSON.stringify(judged.problems));
  assert.ok(S.planInstall(UD, parsed.manifest, parsed.files));

  // And about a bad one: shape fine, content not.
  const evil = S.parseBundle(bundle({ files: { 'tokens.css': 'a{background:url(https://e/x)}' } }));
  assert.equal(evil.ok, true, 'the shape is fine');
  assert.equal(inspectPackage({ manifest: evil.manifest, files: evil.files }).ok, false, 'the content is not');
});

test('a broken installed theme is listed as broken, not hidden', () => {
  // A theme the app pretends is absent is a theme the owner cannot remove
  // through the app.
  const ok = S.describeInstalled('my-shop', { name: 'My Shop', version: 2, author: 'Sam' }, []);
  assert.deepEqual(ok, { id: 'my-shop', name: 'My Shop', version: 2, author: 'Sam', installed: true, broken: false, problems: [] });

  const bad = S.describeInstalled('rusty', null, [{ id: 'x', why: 'manifest.json will not parse' }]);
  assert.equal(bad.broken, true);
  assert.equal(bad.name, 'rusty', 'falls back to the folder name so it can still be named in the UI');
  assert.equal(bad.problems.length, 1);
});

test('end to end, on a real directory', async () => {
  // The pure tests prove the plan. This proves the plan survives contact with a
  // filesystem — that the writes land where they were planned and nowhere else.
  const os = require('os');
  const fs = require('fs');
  const ud = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-themes-'));
  const Pkg = require('../lib/theme-package.js');

  const text = JSON.stringify({
    manifest: { id: 'bench-dark', name: 'Bench Dark', version: 1, author: 'Turki', tokens: 'tokens.css', compat: 'compat.css' },
    files: { 'tokens.css': ':root{--accent:#0af}', 'compat.css': '.khayt-card{border-radius:2px}' },
  });

  const parsed = S.parseBundle(text);
  assert.equal(parsed.ok, true, parsed.error);
  assert.equal(Pkg.inspectPackage({ manifest: parsed.manifest, files: parsed.files }).ok, true);

  const plan = S.planInstall(ud, parsed.manifest, parsed.files);
  fs.mkdirSync(plan.dir, { recursive: true });
  for (const w of plan.writes) fs.writeFileSync(w.path, w.contents, 'utf8');

  // Exactly three files, all inside the theme's own folder.
  const dir = path.join(ud, 'themes', 'bench-dark');
  assert.deepEqual(fs.readdirSync(dir).sort(), ['compat.css', 'manifest.json', 'tokens.css']);
  // Nothing outside it.
  assert.deepEqual(fs.readdirSync(path.join(ud, 'themes')), ['bench-dark']);
  assert.deepEqual(fs.readdirSync(ud), ['themes']);

  // What was written is what was checked.
  const back = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
  assert.equal(back.id, 'bench-dark');
  assert.equal(fs.readFileSync(path.join(dir, 'tokens.css'), 'utf8'), ':root{--accent:#0af}');

  // And it survives being listed.
  const listed = S.describeInstalled('bench-dark', back, []);
  assert.equal(listed.name, 'Bench Dark');
  assert.equal(listed.broken, false);

  fs.rmSync(ud, { recursive: true, force: true });
});

test('the IPC refuses what the pure layer refuses', () => {
  // The handlers must not have their own, weaker, opinion. Read from source
  // rather than asserted about, because the risk is a handler that forgets to
  // call one of these rather than one that calls it wrongly.
  const fs = require('fs');
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const block = src.slice(src.indexOf('/* ── Installed themes'), src.indexOf("ipcMain.handle('hub:relocate-printers'"));

  assert.ok(block.includes('Store.parseBundle'), 'shape is checked');
  assert.ok(block.includes('Pkg.inspectPackage'), 'content is checked');
  assert.ok(block.includes('Store.planInstall'), 'paths come from the confined planner');
  // The order matters: nothing may be written before the CSS has been judged.
  assert.ok(block.indexOf('Pkg.inspectPackage') < block.indexOf('Store.planInstall'),
    'the CSS is judged before any path is planned');
  assert.ok(block.indexOf('Store.planInstall') < block.indexOf('writeFile'),
    'nothing is written before the plan exists');
  // Removal resolves through the same confinement rather than joining a path itself.
  const remove = block.slice(block.indexOf("hub:themes-remove"));
  assert.ok(remove.includes('Store.themeDir'), 'remove confines its path too');
  assert.ok(!/path\.join\([^)]*id/.test(remove), 'remove never builds a path from the id itself');
});
