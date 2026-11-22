/**
 * E2E smoke — a full customer erase takes their tracking pages down.
 *
 * A loopback server stands in for Khayt Cloud. A full erase of a customer with
 * two published jobs (one invoiced and paid) marks both in the erase write and
 * DELETEs both pages; a page whose DELETE fails stays marked, is never
 * republished, and goes on the next pass. Another customer's page and an
 * unlink-only erase take nothing down. The Mac's applyCustomerErase rule.
 *
 * Run: npm run test:e2e:takedown
 */
import http from 'node:http';
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const deletes = [];
let failToken = 'bbb';
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const m = /^\/v1\/shops\/shop1\/published\/([^/?]+)$/.exec(req.url);
    if (req.method === 'DELETE' && m) {
      deletes.push(m[1]);
      if (m[1] === failToken) { res.writeHead(503, { 'content-type': 'application/json' }); return res.end('{"error":"busy"}'); }
      res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{"ok":true}');
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, rev: 1, items: [] }));
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}`;
const waitFor = async (fn, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await fn()) return true; await new Promise((r) => setTimeout(r, 100)); } return false; };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate((u) => {
    settings.cloud = { ...(settings.cloud || {}), enabled: true, shopId: 'shop1', url: u, token: 'tok1' };
    clients.push({ id: 'c1', nameEn: 'Erase Me', email: 'e@example.com' }, { id: 'c2', nameEn: 'Keep Me' }, { id: 'c3', nameEn: 'Unlink Me' });
    printLog.push(
      { id: 'j1', clientId: 'c1', client: 'Erase Me', status: 'completed', cloudPublished: true, trackingToken: 'aaa', paidAmount: 100, paymentStatus: 'paid', invoiceNumber: 'INV-1', date: '2026-10-01' },
      { id: 'j2', clientId: 'c1', client: 'Erase Me', status: 'printing', cloudPublished: true, trackingToken: 'bbb', date: '2026-10-02' },
      { id: 'j3', clientId: 'c2', client: 'Keep Me', status: 'printing', cloudPublished: true, trackingToken: 'ccc', date: '2026-10-03' },
      { id: 'j4', clientId: 'c3', client: 'Unlink Me', status: 'printing', cloudPublished: true, trackingToken: 'ddd', date: '2026-10-04' },
    );
    saveAll();
  }, url);

  // ---- Full erase ----
  await window.evaluate(() => { deleteClient('c1'); });
  await window.waitForSelector('input[name="eraseMode"][value="full"]');
  const sheet = await window.evaluate(() => document.querySelector('.modal, [role="dialog"]')?.innerText || '');
  ok(/takes down 2 tracking page/.test(sheet), 'the erase sheet says two tracking pages come down');
  await window.check('input[name="eraseMode"][value="full"]');
  await window.click('[data-act="save"]');
  const marked = await window.evaluate(() => ['j1', 'j2'].map((id) => { const o = printLog.find((x) => x.id === id); return [o.cloudPublished, !!o.portalTakedownPending, o.clientErasedAt ? 1 : 0]; }));
  ok(marked.every(([pub, , erased]) => pub === false && erased === 1), 'both jobs are unpublished and marked erased in the erase write');
  ok(await waitFor(() => deletes.includes('aaa') && deletes.includes('bbb')), `both pages are DELETEd, the paid one included (${deletes.join(', ')})`);
  ok(await waitFor(() => window.evaluate(() => !printLog.find((x) => x.id === 'j1').portalTakedownPending)), 'a page the cloud took down is no longer pending');
  ok(await window.evaluate(() => printLog.find((x) => x.id === 'j2').portalTakedownPending === true), 'a page whose DELETE failed stays pending');
  ok(!deletes.includes('ccc'), 'another customer\'s page is left alone');

  // A pending page is never put back up.
  await window.evaluate(() => publishOrderToCloudPortal('j2'));
  await new Promise((r) => setTimeout(r, 400));
  ok(await window.evaluate(() => printLog.find((x) => x.id === 'j2').cloudPublished === false), 'publishing a pending job is refused');

  // The next pass finishes it.
  failToken = '';
  await window.evaluate(() => runPortalTakedowns());
  ok(await waitFor(() => window.evaluate(() => !printLog.find((x) => x.id === 'j2').portalTakedownPending)), 'the next pass takes the failed page down and clears the mark');

  // ---- Unlink only ----
  const before = deletes.length;
  await window.evaluate(() => { deleteClient('c3'); });
  await window.waitForSelector('input[name="eraseMode"][value="unlink"]');
  await window.click('[data-act="save"]');
  await new Promise((r) => setTimeout(r, 600));
  const j4 = await window.evaluate(() => { const o = printLog.find((x) => x.id === 'j4'); return [o.cloudPublished, !!o.portalTakedownPending]; });
  ok(deletes.length === before && j4[0] === true && !j4[1], 'an unlink-only erase takes nothing down');

  console.log('e2e-erase-takedown: ok (full erase marks + DELETEs, failure stays pending and unpublishable, retried; unlink takes nothing)');
} catch (err) {
  failed = true;
  console.error('e2e-erase-takedown FAILED:', err && err.message);
} finally {
  await electronApp.close();
  server.close();
  process.exit(failed ? 1 : 0);
}
