/**
 * E2E smoke — a product actually accepts a photo.
 *
 * This exists because the multi-image editor shipped unable to accept a single
 * image, and every unit test passed. The handler read `e.target.files` and then
 * cleared the input:
 *
 *     const files = e.target.files; e.target.value = '';
 *
 * `files` is a LIVE FileList, not a snapshot, so clearing the input emptied the
 * collection before it was read. Picking a photo did nothing, silently, with no
 * console error. The single-slot code this replaced took `files[0]` first — a
 * real File reference — so clearing after was safe there and is not safe here.
 * Reported as "the catalogue won't accept images".
 *
 * Nothing short of putting a real file through a real <input type=file> could
 * have caught it: the module was correct, the wiring test found the listener,
 * and the bug lived in the one line between them.
 *
 * Run: npm run test:e2e:productimages
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

// A 2×2 PNG, written fresh so the suite carries no binary fixture.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQIAFtwCAxsBcJgAAAAASUVORK5CYII=',
  'base64');

const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-prodimg-'));
const shot = path.join(userData, 'part.png');
fs.writeFileSync(shot, PNG);

let app;
let failed = false;
try {
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_USER_DATA: userData },
    timeout: 120_000,
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('pageerror', (e) => errors.push('[pageerror] ' + String(e).slice(0, 300)));

  await page.waitForSelector('.khayt-app', { timeout: 60_000 });
  await page.waitForFunction(() => !!window.KhaytProductImages, { timeout: 40_000 });
  await page.waitForTimeout(1500);
  await page.evaluate(() => {
    document.querySelector('#setup-wizard')?.remove();
    if (typeof settings !== 'undefined' && settings) { settings.firstRun = false; settings.mode = 'professional'; }
  });

  await page.evaluate(() => openProductEditor(null));
  await page.waitForSelector('.modal #productPhotoInput', { state: 'attached', timeout: 20_000 });
  ok(await page.evaluate(() => document.querySelector('.modal #productPhotoInput').multiple),
    'the picker accepts more than one file');

  await page.setInputFiles('.modal #productPhotoInput', shot);
  await page.waitForTimeout(1200);
  const one = await page.evaluate(() => ({
    strip: document.querySelectorAll('#productImageStrip > div').length,
    kind: document.querySelector('.pi-kind')?.value,
    primary: !!document.querySelector('.modal .photo-drop.has-photo'),
  }));
  ok(one.strip === 1, `picking a photo adds it (${one.strip})`);
  ok(one.primary, 'and it becomes the primary picture');
  ok(one.kind === 'render', 'unlabelled arrives as a render, the claim that cannot mislead');

  // Several at once — the thing the single slot could not do at all.
  await page.setInputFiles('.modal #productPhotoInput', [shot, shot]);
  await page.waitForTimeout(1200);
  const three = await page.evaluate(() => ({
    strip: document.querySelectorAll('#productImageStrip > div').length,
    promote: document.querySelectorAll('.pi-primary').length,
    remove: document.querySelectorAll('.pi-remove').length,
  }));
  ok(three.strip === 3, `picking two more appends rather than replacing (${three.strip})`);
  ok(three.promote === 2, 'every picture but the primary can be promoted');
  ok(three.remove === 3, 'and every one can be removed');

  await page.evaluate(() => {
    const sels = document.querySelectorAll('.pi-kind');
    sels[1].value = 'print';
    sels[1].dispatchEvent(new Event('change', { bubbles: true }));
    document.querySelectorAll('.pi-primary')[0].click();
  });
  await page.waitForTimeout(700);
  const kinds = await page.evaluate(() => [...document.querySelectorAll('.pi-kind')].map((s) => s.value));
  ok(kinds[0] === 'print', 'labelling a photo as the actual print sticks, and promoting moves it to the front');

  // Remove the LAST one, not the first: the first is now the photo just labelled
  // as the actual print, and deleting it would leave nothing for the save check
  // below to look at. (It did, on the first run of this file.)
  await page.evaluate(() => {
    const b = document.querySelectorAll('.pi-remove');
    b[b.length - 1].click();
  });
  await page.waitForTimeout(600);
  ok(await page.evaluate(() => document.querySelectorAll('#productImageStrip > div').length) === 2,
    'removing one leaves the rest');
  ok(await page.evaluate(() => document.querySelector('.pi-kind').value) === 'print',
    'and does not disturb the others');

  /* SAVE IT, AND CHECK THE DISK.
   *
   * The editor showing three thumbnails proves nothing about what was written.
   * The filename used to be built from the PRODUCT id alone, so every photo on
   * a product wrote to the same file: the store held three image records, the
   * disk held one picture, and deleting any of them would have unlinked the
   * file the others still used. Nothing on screen showed it.
   */
  await page.evaluate(() => {
    const m = document.querySelector('.modal');
    const n = m.querySelector('[data-f="nameEn"]');
    n.value = 'Smoke Widget';
    n.dispatchEvent(new Event('input', { bubbles: true }));
    m.querySelector('[data-act="add-part"]').click();
  });
  await page.waitForTimeout(400);
  await page.evaluate(() => document.querySelector('.modal [data-act="save"]').click());
  await page.waitForTimeout(2200);

  // Flushed, then read from DISK after the app closes. Reading `window.products`
  // was tried first and silently skipped — that global is not reachable from an
  // automation context, so the check passed by not running, which is the exact
  // shape of guard this file exists to replace.
  await page.evaluate(() => { if (typeof flushSave === 'function') flushSave(); else saveAll(); });
  await page.waitForTimeout(1500);
  ok(errors.length === 0, `no renderer errors${errors.length ? ':\n    ' + errors.join('\n    ') : ''}`);
  await app.close();
  app = null;
  await new Promise((r) => setTimeout(r, 1200));

  const store = JSON.parse(fs.readFileSync(path.join(userData, 'khayt-store.json'), 'utf8'));
  const prod = (store.products || []).find((p) => p.nameEn === 'Smoke Widget');
  ok(!!prod, 'the product saved');
  const paths = (prod.images || []).map((i) => i.path);
  ok(paths.length === 2, `both pictures are stored (${paths.length})`);
  /* Each picture must have its OWN file.
   *
   * The filename used to be built from the PRODUCT id alone, so every photo on
   * a product wrote to the same file: the store held three image records, the
   * disk held one picture, and deleting any of them would have unlinked the
   * file the others still used. Nothing on screen showed it. */
  ok(new Set(paths).size === paths.length, `each picture has its own file (${paths.join(', ')})`);
  ok(prod.imagePath === paths[0], 'the legacy field mirrors the primary');
  ok((prod.images || []).some((i) => i.kind === 'print'), 'the label survived the save');

  const dir = path.join(userData, 'products');
  const onDisk = fs.existsSync(dir) ? fs.readdirSync(dir) : [];
  ok(onDisk.length === paths.length, `the files are actually on disk (${onDisk.length}: ${onDisk.join(', ')})`);
  for (const p of paths) ok(onDisk.includes(p), `${p} was written`);

  console.log('\n✅ the catalogue accepts photos, and each one is its own file.');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + (e && e.message ? e.message : e));
} finally {
  if (app) await app.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
