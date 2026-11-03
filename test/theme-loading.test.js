const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

/** The renderer's theme registry, loaded outside a browser. */
function registry() {
  const ctx = { console, document: undefined };
  ctx.globalThis = ctx; ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(read('renderer/themes/registry-core.js'), ctx);
  return ctx.KhaytThemeRegistry;
}

const MANIFEST = { id: 'bench-dark', name: 'Bench Dark', tokens: 'tokens.css' };

test('a theme with no URL still registers, and carries its CSS as text', () => {
  const reg = registry();
  const css = [{ name: 'tokens.css', text: ':root{--accent:#0af}' }];
  const r = reg.registerCustomTheme(MANIFEST, null, css);
  assert.equal(r.ok, true, JSON.stringify(r.errors));

  const theme = reg.getTheme('custom:bench-dark') || reg.getTheme('bench-dark');
  assert.ok(theme, 'registered');
  assert.deepEqual(Array.from(theme.stylesheets), [], 'nothing to link — userData has no fetchable URL');
  assert.equal(JSON.stringify(theme.inlineCss), JSON.stringify(css), 'the CSS travels with it instead');
});

test('a bundled theme still links, exactly as before', () => {
  // The developer route must not regress: this is how a theme gets written.
  const reg = registry();
  reg.registerCustomTheme({ ...MANIFEST, compat: 'compat.css' }, 'themes/custom');
  const theme = reg.getTheme('custom:bench-dark') || reg.getTheme('bench-dark');
  assert.deepEqual(Array.from(theme.stylesheets), [
    'themes/custom/bench-dark/tokens.css',
    'themes/custom/bench-dark/compat.css',
  ]);
  assert.equal(theme.inlineCss, null);
});

test('injected CSS uses textContent, which cannot end the element', () => {
  // The single line the safety of injection rests on. innerHTML would let
  // `</style><script>` out of the stylesheet; textContent cannot, whatever the
  // string says. lib/theme-package.js refuses that construct twice as well, so
  // this is the third independent reason it does not work.
  const src = read('renderer/themes.js');
  const region = src.slice(src.indexOf('function loadCustomThemeStyles'), src.indexOf('function isBedReady'));
  // Comments stripped: the code explains why it does not use innerHTML, and
  // asserting over prose would forbid writing that down — which is the opposite
  // of what this repo does.
  const fn = region.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  assert.ok(/createElement\('style'\)/.test(fn), 'inline CSS becomes a <style> element');
  assert.ok(/\.textContent\s*=\s*sheet\.text/.test(fn), 'set via textContent');
  assert.ok(!/innerHTML/.test(fn), 'never innerHTML');
});

test('unloading removes injected styles as well as linked ones', () => {
  // It selected link[...] only. A theme switched away from would have left its
  // <style> behind, so every design tried in one session would still be applied.
  const src = read('renderer/themes.js');
  const fn = src.slice(src.indexOf('function unloadCustomThemeStyles'), src.indexOf('function loadCustomThemeStyles'));
  assert.ok(/querySelectorAll\('\[data-khayt-theme-pack="custom"\]'\)/.test(fn),
    'matches any element carrying the marker, not just <link>');
});

test('an inline-only theme is not skipped by the empty-stylesheets guard', () => {
  const src = read('renderer/themes.js');
  const fn = src.slice(src.indexOf('function loadCustomThemeStyles'), src.indexOf('function isBedReady'));
  assert.ok(/inlineCss\?\.length/.test(fn), 'the early return accounts for inline-only themes');
});

