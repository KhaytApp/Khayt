/**
 * E2E smoke — a customer's address in fields (Windows/Linux).
 *
 * The customer editor's address book opens each row in its own editor
 * (renderer/address-editor.js on lib/customer-address.js). Through the real
 * screens:
 *   - a Saudi address added through the editor is stored with its fields AND
 *     the `address` text (and textOf), which every older build reads;
 *   - it reopens showing its fields;
 *   - changing the country to the UAE removes the National Address block and
 *     changes the field order;
 *   - a bad postal code is a note under the field, and the address still saves;
 *   - an old free-text row opens as its text, not split into fields;
 *   - a row an older build edited shows the module's message and is not
 *     rewritten by a customer save;
 *   - Edit Order's delivery picker shows the formatted address;
 *   - in Arabic (RTL) the phone, postal code and number fields are dir=ltr.
 *
 * Run: npm run test:e2e:addresseditor
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
const errors = [];
window.on('pageerror', (e) => errors.push(String(e && e.message)));

const fill = async (field, value) => {
  await window.fill(`.addr-editor #addrF_${field}`, value);
};

try {
  await dismissWizard(window);
  const shop = await window.evaluate(() => {
    settings.mode = 'professional'; applyMode();
    settings.tax = Object.assign({}, settings.tax || {}, { country: 'SA' });
    i18n.set('en');
    // Saved in fields, then an older build changed the text (address ≠ textOf).
    const edited = { id: 'ADDR-else', label: 'Head office', line1: 'Office 14', city: 'Riyadh',
      textOf: 'Office 14\nRiyadh', address: 'Office 14, Sample Tower, Dubai' };
    clients.push({ id: 'CLI-addr', nameEn: 'Sample Customer', phone: '0500000000', createdAt: '2026-01-01',
      addresses: [{ id: 'ADDR-old', label: 'Old shop', address: 'Sample Street near the sample mall, Jeddah' }, edited] });
    printLog.push({ id: 'J-addr-1', project: 'Cup', status: 'pending', price: 10, parts: [], date: '2026-11-01', clientId: 'CLI-addr' });
    saveAll();
    return settings.tax.country;
  });
  ok(shop === 'SA', 'the shop is in Saudi Arabia');

  // Add a Saudi address through the editor.
  await window.evaluate(() => openClientEditor('CLI-addr'));
  await window.waitForSelector('#ceAddrAdd', { timeout: 10000 });
  await window.click('#ceAddrAdd');
  await window.waitForSelector('.addr-editor', { timeout: 10000 });
  const fresh = await window.evaluate(() => ({
    country: document.querySelector('#addrCountry').value,
    na: !!document.querySelector('.addr-editor .addr-na'),
    first: document.querySelector('.addr-editor .modal-body .addr-fld:nth-child(2) select')?.id,
    width: document.querySelector('.addr-editor').getBoundingClientRect().width,
  }));
  ok(fresh.country === 'SA' && fresh.na, `a new address starts on the shop's country with the National Address block (${JSON.stringify(fresh)})`);
  ok(fresh.width <= 640, `the editor is at most 640 px wide (${fresh.width})`);
  await window.fill('.addr-editor #addrLabel', 'Workshop');
  await fill('shortAddress', 'rrrd2929');
  await fill('buildingNumber', '2929');
  await fill('additionalNumber', '7241');
  await fill('line1', 'Prince Sultan Road');
  await fill('district', 'Al Olaya');
  await fill('city', 'Riyadh');
  await fill('postalCode', '1221');
  await fill('recipientName', 'Sample Recipient');
  const warn = await window.evaluate(() => {
    const el = document.querySelector('.addr-editor [data-warn-for="postalCode"]');
    return { hidden: el.hidden, text: el.textContent, prints: document.querySelector('#addrPrints').textContent };
  });
  ok(!warn.hidden && /5 digits/.test(warn.text), `a bad postal code is a note under the field (${warn.text})`);
  ok(warn.prints === '2929 Prince Sultan Road\nAl Olaya\nRiyadh 1221-7241\nRRRD2929', `"Prints as" is the formatted address (${JSON.stringify(warn.prints)})`);
  await window.click('.addr-editor [data-act="addr-save"]');
  await window.waitForSelector('.addr-editor', { state: 'detached', timeout: 10000 });
  ok(await window.evaluate(() => /Prince Sultan Road, Al Olaya, Riyadh 1221-7241, RRRD2929/.test(document.querySelector('#ceAddressBookWrap').textContent)),
    'the customer editor lists it as one formatted line');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForSelector('#ceAddrAdd', { state: 'detached', timeout: 10000 });
  const stored = await window.evaluate(() => clients.find((c) => c.id === 'CLI-addr').addresses);
  const ws = stored.find((r) => r.label === 'Workshop');
  ok(ws && ws.line1 === 'Prince Sultan Road' && ws.city === 'Riyadh' && ws.shortAddress === 'RRRD2929' && ws.country === 'SA' && ws.postalCode === '1221',
    `the stored row has its fields (${JSON.stringify(ws)})`);
  ok(ws.address === '2929 Prince Sultan Road\nAl Olaya\nRiyadh 1221-7241\nRRRD2929' && ws.textOf === ws.address, 'and the address text, for older builds');
  ok(ws.recipientName === 'Sample Recipient', 'and who receives it');
  const old = stored.find((r) => r.id === 'ADDR-old');
  ok(old && old.address === 'Sample Street near the sample mall, Jeddah' && !old.city, 'the old free-text row is untouched');
  const else1 = stored.find((r) => r.id === 'ADDR-else');
  ok(else1 && else1.address === 'Office 14, Sample Tower, Dubai', 'a row edited elsewhere is not rewritten by a customer save');

  // Reopen: the fields are there. Change the country.
  await window.evaluate(() => openClientEditor('CLI-addr'));
  await window.waitForSelector('.addr-edit', { timeout: 10000 });
  const rows = await window.evaluate(() => [...document.querySelectorAll('.addr-row')].map((r) => ({ state: r.dataset.addrState, text: r.textContent.replace(/\s+/g, ' ').trim() })));
  ok(rows.some((r) => r.state === 'unstructured' && /Not split into fields yet/.test(r.text)), 'the old row says it is not split into fields');
  ok(rows.some((r) => r.state === 'edited_elsewhere' && /Check the fields/.test(r.text) && /Edited on another device/.test(r.text)), 'the row edited elsewhere says so');
  const wsIdx = await window.evaluate(() => clients.find((c) => c.id === 'CLI-addr').addresses.findIndex((r) => r.label === 'Workshop'));
  await window.click(`.addr-edit[data-ai="${wsIdx}"]`);
  await window.waitForSelector('.addr-editor', { timeout: 10000 });
  const re = await window.evaluate(() => ({
    line1: document.querySelector('#addrF_line1').value, sa: document.querySelector('#addrF_shortAddress').value,
    country: document.querySelector('#addrCountry').value,
  }));
  ok(re.line1 === 'Prince Sultan Road' && re.sa === 'RRRD2929' && re.country === 'SA', `it reopens showing its fields (${JSON.stringify(re)})`);
  const saOrder = await window.evaluate(() => [...document.querySelectorAll('#addrFields [data-addr]')].map((i) => i.dataset.addr));
  await window.selectOption('.addr-editor #addrCountry', 'AE');
  const ae = await window.evaluate(() => ({
    na: !!document.querySelector('.addr-editor .addr-na'),
    order: [...document.querySelectorAll('#addrFields [data-addr]')].map((i) => i.dataset.addr),
    line1: document.querySelector('#addrF_line1').value,
    region: document.querySelector('label[for="addrF_region"]').textContent,
  }));
  ok(!ae.na, 'the UAE has no National Address block');
  ok(ae.order.join() === 'line1,line2,line3,district,city,region,postalCode' && ae.order.join() !== saOrder.join(),
    `and the field order changes (${saOrder.join()} → ${ae.order.join()})`);
  ok(ae.line1 === 'Prince Sultan Road' && ae.region === 'State / region', 'what was typed stays, and the region reads "State / region"');
  await window.click('.addr-editor [data-act="addr-cancel"]');
  await window.waitForSelector('.addr-editor', { state: 'detached', timeout: 10000 });

  // The old free-text row opens as its text.
  await window.click('.addr-edit[data-ai="0"]');
  await window.waitForSelector('.addr-editor', { timeout: 10000 });
  const unsplit = await window.evaluate(() => ({
    text: document.querySelector('#addrText')?.value, city: !!document.querySelector('#addrF_city'),
    offer: !!document.querySelector('#addrFillFields'),
  }));
  ok(unsplit.text === 'Sample Street near the sample mall, Jeddah' && !unsplit.city && unsplit.offer,
    `an old free-text row opens as its text with an offer to fill fields (${JSON.stringify(unsplit)})`);
  await window.click('#addrFillFields');
  const filled = await window.evaluate(() => ({ city: document.querySelector('#addrF_city')?.value, line1: document.querySelector('#addrF_line1')?.value }));
  ok(filled.city === '' && filled.line1 === '', 'filling fields starts empty: nothing is parsed out of the text');
  await window.click('.addr-editor [data-act="addr-cancel"]');

  // The row edited elsewhere shows the newer text and the message.
  const elseIdx = await window.evaluate(() => clients.find((c) => c.id === 'CLI-addr').addresses.findIndex((r) => r.id === 'ADDR-else'));
  await window.click(`.addr-edit[data-ai="${elseIdx}"]`);
  await window.waitForSelector('.addr-editor', { timeout: 10000 });
  const ee = await window.evaluate(() => document.querySelector('.addr-editor [data-addr-state="edited_elsewhere"]')?.textContent || '');
  ok(/Office 14, Sample Tower, Dubai/.test(ee) && /Edited on another device/.test(ee), 'a row edited elsewhere opens with the newer text and the message');
  await window.click('.addr-editor [data-act="addr-cancel"]');
  await window.click('#modalMount [data-act="cancel"]');

  // Edit Order's delivery picker.
  await window.evaluate(() => openOrderEditor('J-addr-1'));
  await window.waitForSelector('#oeAddressSelect', { timeout: 10000 });
  const pick = await window.evaluate(() => [...document.querySelectorAll('#oeAddressSelect option')].map((o) => ({ v: o.value, t: o.textContent })));
  const wsOpt = pick.find((o) => o.t.startsWith('Workshop'));
  ok(wsOpt && wsOpt.t === 'Workshop — 2929 Prince Sultan Road, Al Olaya, Riyadh 1221-7241, RRRD2929', `the delivery picker shows the formatted address (${wsOpt && wsOpt.t})`);
  await window.selectOption('#oeAddressSelect', { label: wsOpt.t });
  const delivery = await window.evaluate(() => document.querySelector('[data-f="deliveryAddress"]').value);
  ok(delivery === ws.address, 'picking it copies the plain address text onto the job');
  await window.evaluate(() => document.querySelector('#modalMount [data-act="cancel"]')?.click());

  // Arabic: the numbers and the phone stay left to right.
  await window.evaluate(() => { i18n.set('ar'); openClientEditor('CLI-addr'); });
  await window.waitForSelector('.addr-edit', { timeout: 10000 });
  await window.click(`.addr-edit[data-ai="${wsIdx}"]`);
  await window.waitForSelector('.addr-editor', { timeout: 10000 });
  const rtl = await window.evaluate(() => ({
    dir: document.documentElement.dir,
    ltr: ['postalCode', 'recipientPhone', 'buildingNumber', 'additionalNumber', 'shortAddress'].map((k) => document.querySelector('#addrF_' + k)?.getAttribute('dir')),
    city: document.querySelector('#addrF_city').getAttribute('dir'),
    title: document.querySelector('#addrEdTitle').textContent,
  }));
  ok(rtl.dir === 'rtl' && rtl.title === 'العنوان', `the app is in Arabic, right to left (${rtl.title})`);
  ok(rtl.ltr.every((d) => d === 'ltr') && rtl.city !== 'ltr', `phone, postal code and the numbers are dir=ltr (${rtl.ltr})`);
  await window.click('.addr-editor [data-act="addr-cancel"]');
  await window.evaluate(() => { document.querySelector('#modalMount [data-act="cancel"]')?.click(); i18n.set('en'); });

  ok(errors.length === 0, `nothing threw (${errors.join(' | ')})`);
  console.log('e2e-address-editor: ok');
} catch (err) {
  failed = true;
  console.error('e2e-address-editor FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
