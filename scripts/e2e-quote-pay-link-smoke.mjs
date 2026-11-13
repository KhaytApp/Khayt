/**
 * E2E smoke — the quote pay link on the desktop, with real clicks.
 *
 *   1. Settings › Online Store › Pay links: type the store address and a fake
 *      secret, Save. The secret goes to main once and comes back as dots.
 *   2. An approved quote's job line says Ready; Send pay link opens the
 *      sheet; Copy link puts a link on the clipboard that verifies against
 *      the fake secret, and the line turns to Sent.
 *   3. A part with no weight: the sheet says why it cannot be sent.
 *   4. The job line in its other states: Expired, Paid, Mismatch, a Sent
 *      link the quote has changed under, and no line on a cancelled job.
 *   5. The secret is nowhere in the window: not the DOM, not an input, not
 *      localStorage, not the window's copy of the book, not the file on disk
 *      when the system can encrypt.
 *
 * Fake secret and fake store only. Run: npm run test:e2e:paylink
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const L = createRequire(import.meta.url)('../lib/quote-pay-link.js');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const SECRET = 'test-secret-not-real-e2e-0123456789abcdef';
const STORE = 'https://shop.example';

const userData = makeUserDataDir();
const { electronApp, window } = await launchApp(userData);
let failed = false;
try {
  await dismissWizard(window);
  const now = Math.floor(Date.now() / 1000);
  await window.evaluate(({ now }) => {
    settings.mode = 'professional';
    settings.currency = 'SAR';
    settings.enableVat = false;
    KhaytShell.applyMode();
    clients.push({ id: 'C-PL', nameEn: 'Sara Example', nameAr: 'سارة مثال', phone: '+966500000000' });
    const job = (id, over) => Object.assign({
      id, jobNumber: id, status: 'pending', clientId: 'C-PL', client: 'Sara Example',
      quoteAcceptedAt: '2026-11-12', date: '2026-11-12', project: 'Dragon ' + id, price: 340, paidAmount: 0,
      material: 'PLA', statusHistory: [],
      parts: [{ name: 'dragon-v2.stl', material: 'PLA', color: 'red', qty: 2, printWeight: 450, baseCost: 80 }],
      extraLines: [{ label: 'Design fee', amount: 50 }],
    }, over || {});
    printLog.unshift(
      job('QPL-READY'),
      job('QPL-NOWEIGHT', { parts: [{ name: 'bracket-left.stl', material: 'PLA', qty: 1, baseCost: 20 }], price: 60, extraLines: [] }),
      job('QPL-EXPIRED', { payLink: { issuedAt: now - 9 * 86400, expiresAt: now - 2 * 86400, amount: 340, locale: 'ar' } }),
      job('QPL-PAID', { payLink: { issuedAt: now - 86400, expiresAt: now + 6 * 86400, amount: 340,
        paid: { storeOrder: '1043', amount: 340, delivery: 22, paidAt: '2026-11-12T10:00:00Z', url: 'https://shop.example/orders/1043' } } }),
      job('QPL-OUTDATED', { payLink: { issuedAt: now - 86400, expiresAt: now + 6 * 86400, amount: 290, locale: 'ar' } }),
      job('QPL-CANCELLED', { status: 'cancelled', payLink: { issuedAt: now - 86400, expiresAt: now + 6 * 86400, amount: 340 } }),
      job('QPL-MISMATCH', { payLink: { issuedAt: now - 86400, expiresAt: now + 6 * 86400, amount: 290,
        paid: { storeOrder: '1044', amount: 290, delivery: 22, paidAt: '2026-11-12T10:00:00Z' } } }),
    );
    saveAll();
    return flushSave();
  }, { now });

  // ── 1. Settings › Online Store ───────────────────────────────────────────
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="store"]');
  await window.waitForSelector('#quotePayLinkSection #qpl_storeUrl', { state: 'visible', timeout: 10_000 });
  ok(true, 'the Pay links card is in Settings › Online Store');
  await window.fill('#qpl_storeUrl', STORE);
  await window.click('#quotePayLinkSection [data-qpl-set="replace"]');
  await window.fill('#qpl_secretInput', 'too-short');
  await window.click('#quotePayLinkSection [data-qpl-set="save"]');
  ok(!(await window.evaluate(() => !!(settings.quotePayLink && settings.quotePayLink.secret))), 'a secret under 32 characters is refused');
  await window.fill('#qpl_secretInput', SECRET);
  await window.click('#quotePayLinkSection [data-qpl-set="save"]');
  await window.waitForFunction(() => /••••••••/.test(document.querySelector('#qpl_secretState')?.textContent || ''), null, { timeout: 10_000 });
  ok(true, 'the secret shows as dots, "Saved on this computer"');
  ok(await window.isVisible('#quotePayLinkSection [data-qpl-set="remove"]'), 'with Remove beside Replace…');
  await window.click('#settings-panel-store [data-act="save-settings-from-panel"]');
  await window.waitForFunction((s) => settings.quotePayLink?.storeUrl === s, STORE, { timeout: 5_000 });
  ok(true, 'the store address is saved by the pane\'s Save');
  await window.evaluate(() => flushSave());
  const reloaded = await window.evaluate(() => window.hubAPI.loadStore());
  ok(reloaded.settings.quotePayLink.secret === '__KHAYT_MASKED__', 'the window is handed the mask on load');

  // ── 2. Ready → Send → Copy → Sent ────────────────────────────────────────
  await switchTab(window, 'logs-tab');
  await window.click('[data-act="edit-log"][data-id="QPL-READY"]');
  await window.waitForSelector('.qpl-line[data-state="ready"]', { timeout: 10_000 });
  ok((await window.textContent('.qpl-line[data-state="ready"]')).includes('Quote approved. Not paid.'), 'the job line says Ready');
  await window.click('.qpl-line[data-state="ready"] [data-act="qpl-send"]');
  await window.waitForSelector('.qpl-sheet .qpl-items', { timeout: 10_000 });
  const total = await window.textContent('.qpl-sheet [data-qpl-total]');
  ok(total.includes('340.00'), `the sheet shows what the customer pays (${total.trim()})`);
  ok((await window.$$('.qpl-sheet .qpl-item')).length === 2, 'two lines: the part and the design fee');
  const width = await window.evaluate(() => document.querySelector('.qpl-sheet').getBoundingClientRect().width);
  ok(Math.round(width) === 560, `the sheet is 560 px wide (${Math.round(width)})`);
  await electronApp.evaluate(({ clipboard }) => clipboard.writeText(''));
  await window.click('.qpl-sheet [data-qpl="copy"]');
  await window.waitForFunction(() => /\S/.test(document.querySelector('.qpl-sheet .qpl-status')?.textContent || ''), null, { timeout: 10_000 });
  const link = await electronApp.evaluate(({ clipboard }) => clipboard.readText());
  const m = /^https:\/\/shop\.example\/sa\/(ar|en)\/pay\/([\w-]+\.[\w-]+\.[\w-]+)$/.exec(link);
  ok(!!m, `the copied link is the store's pay link (${link.slice(0, 48)}…)`);
  const opened = L.open(m[2]);
  ok(!!opened, 'the shared rule can open its token');
  const mac = crypto.createHmac('sha256', Buffer.from(SECRET, 'utf8')).update(opened.input).digest();
  ok(L.signatureMatches(m[2], Array.from(mac)), 'and its signature matches the secret (signatureMatches)');
  const other = crypto.createHmac('sha256', Buffer.from('test-secret-not-real-some-other-key-000000', 'utf8')).update(opened.input).digest();
  ok(!L.signatureMatches(m[2], Array.from(other)), 'and no other key');
  const claims = opened.claims;
  ok(claims.quote_id === 'QPL-READY' && claims.items.reduce((s, i) => s + i.unit_amount * i.quantity, 0) === 34000,
    'it charges the quote: 340.00 in halalas, for this job');
  ok(JSON.stringify(claims.customer) === JSON.stringify({ name: m[1] === 'ar' ? 'سارة مثال' : 'Sara Example' }), 'only the name goes with it');
  await window.click('.qpl-sheet [data-qpl="close"]');
  await window.waitForSelector('.qpl-line[data-state="sent"]', { timeout: 10_000 });
  ok((await window.textContent('.qpl-line[data-state="sent"]')).includes('expires in 7 days'), 'the line turns to Sent, expiring in 7 days');
  const rec = await window.evaluate(() => printLog.find((o) => o.id === 'QPL-READY').payLink);
  ok(rec.issuedAt > 0 && rec.amount === 340 && (rec.locale === 'ar' || rec.locale === 'en') && typeof rec.sentAt === 'string',
    `the job remembers the link it sent, as recordOf(claims, { locale, sentAt }) (${JSON.stringify(rec)})`);
  await window.click('.modal-form [data-act="cancel"]');

  // ── 3. Can't send: a part with no weight ─────────────────────────────────
  await window.click('[data-act="edit-log"][data-id="QPL-NOWEIGHT"]');
  await window.waitForSelector('.qpl-line[data-state="ready"]', { timeout: 10_000 });
  await window.click('.qpl-line [data-act="qpl-send"]');
  await window.waitForSelector('.qpl-sheet .qpl-why[data-reason="no_weight"]', { timeout: 10_000 });
  const why = await window.textContent('.qpl-sheet .qpl-why');
  ok(why.includes('A part has no weight') && why.includes('bracket-left.stl'), 'the sheet says why: a part has no weight, and which');
  ok(!(await window.$('.qpl-sheet [data-qpl="copy"]')), 'and offers no link to copy');
  await window.click('.qpl-sheet [data-qpl="close"]');
  await window.click('.modal-form [data-act="cancel"]');

  // ── 4. The other states ──────────────────────────────────────────────────
  for (const [id, state, words] of [
    ['QPL-EXPIRED', 'expired', 'Not paid.'],
    ['QPL-PAID', 'paid', 'order #1043'],
    ['QPL-MISMATCH', 'mismatch', '290.00 paid, 340.00 quoted'],
    ['QPL-OUTDATED', 'sent', 'The quote has changed since: this link charges 290.00, the quote now comes to 340.00'],
  ]) {
    await window.click(`[data-act="edit-log"][data-id="${id}"]`);
    await window.waitForSelector(`.qpl-line[data-state="${state}"]`, { timeout: 10_000 });
    const text = await window.textContent(`.qpl-line[data-state="${state}"]`);
    ok(text.includes(words), `${state}: "${text.replace(/\s+/g, ' ').trim()}"`);
    await window.click('.modal-form [data-act="cancel"]');
  }
  await window.click('[data-act="edit-log"][data-id="QPL-OUTDATED"]');
  await window.waitForSelector('.qpl-line[data-outdated="true"] .btn.primary[data-act="qpl-send"]', { timeout: 10_000 });
  ok((await window.textContent('.qpl-line[data-outdated="true"] [data-act="qpl-send"]')).trim() === 'Send again', 'an outdated link offers Send again');
  await window.click('.modal-form [data-act="cancel"]');
  await window.click('[data-act="edit-log"][data-id="QPL-CANCELLED"]');
  await window.waitForSelector('.modal-form', { timeout: 10_000 });
  ok(!(await window.$('.modal-form .qpl-line')), 'a cancelled job shows no pay link line');
  await window.click('.modal-form [data-act="cancel"]');
  const dots = await window.evaluate(() => Object.fromEntries(['expired', 'paid', 'mismatch'].map((s) => {
    const host = document.createElement('div');
    host.innerHTML = payLinkLineHtml(printLog.find((o) => o.id === 'QPL-' + s.toUpperCase()));
    document.body.appendChild(host);
    const c = getComputedStyle(host.querySelector('.qpl-dot')).backgroundColor;
    host.remove();
    return [s, c];
  })));
  ok(new Set(Object.values(dots)).size === 3, `each state has its own dot colour (${JSON.stringify(dots)})`);

  // ── 5. The secret is nowhere in the window ───────────────────────────────
  const leak = await window.evaluate((secret) => {
    const inputs = [...document.querySelectorAll('input, textarea')].map((el) => el.value).join('\n');
    let ls = '';
    try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); ls += k + '=' + localStorage.getItem(k) + '\n'; } } catch (_) { /* none */ }
    let ss = '';
    try { for (let i = 0; i < sessionStorage.length; i++) { const k = sessionStorage.key(i); ss += sessionStorage.getItem(k); } } catch (_) { /* none */ }
    return {
      dom: document.documentElement.outerHTML.includes(secret),
      inputs: inputs.includes(secret),
      local: ls.includes(secret), session: ss.includes(secret),
      book: JSON.stringify({ settings, printLog }).includes(secret),
    };
  }, SECRET);
  ok(!leak.dom, 'not in the DOM');
  ok(!leak.inputs, 'not in any input');
  ok(!leak.local && !leak.session, 'not in localStorage or sessionStorage');
  ok(!leak.book, 'not in the window\'s copy of the book');
  const canSeal = await electronApp.evaluate(({ safeStorage }) => safeStorage.isEncryptionAvailable());
  const raw = fs.readFileSync(path.join(userData, 'khayt-store.json'), 'utf8');
  if (canSeal) ok(!raw.includes(SECRET), 'and sealed in the file on disk');
  else console.log('  · safeStorage unavailable here: the file-on-disk check is skipped');

  console.log('\n✅ quote pay link smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
