/**
 * E2E smoke — the customer editor works on a copy (Windows/Linux).
 *
 * The editor used to shallow-copy the customer, so the address book and price
 * list it edited WERE the book's: deleting an address and pressing Cancel
 * still lost it, and the next save anywhere wrote that to disk. And Save threw
 * on a row another app wrote without a `label`. Here, through the real editor:
 *   - delete an address and a price row, Cancel, save something else: both
 *     rows are still in the book and on disk;
 *   - a row with no `label`, and one with fields this build does not know,
 *     survive a Save untouched, and nothing throws;
 *   - Edit Order's address book follows the Customer picker.
 *
 * Run: npm run test:e2e:clientdraft
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const userData = makeUserDataDir();
const { electronApp, window } = await launchApp(userData);
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(() => {
    settings.mode = 'professional'; applyMode();
    clients.push(
      { id: 'CLI-cd-a', nameEn: 'Amal', createdAt: '2026-01-01',
        addresses: [{ id: 'ADDR-1', label: 'Home', address: 'Riyadh 1' }, { id: 'ADDR-2', label: 'Work', address: 'Riyadh 2' }],
        priceList: [{ product: 'Bracket', price: 12, note: '' }] },
      { id: 'CLI-cd-b', nameEn: 'Badr', createdAt: '2026-01-01',
        addresses: [{ id: 'ADDR-3', address: 'Jeddah 3' }, { id: 'ADDR-4', label: 'Shop', address: 'Jeddah 4', line1: '12 King Rd', city: 'Jeddah' }] },
    );
    printLog.push({ id: 'J-cd-1', project: 'Cup', status: 'pending', price: 10, parts: [], date: '2026-11-01', clientId: 'CLI-cd-a' });
    saveAll();
  });
  const errors = [];
  window.on('pageerror', (e) => errors.push(String(e && e.message)));

  // Delete, Cancel, then a save from elsewhere.
  await window.evaluate(() => openClientEditor('CLI-cd-a'));
  await window.waitForSelector('.addr-edit', { state: 'attached', timeout: 10000 });
  // Remove one address and relabel the other through the address editor,
  // then Cancel the customer.
  await window.click('.addr-edit[data-ai="0"]');
  await window.click('.addr-editor [data-act="addr-remove"]');
  await window.waitForSelector('.addr-editor', { state: 'detached', timeout: 10000 });
  await window.click('.addr-edit[data-ai="0"]');
  await window.fill('.addr-editor #addrLabel', 'Changed');
  await window.click('.addr-editor [data-act="addr-save"]');
  await window.waitForSelector('.addr-editor', { state: 'detached', timeout: 10000 });
  await window.evaluate(() => document.querySelector('.pl-rm')?.click());
  await window.click('#modalMount [data-act="cancel"]');
  await window.waitForSelector('.addr-edit', { state: 'detached', timeout: 10000 });
  await window.evaluate(() => { settings.bizEn = 'Acme'; saveAll(); flushSave(); });
  await window.waitForTimeout(600);
  const a = await window.evaluate(() => clients.find((c) => c.id === 'CLI-cd-a'));
  ok(a.addresses.length === 2 && a.addresses[0].label === 'Home' && a.addresses[1].label === 'Work',
    `Cancel kept both addresses as they were (${JSON.stringify(a.addresses.map((x) => x.label))})`);
  ok(a.priceList.length === 1, 'and the price row');
  const disk = JSON.parse(fs.readFileSync(path.join(userData, 'khayt-store.json'), 'utf8'));
  const onDisk = (disk.clients || []).find((c) => c.id === 'CLI-cd-a');
  ok(onDisk && onDisk.addresses.length === 2, 'and so does the book on disk');

  // A row with no label, and one with fields this build does not know.
  await window.evaluate(() => openClientEditor('CLI-cd-b'));
  await window.waitForSelector('#modalMount [data-act="save"]', { timeout: 10000 });
  await window.click('#modalMount [data-act="save"]');
  await window.waitForSelector('.addr-edit', { state: 'detached', timeout: 10000 });
  const b = await window.evaluate(() => clients.find((c) => c.id === 'CLI-cd-b'));
  ok(errors.length === 0, `Save did not throw (${errors.join(' | ')})`);
  ok(b.addresses.length === 2 && b.addresses[0].address === 'Jeddah 3', 'a row with no label is kept');
  ok(b.addresses[1].line1 === '12 King Rd' && b.addresses[1].city === 'Jeddah', 'a row with newer fields is kept whole');

  // Edit Order's address book follows the Customer picker.
  await window.evaluate(() => openOrderEditor('J-cd-1'));
  await window.waitForSelector('#oeCustomer', { timeout: 10000 });
  const before = await window.evaluate(() => [...document.querySelectorAll('#oeAddressSelect option')].map((o) => o.value).filter(Boolean));
  ok(before.join() === 'Riyadh 1,Riyadh 2', `the job's customer's book (${before})`);
  await window.evaluate(() => { const s = document.getElementById('oeCustomer'); s.value = 'CLI-cd-b'; s.dispatchEvent(new Event('change', { bubbles: true })); });
  const after = await window.evaluate(() => [...document.querySelectorAll('#oeAddressSelect option')].map((o) => o.value).filter(Boolean));
  // A row with fields is copied as its fields formatted (lib/customer-address.js textOf).
  ok(after.join() === 'Jeddah 3,12 King Rd\nJeddah', `follows the customer picked (${JSON.stringify(after)})`);
  await window.evaluate(() => { const s = document.getElementById('oeAddressSelect'); s.value = 'Jeddah 3'; s.dispatchEvent(new Event('change', { bubbles: true })); });
  ok(await window.evaluate(() => document.querySelector('[data-f="deliveryAddress"]').value) === 'Jeddah 3', 'and picking one fills the delivery address');
  await window.evaluate(() => document.querySelector('#modalMount [data-act="cancel"]')?.click());

  console.log('e2e-client-draft: ok');
} catch (err) {
  failed = true;
  console.error('e2e-client-draft FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
