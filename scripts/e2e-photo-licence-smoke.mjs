#!/usr/bin/env node
/**
 * E2E: "Use as product photo" on a job's photo, and "I have a licence to sell
 * prints" on the "Not licensed for sale" warning — both in the real job editor.
 *
 * The photo lands on the job's product as a `print`-kind picture with a file
 * on disk, and the same photo twice is one picture. The licence override
 * opens INLINE (the editor must survive it), refuses a non-http link, and on
 * save records `licence: commercial` with the proof fields, which clears the
 * warning in place.
 *
 *   node scripts/e2e-photo-licence-smoke.mjs
 */
import { launchApp, makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';
import fs from 'node:fs';

const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  await window.evaluate(() => {
    const c = document.createElement('canvas'); c.width = 32; c.height = 24;
    const g = c.getContext('2d'); g.fillStyle = '#c33'; g.fillRect(0, 0, 32, 24);
    const thumb = c.toDataURL('image/jpeg', 0.85);
    products.push({ id: 'PRD-e2e', name: 'Lamp', images: [] });
    printFiles.push({ id: 'PF-e2e', name: 'Dragon', originalName: 'dragon.3mf', licence: 'cc-by-nc' });
    printLog.push({ id: 'ORD-e2e', project: 'Lamp', date: localDateStr(), status: 'completed',
      productId: 'PRD-e2e', parts: [{ printFileId: 'PF-e2e', grams: 10 }],
      printPhotos: [{ thumb, filename: null, source: 'printer' }] });
    saveAll();
    openOrderEditor('ORD-e2e');
  });

  // ---- Use as product photo ----
  await window.waitForSelector('[data-act="photo-to-product"]', { timeout: 10_000 });
  await window.click('[data-act="photo-to-product"]');
  await window.waitForFunction(() => (products.find((p) => p.id === 'PRD-e2e').images || []).length === 1, null, { timeout: 10_000 });
  const pic = await window.evaluate(() => {
    const p = products.find((x) => x.id === 'PRD-e2e');
    return { img: p.images[0], imagePath: p.imagePath, thumb: p.thumbnail === p.images[0].thumbnail };
  });
  if (pic.img.kind !== 'print') fail(`added picture kind is ${pic.img.kind}, wanted print`);
  if (!pic.img.path || pic.imagePath !== pic.img.path) fail(`no file path / not primary on an empty product: ${JSON.stringify(pic)}`);
  if (!pic.thumb) fail('legacy thumbnail not mirrored');
  const onDisk = fs.readdirSync(userData, { recursive: true }).some((f) => String(f).endsWith(pic.img.path));
  if (!onDisk) fail(`product picture ${pic.img.path} was not written under userData`);
  await window.click('[data-act="photo-to-product"]');
  await window.waitForTimeout(500);
  const n = await window.evaluate(() => products.find((p) => p.id === 'PRD-e2e').images.length);
  if (n !== 1) fail(`the same photo twice made ${n} pictures`);

  // ---- I have a licence to sell prints ----
  await window.waitForSelector('.licence-at-sale.warn [data-act="licence-have"]', { timeout: 10_000 });
  await window.click('.licence-at-sale.warn [data-act="licence-have"]');
  await window.waitForSelector('.licence-have-form', { timeout: 5_000 });
  if (!(await window.$('[data-act="photo-to-product"]'))) fail('opening the licence form closed the job editor');
  await window.fill('.licence-have-form [data-lh="code"]', 'PATREON-123');
  await window.fill('.licence-have-form [data-lh="url"]', 'ftp://example.com/licence');
  await window.click('.licence-have-form [data-lh="save"]');
  const shown = await window.$eval('.licence-have-error', (e) => !e.hidden && e.textContent);
  if (!shown) fail('a non-http verification page was accepted');
  if (await window.evaluate(() => printFiles.find((r) => r.id === 'PF-e2e').licence) !== 'cc-by-nc') fail('a refused save changed the licence');
  await window.fill('.licence-have-form [data-lh="url"]', 'https://example.com/licence');
  await window.fill('.licence-have-form [data-lh="until"]', '2099-12-31');
  await window.click('.licence-have-form [data-lh="save"]');
  const rec = await window.evaluate(() => {
    const r = printFiles.find((x) => x.id === 'PF-e2e');
    return { licence: r.licence, code: r.licenceCode, url: r.licenceUrl, until: r.licenceExpires };
  });
  if (rec.licence !== 'commercial' || rec.code !== 'PATREON-123' || rec.url !== 'https://example.com/licence' || rec.until !== '2099-12-31') {
    fail(`licence not recorded: ${JSON.stringify(rec)}`);
  }
  if (await window.$('.licence-at-sale.warn')) fail('the warning is still shown after the licence was recorded');
  if (!(await window.$('[data-act="photo-to-product"]'))) fail('saving the licence closed the job editor');

  console.log('photo/licence smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