test('the read handler judges the CSS again, every time', () => {
  // Install-time approval describes the file that arrived, not the file now.
  // userData is a directory the owner can open and anything running as that user
  // can write to, so loading on the old verdict is trust-on-first-use.
  const src = read('main.js');
  const h = src.slice(src.indexOf("ipcMain.handle('hub:themes-read'"), src.indexOf("ipcMain.handle('hub:themes-remove'"));
  assert.ok(h.includes('Pkg.inspectPackage'), 're-inspected on read');
  assert.ok(h.indexOf('Pkg.inspectPackage') < h.indexOf('return {\n    ok: true'), 'before anything is returned');
  assert.ok(h.includes('changedSinceInstall'), 'and says so, rather than failing vaguely');
  // Paths still come from the confined helpers, not built here.
  assert.ok(h.includes('Store.themeDir'), 'directory resolved by the store');
  assert.ok(h.includes('Store.isInsideRoot'), 'each file confined');
  assert.ok(h.includes('Store.SAFE_FILENAME'), 'each name checked as a name');
});

test('the loader reads the API the preload actually exposes', () => {
  // It was written against `khaytAPI`, which does not exist — the loader would
  // have returned [] forever and looked like "no themes installed".
  const exposed = /exposeInMainWorld\('([^']+)'/.exec(read('preload.js'))[1];
  const loader = read('renderer/themes/custom-loader.js');
  assert.ok(loader.includes(`global.${exposed}`), `loader must use ${exposed}`);
  for (const fn of ['themesList', 'themesRead']) {
    assert.ok(read('preload.js').includes(fn), `${fn} exposed`);
    assert.ok(loader.includes(fn), `${fn} used`);
  }
});

test('a broken or refused theme costs a design, not the app', () => {
  const loader = read('renderer/themes/custom-loader.js');
  assert.ok(/if \(t\.broken\) continue/.test(loader), 'a broken theme is skipped, not applied');
  assert.ok(/if \(!read \|\| !read\.ok\)/.test(loader), 'a refused read is skipped');
  // Both loaders are wrapped: this runs during boot and an exception would take
  // the renderer down over somebody else's stylesheet.
  assert.equal((loader.match(/catch \(e\)/g) || []).length, 2, 'both paths catch');
});

test('the whole chain agrees: install, store, read, register', () => {
  const Store = require('../lib/theme-store.js');
  const Pkg = require('../lib/theme-package.js');
  const os = require('os');

  const ud = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-load-'));
  const text = JSON.stringify({ manifest: MANIFEST, files: { 'tokens.css': ':root{--accent:#0af}' } });

  const parsed = Store.parseBundle(text);
  assert.equal(parsed.ok, true);
  assert.equal(Pkg.inspectPackage({ manifest: parsed.manifest, files: parsed.files }).ok, true);

  const plan = Store.planInstall(ud, parsed.manifest, parsed.files);
  fs.mkdirSync(plan.dir, { recursive: true });
  for (const w of plan.writes) fs.writeFileSync(w.path, w.contents, 'utf8');

  // Now read it back the way the handler does, and re-judge.
  const manifest = JSON.parse(fs.readFileSync(path.join(plan.dir, 'manifest.json'), 'utf8'));
  const files = { 'tokens.css': fs.readFileSync(path.join(plan.dir, 'tokens.css'), 'utf8') };
  const judged = Pkg.inspectPackage({ manifest, files });
  assert.equal(judged.ok, true);

  const reg = registry();
  const r = reg.registerCustomTheme(manifest, null, judged.files.map((n) => ({ name: n, text: files[n] })));
  assert.equal(r.ok, true, JSON.stringify(r.errors));

  // And the edited-after-install case, which is the reason the read re-judges.
  fs.writeFileSync(path.join(plan.dir, 'tokens.css'), 'a{background:url(https://evil.example/x)}', 'utf8');
  const after = Pkg.inspectPackage({
    manifest,
    files: { 'tokens.css': fs.readFileSync(path.join(plan.dir, 'tokens.css'), 'utf8') },
  });
  assert.equal(after.ok, false, 'a theme edited on disk is refused on the next read');

  fs.rmSync(ud, { recursive: true, force: true });
});

/* ── The picker surface ──────────────────────────────────────────────────── */

const picker = () => read('renderer/themes/theme-picker.js');

