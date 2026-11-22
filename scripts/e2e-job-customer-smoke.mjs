/**
 * E2E smoke — a job's customer, changed from Edit Order (Windows/Linux).
 *
 * Turki's rule (Nov 10, option C), which is lib/order-edit.js's and the
 * Mac's: a job's customer can be changed until its invoice is submitted to
 * ZATCA, voided, credited or paid; a job with no customer can always be given
 * one. Here, through the real editor:
 *   - a job with no customer is given one; the id moves and the edit is in
 *     the job's history, once;
 *   - a paid job's picker is shut and says why;
 *   - a paid job with NO customer can still be given one;
 *   - a customer who bills in another currency is warned about, and the
 *     job keeps its price and currency.
 *
 * Run: npm run test:e2e:jobcustomer
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(() => {
    settings.currency = 'SAR';
    clients.push(
      { id: 'CLI-jc-a', nameEn: 'Amal', createdAt: '2026-01-01' },
      { id: 'CLI-jc-b', nameEn: 'Badr', createdAt: '2026-01-01' },
      { id: 'CLI-jc-k', nameEn: 'Khalid', currency: 'KWD', createdAt: '2026-01-01' },
    );
    const job = (id, extra) => Object.assign({ id, project: id, status: 'pending', price: 100, parts: [], date: '2026-11-01' }, extra);
    printLog.push(
      job('J-jc-none'),
      job('J-jc-paid', { clientId: 'CLI-jc-a', paidAmount: 40 }),
      job('J-jc-paid-none', { paidAmount: 40 }),
      job('J-jc-open', { clientId: 'CLI-jc-a' }),
    );
    saveAll();
  });

  const open = async (id) => {
    await window.evaluate((i) => openOrderEditor(i), id);
    await window.waitForSelector('#oeCustomer', { timeout: 10000 });
    return window.evaluate(() => ({
      disabled: document.getElementById('oeCustomer').disabled,
      value: document.getElementById('oeCustomer').value,
      note: document.getElementById('oeCustomerNote').textContent.trim(),
    }));
  };
  const pick = (v) => window.evaluate((val) => {
    const s = document.getElementById('oeCustomer');
    s.value = val; s.dispatchEvent(new Event('change', { bubbles: true }));
    return document.getElementById('oeCustomerNote').textContent.trim();
  }, v);
  const save = async () => {
    await window.click('#modalMount [data-act="save"]');
    await window.waitForSelector('#oeCustomer', { state: 'detached', timeout: 10000 });
  };
  const cancel = () => window.evaluate(() => document.querySelector('#modalMount [data-act="cancel"]')?.click());

  // A job with no customer is given one.
  let s = await open('J-jc-none');
  ok(!s.disabled && s.value === '', 'a job with no customer: the picker is open, on No customer');
  await pick('CLI-jc-b');
  await save();
  const given = await window.evaluate(() => printLog.find((o) => o.id === 'J-jc-none'));
  ok(given.clientId === 'CLI-jc-b', `the customer was given (${given.clientId})`);
  ok(!('client' in given), 'a desktop job carries the id alone, no copied name');
  const hist = (given.editHistory || []).filter((e) => e.fields && e.fields.clientId);
  ok(hist.length === 1 && hist[0].fields.clientId.from === null && hist[0].fields.clientId.to === 'CLI-jc-b',
    `one history entry for it (${JSON.stringify(hist)})`);

  // A paid job: shut, and says why.
  s = await open('J-jc-paid');
  ok(s.disabled && s.value === 'CLI-jc-a', 'a paid job: the picker is shut on its customer');
  ok(/payment was taken/i.test(s.note), `and says why (${s.note})`);
  await cancel();

  // A paid job with no customer can still be given one.
  s = await open('J-jc-paid-none');
  ok(!s.disabled, 'a paid job with no customer: the picker is open');
  await pick('CLI-jc-a');
  await save();
  ok(await window.evaluate(() => printLog.find((o) => o.id === 'J-jc-paid-none').clientId) === 'CLI-jc-a', 'and the customer was given');

  // Another currency: warned, nothing converted.
  s = await open('J-jc-open');
  ok(!s.disabled && s.note === '', 'an unpaid job: open, no note');
  const note = await pick('CLI-jc-k');
  ok(/another currency/i.test(note), `a customer in another currency is warned about (${note})`);
  await save();
  const moved = await window.evaluate(() => printLog.find((o) => o.id === 'J-jc-open'));
  ok(moved.clientId === 'CLI-jc-k' && moved.price === 100 && !moved.currency, 'the job keeps its price and currency');

  console.log('e2e-job-customer: ok');
} catch (err) {
  failed = true;
  console.error('e2e-job-customer FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
