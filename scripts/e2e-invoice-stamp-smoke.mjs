#!/usr/bin/env node
/**
 * E2E: a voided invoice prints VOID, a credited one CREDITED, a paid one PAID.
 *
 * The stamp is the shared document's (`invoiceStampOf` in
 * lib/invoice-document.js, #2315) and its look is invoice.css, the same in
 * the desktop, Mac and iPhone copies. What only the running desktop can show
 * is that its own invoice window draws it with that look: the old desktop-only
 * `.inv .paid-stamp` rule in styles.css is gone, so a missing stylesheet would
 * leave the word as plain text at the top of the page.
 *
 *   node scripts/e2e-invoice-stamp-smoke.mjs
 */
import fs from 'node:fs';
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  await window.evaluate(() => {
    const job = (id, extra) => ({ id, project: 'Bracket', date: '2026-11-01', status: 'completed',
      price: 100, material: 'PLA', parts: [], ...extra });
    printLog.push(
      job('ORD-void', { voidedAt: '2026-11-05T09:00:00.000Z', voidedReason: 'Customer cancelled' }),
      job('ORD-cred', { creditedAt: '2026-11-06T09:00:00.000Z' }),
      job('ORD-paid', { paidAmount: 1000 }),
      job('ORD-open', {}),
    );
    saveAll();
  });

  const render = (id) => window.evaluate(async (orderId) => {
    await renderInvoiceForOrder(printLog.find((o) => o.id === orderId));
    const area = document.querySelector('#invoice-print-area');
    const mark = area.querySelector('[data-stamp]');
    const banner = area.querySelector('.inv-reversal');
    const cs = mark ? getComputedStyle(mark) : null;
    return {
      kind: mark ? mark.dataset.stamp : null,
      word: mark ? mark.textContent.trim() : null,
      position: cs ? cs.position : null,
      pointerEvents: cs ? cs.pointerEvents : null,
      banner: banner ? banner.textContent.replace(/\s+/g, ' ').trim() : null,
      oldClass: !!area.querySelector('.paid-stamp'),
    };
  }, id);

  const v = await render('ORD-void');
  if (v.kind !== 'void' || v.word !== 'VOID') fail(`voided invoice: ${JSON.stringify(v)}`);
  if (v.position !== 'absolute' || v.pointerEvents !== 'none') fail(`VOID is not laid over the page (invoice.css missing?): ${JSON.stringify(v)}`);
  if (!v.banner || !/voided/i.test(v.banner) || !/Customer cancelled/.test(v.banner)) fail(`void banner: "${v.banner}"`);

  const c = await render('ORD-cred');
  if (c.kind !== 'credited' || c.word !== 'CREDITED') fail(`credited invoice: ${JSON.stringify(c)}`);
  if (c.position !== 'absolute') fail(`CREDITED not styled: ${JSON.stringify(c)}`);
  if (!c.banner) fail('credited invoice has no line saying so');

  const p = await render('ORD-paid');
  if (p.kind !== 'paid' || p.word !== 'PAID') fail(`paid invoice: ${JSON.stringify(p)}`);
  if (p.position !== 'absolute') fail(`PAID corner stamp not styled: ${JSON.stringify(p)}`);
  if (p.banner) fail(`a paid invoice got a reversal line: "${p.banner}"`);

  const o = await render('ORD-open');
  if (o.kind) fail(`an unpaid invoice got a stamp: ${JSON.stringify(o)}`);
  if ([v, c, p, o].some((r) => r.oldClass)) fail('the old .paid-stamp element is still drawn');

  console.log('invoice stamp smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