test('installing never gives the renderer a filesystem path', () => {
  // The obvious build is "pick a file" then "read that file". The second half is
  // a general read-any-file capability handed to the renderer — far larger than
  // this feature needs, and once it exists every future renderer bug inherits
  // it. Picking, reading and installing happen in one main-process call instead.
  const p = picker();
  assert.ok(p.includes('themesInstallFile()'), 'one call does all three');
  assert.ok(!/readTextFile/.test(p), 'no general file-read capability is used');
  assert.ok(!/pickFile/.test(p), 'the renderer never receives a path');

  const pre = read('preload.js');
  assert.ok(pre.includes('hub:themes-install-file'));
  assert.ok(!/readTextFile/.test(pre), 'and none is exposed');

  const h = read('main.js');
  const fn = h.slice(h.indexOf("ipcMain.handle('hub:themes-install-file'"), h.indexOf("ipcMain.handle('hub:themes-read'"));
  assert.ok(fn.includes('showOpenDialog'), 'the dialog is opened in main');
  assert.ok(fn.includes('themeInstallFromText'), 'and hands straight to the shared install path');
  assert.ok(/stat\.size >/.test(fn), 'size is checked before the file is read into memory');
});

test('both install entry points run identical checks', () => {
  // Two doors into one room. If the file-picking one grew its own copy of the
  // logic, the checks would drift and the door people actually use would be the
  // one that relaxed.
  const h = read('main.js');
  assert.ok(/ipcMain\.handle\('hub:themes-install',[^;]*themeInstallFromText\(text\)\)/.test(h),
    'the text entry point delegates');
  assert.equal((h.match(/async function themeInstallFromText/g) || []).length, 1,
    'exactly one implementation');
});

test('a refusal reaches the person who can fix it', () => {
  // lib/theme-package.js reports every problem at once and names the file. That
  // is wasted if the UI replaces it with "could not install".
  const p = picker();
  assert.ok(/res && res\.error/.test(p), 'the real message is shown');
  assert.ok(/canceled/.test(p), 'cancelling is not an error');
  // …and rendered as text, not markup: the message quotes a stranger's CSS.
  assert.ok(/\.textContent\s*=\s*msg/.test(p), 'shown via textContent');
});

test('removing the design in use hands the app back to a built-in', () => {
  // Otherwise the app is left styled by a theme that no longer exists, which
  // reads as "the app broke when I deleted something".
  const p = picker();
  const remove = p.slice(p.indexOf('.themeRemove'), p.indexOf('function mountSettingsPicker'));
  assert.ok(/settings\.designTheme === `custom:\$\{id\}`/.test(remove), 'notices it was the active one');
  assert.ok(/settings\.designTheme = 'khayt'/.test(remove), 'falls back to a built-in');
  assert.ok(/saveAll/.test(remove), 'and persists that');
});

test('a broken design is listed, struck through, and still removable', () => {
  const p = picker();
  assert.ok(/is-broken/.test(p), 'marked in the markup');
  assert.ok(/theme\.design\.broken/.test(p), 'and explained in words');
  // The remove button is outside the broken branch, so it renders either way.
  const row = p.slice(p.indexOf('function installedRowHtml'), p.indexOf('async function renderInstalledSection'));
  assert.ok(/themeRemove/.test(row), 'every row can be removed, broken or not');

  const css = read('renderer/themes/theme-picker.css');
  assert.ok(/\.theme-installed-row\.is-broken/.test(css), 'and looks different');
});

test('every string the picker shows is translated', () => {
  // The locale parity gate proves the keys exist in all nine bundles. This
  // proves the picker uses keys at all rather than hard-coding English.
  const p = picker();
  const keys = [...p.matchAll(/tr\('(theme\.design\.[a-z_]+)'/g)].map((m) => m[1]);
  assert.ok(keys.length >= 8, `expected the picker to use locale keys, found ${keys.length}`);
  const en = read('renderer/locales/en.js');
  for (const k of new Set(keys)) {
    assert.ok(en.includes(`"${k}"`), `${k} missing from en.js`);
  }
});
