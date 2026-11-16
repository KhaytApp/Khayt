/**
 * E2E: the job edit sheet (S1 · Figma 75:583, 95:461, 95:596), with real
 * clicks. Sample data only.
 *
 *   - The job page's Edit opens the sheet: Job · Parts · Price, total pinned.
 *   - Name and priority save through lib/order-edit.js applyJobEdit.
 *   - A part added to or edited on a job the customer has seen asks
 *     keep-or-new (95:461): Keep leaves the price, Use takes the new one.
 *   - A draft quote's price follows its parts without asking.
 *   - A discount that drops the bill below what was paid shows the refusal
 *     line and Save is disabled (95:596); taking it back clears it.
 *   - A finished job offers no new part and no Remove.
 *   - Jobs › New job opens the same sheet empty: Take job waits for a part,
 *     records the job as the sheet priced it and opens its page; Save as
 *     quote records a quote.
 *
 * Run: npm run test:e2e:jobsheet
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
const job = (id) => window.evaluate((i) => JSON.parse(JSON.stringify(printLog.find((o) => o.id === i))), id);
const shot = async (name) => { if (process.env.E2E_SHOTS) await window.locator('#modalMount .modal').last().screenshot({ path: `${process.env.E2E_SHOTS}/${name}.png` }); };

const openSheet = async (id) => {
  await switchTab(window, 'logs-tab');
  await window.click(`.row-more-btn[data-id="${id}"]`);
  await window.click(`.row-actions-menu[data-for="${id}"] [data-act="job-page"]`);
  await window.waitForSelector('#jobPage:not([hidden]) .jp-title', { timeout: 5_000 });
  await window.click('#jobPage [data-jp="edit"]');
  await window.waitForSelector('#modalMount .job-sheet', { state: 'visible', timeout: 5_000 });
};
const save = () => window.click('#modalMount .job-sheet-modal [data-act="save"]');
const closed = () => window.waitForFunction(() => !document.querySelector('#modalMount .job-sheet'), null, { timeout: 5_000 });
const addPart = async (name, grams, hours) => {
  await window.fill('#modalMount [data-js="pName"]', name);
  await window.fill('#modalMount [data-js="pGrams"]', String(grams));
  await window.fill('#modalMount [data-js="pHours"]', String(hours));
  await window.click('#modalMount [data-js="pAdd"]');
};

try {
  await dismissWizard(window);
  await window.evaluate(() => {
    settings.mode = 'professional'; settings.currency = 'SAR'; settings.enableVat = false;
    KhaytShell.applyMode();
    inventory.unshift({ id: 'F-JS', material: 'PLA Black', color: '#111111', cost: 90, spoolWeight: 1000, weight: 1000 });
    const part = { id: 'P-1', name: 'body.stl', material: 'PLA Black', filamentId: 'F-JS', qty: 1, printWeight: 100, printTime: 2,
      spoolCost: 90, spoolWeight: 1000 };
    // Costed as the app costs it, so a re-costed part moves from a true figure.
    const rated = KhaytPrintRates.withRates(part, { settings });
    part.unitCost = KhaytCalculatorCost.computePartBaseCost(rated, { inventory, settings });
    part.baseCost = part.unitCost;
    const base = (id, over) => Object.assign({
      id, jobNumber: id, status: 'pending', currency: 'SAR', date: '2026-11-12', project: 'Sample ' + id,
      price: 340, paidAmount: 0, discountPct: 0, material: 'PLA Black', printTime: 2,
      statusHistory: [{ status: 'pending', at: '2026-11-12T08:00:00Z' }],
      parts: [JSON.parse(JSON.stringify(part))],
    }, over || {});
    printLog.unshift(
      base('JS-SEEN'),
      base('JS-USE'),
      base('JS-MK'),
      // Taken in US dollars at 3.75 SAR each: the same job as JS-MK, priced in
      // the job's currency (newOrder divides the shop-currency cost by fxRate).
      // It carries the markup it was taken at, as newOrder stores it: a markup
      // is never worked backwards through a rate (order-edit.js marginOf).
      base('JS-USD', { currency: 'USD', fxRate: 3.75, marginPct: 100, price: Math.round(340 / 3.75 * 100) / 100 }),
      base('JS-DRAFT', { status: 'quote', statusHistory: [{ status: 'quote', at: '2026-11-12T08:00:00Z' }] }),
      base('JS-PAID', { paidAmount: 300, paidAt: '2026-11-12T09:00:00Z' }),
      base('JS-DONE', { status: 'completed', materialDeducted: true, costBasis: 100 }),
    );
    saveAll();
    return flushSave();
  });

  // ── Job fields ───────────────────────────────────────────────────────────
  await openSheet('JS-SEEN');
  ok(/Parts · 1/i.test(await window.textContent('#modalMount [data-js="partsHead"]')), 'the sheet lists the job\'s parts');
  ok(/340/.test(await window.textContent('#modalMount [data-js="total"]')), 'the total is pinned at the foot (340)');
  ok(await window.evaluate(() => document.querySelector('#modalMount [data-js="fixed"]').hidden), 'a price worked from its parts carries no "fixed" note');
  await shot('job-sheet');
  await window.fill('#modalMount [data-js="project"]', 'Renamed sample');
  await window.click('#modalMount [data-js-pr="high"]');
  await save(); await closed();
  let j = await job('JS-SEEN');
  ok(j.project === 'Renamed sample' && j.priorityLevel === 'high', 'name and priority saved through applyJobEdit');
  ok(j.price === 340, 'the price did not move');

  // ── Keep the price the customer saw ──────────────────────────────────────
  await window.click('#jobPage [data-jp="edit"]');
  await window.waitForSelector('#modalMount .job-sheet', { state: 'visible', timeout: 5_000 });
  await addPart('clip.stl', 50, 1);
  ok(/Parts · 2/i.test(await window.textContent('#modalMount [data-js="partsHead"]')), 'Add part puts a second part in the list');
  await save();
  await window.waitForSelector('#modalMount .js-ask', { state: 'visible', timeout: 5_000 });
  await shot('job-sheet-ask');
  ok(/340/.test(await window.textContent('#modalMount .js-ask [data-ask="keep"]')), 'the customer has seen the price: Keep 340 is offered');
  await window.click('#modalMount .js-ask [data-ask="keep"]');
  await closed();
  j = await job('JS-SEEN');
  ok(j.parts.length === 2 && j.price === 340, `Keep: two parts, the price stays 340 (${j.price})`);
  ok(j.parts[1].baseCost > 0 && j.parts[1].filamentId === 'F-JS', 'the new part is costed off its filament');
  await window.click('#jobPage [data-jp="edit"]');
  await window.waitForSelector('#modalMount [data-js="fixed"]:not([hidden])', { timeout: 5_000 });
  ok(/fixed/.test(await window.textContent('#modalMount [data-js="fixed"]')), 'after Keep, the sheet says the price is fixed');
  await window.click('#modalMount .job-sheet-modal [data-act="cancel"]');
  await closed();

  // ── Use the new price (a job whose price is still its parts' arithmetic;
  //    after Keep the price is a typed one, and the rule leaves it as typed) ──
  await window.click('#jobPage [data-jp="back"]');
  await openSheet('JS-USE');
  await window.click('#modalMount [data-js-edit="0"]');
  await window.fill('#modalMount [data-js="pGrams"]', '150');
  await window.click('#modalMount [data-js="pAdd"]');
  await save();
  await window.waitForSelector('#modalMount .js-ask', { state: 'visible', timeout: 5_000 });
  await window.click('#modalMount .js-ask [data-ask="new"]');
  await closed();
  j = await job('JS-USE');
  ok(j.price > 340 && j.parts[0].printWeight === 150 && j.parts.length === 1, `Use: a part edited in place, the price follows it (${j.price})`);
  await window.click('#jobPage [data-jp="back"]');

  // ── A draft quote follows its parts ──────────────────────────────────────
  await openSheet('JS-DRAFT');
  await addPart('lid.stl', 40, 1);
  await save(); await closed();
  ok(await window.evaluate(() => !document.querySelector('#modalMount .js-ask')), 'a draft quote is not asked');
  j = await job('JS-DRAFT');
  ok(j.parts.length === 2 && j.price > 340, `its price follows the new part (${j.price})`);
  await window.click('#jobPage [data-jp="back"]');

  // ── The paid floor ───────────────────────────────────────────────────────
  await openSheet('JS-PAID');
  await window.fill('#modalMount [data-js="discountPct"]', '50');
  await window.waitForSelector('#modalMount .js-refused:not([hidden])', { timeout: 5_000 });
  const why = await window.textContent('#modalMount .js-refused');
  ok(/already paid/.test(why) && /300/.test(why), `a 50 % discount on a job with 300 paid is refused live (${why.trim()})`);
  ok(await window.isDisabled('#modalMount .job-sheet-modal [data-act="save"]'), 'Save is disabled while it would be refused');
  await shot('job-sheet-refused');
  await window.fill('#modalMount [data-js="discountPct"]', '0');
  ok(await window.isEnabled('#modalMount .job-sheet-modal [data-act="save"]'), 'with the discount back, Save comes back');
  await window.click('#modalMount .job-sheet-modal [data-act="cancel"]');
  await closed();
  j = await job('JS-PAID');
  ok(j.paidAmount === 300 && j.price === 340 && !j.discountPct, 'the paid job is unchanged');
  await window.click('#jobPage [data-jp="back"]');

  // ── Markup (#2494's applyMarkup) ─────────────────────────────────────────
  await openSheet('JS-MK');
  const mk0 = await window.inputValue('#modalMount [data-js="margin"]');
  ok(mk0 !== '' && Number(mk0) > 0, `Markup is a field, holding the markup the job was priced at (${mk0})`);
  await window.fill('#modalMount [data-js="margin"]', '-5');
  await window.waitForSelector('#modalMount .js-refused:not([hidden])', { timeout: 5_000 });
  ok(/0 or more/.test(await window.textContent('#modalMount .js-refused')), 'a negative markup is refused in its own words');
  await window.fill('#modalMount [data-js="margin"]', '200');
  await window.waitForFunction(() => document.querySelector('#modalMount .js-refused').hidden, null, { timeout: 5_000 });
  const shown = await window.textContent('#modalMount [data-js="total"]');
  ok(!/340/.test(shown), `the new total shows before saving (${shown.trim()})`);
  await save();
  await window.waitForSelector('#modalMount .js-ask', { state: 'visible', timeout: 5_000 });
  ok(/seen this job/.test(await window.textContent('#modalMount .js-ask')), 'the customer has seen the price: the sheet asks first');
  await shot('job-sheet-markup-ask');
  await window.click('#modalMount .js-ask [data-ask="cancel"]');
  ok(await window.evaluate(() => !!document.querySelector('#modalMount .job-sheet')), 'Cancel keeps the sheet open');
  ok((await job('JS-MK')).price === 340, 'and saves nothing');
  await save();
  await window.waitForSelector('#modalMount .js-ask', { state: 'visible', timeout: 5_000 });
  await window.click('#modalMount .js-ask [data-ask="change"]');
  await closed();
  j = await job('JS-MK');
  ok(j.marginPct === 200 && j.price !== 340, `Change the price: markup 200 stored, the price worked again from cost (${j.price})`);
  ok(shown.replace(/[^0-9.]/g, '').includes(j.price.toFixed(2)), 'the price saved is the total the sheet showed');
  await window.click('#jobPage [data-jp="back"]');

  // A job in another currency: the cost is in the shop's (SAR), the price in
  // the job's (USD at 3.75). At the same markup its price is JS-MK's divided
  // by the rate, not multiplied (beta.38 review: about 14x too high).
  const sarAt200 = j.price;
  await openSheet('JS-USD');
  const mkUsd = await window.inputValue('#modalMount [data-js="margin"]');
  ok(mkUsd === '100', `a USD job shows the markup it was taken at (${mkUsd})`);
  await window.fill('#modalMount [data-js="margin"]', '200');
  await window.waitForFunction(() => document.querySelector('#modalMount .js-refused').hidden, null, { timeout: 5_000 });
  await save();
  await window.waitForSelector('#modalMount .js-ask', { state: 'visible', timeout: 5_000 });
  await window.click('#modalMount .js-ask [data-ask="change"]');
  await closed();
  j = await job('JS-USD');
  ok(j.marginPct === 200 && j.currency === 'USD' && j.fxRate === 3.75, 'the USD job keeps its currency and rate');
  ok(Math.abs(j.price - sarAt200 / 3.75) <= 0.02,
    `markup 200 on the USD job is the SAR price divided by 3.75 (${j.price} vs ${(sarAt200 / 3.75).toFixed(2)})`);
  await window.click('#jobPage [data-jp="back"]');
  await openSheet('JS-SEEN');
  ok(await window.inputValue('#modalMount [data-js="margin"]') === '', 'a typed price has no markup to show');
  await window.fill('#modalMount [data-js="margin"]', '80');
  await window.waitForSelector('#modalMount .js-refused:not([hidden])', { timeout: 5_000 });
  ok(/price was typed/.test(await window.textContent('#modalMount .js-refused')), 'a markup on a typed price is refused in its own words, not the parts note');
  ok(await window.isDisabled('#modalMount .job-sheet-modal [data-act="save"]'), 'and Save waits');
  await window.click('#modalMount .job-sheet-modal [data-act="cancel"]');
  await closed();
  await window.click('#jobPage [data-jp="back"]');
  await openSheet('JS-PAID');
  await window.fill('#modalMount [data-js="margin"]', '0');
  await window.waitForSelector('#modalMount .js-refused:not([hidden])', { timeout: 5_000 });
  ok(/already paid/.test(await window.textContent('#modalMount .js-refused')), 'a markup that takes the price under what was paid is refused');
  await window.click('#modalMount .job-sheet-modal [data-act="cancel"]');
  await closed();
  await window.click('#jobPage [data-jp="back"]');

  // ── A finished job ───────────────────────────────────────────────────────
  await openSheet('JS-DONE');
  ok(await window.evaluate(() => document.querySelector('#modalMount [data-js="addRow"]').hidden), 'a finished job offers no new part');
  ok(await window.evaluate(() => !document.querySelector('#modalMount [data-js-rm]')), 'and no Remove');

  await window.click('#modalMount .job-sheet-modal [data-act="cancel"]');
  await closed();
  await window.click('#jobPage [data-jp="back"]');

  // ── New job: the same sheet, empty ───────────────────────────────────────
  const before = await window.evaluate(() => printLog.length);
  await switchTab(window, 'logs-tab');
  await window.click('#btnNewJobSheet');
  await window.waitForSelector('#modalMount .job-sheet', { state: 'visible', timeout: 5_000 });
  ok(/New job/.test(await window.textContent('#modalMount #modalTitle')), 'Jobs › New job opens the sheet as New job');
  ok(await window.isDisabled('#modalMount .job-sheet-modal [data-act="save"]'), 'with no part yet, Take job waits');
  ok(await window.evaluate(() => document.querySelector('#modalMount .js-refused')?.hidden !== false), 'and nothing is shown as refused');
  await window.fill('#modalMount [data-js="project"]', 'New sample');
  await addPart('new.stl', 80, 1.5);
  await window.click('#modalMount [data-js-pr="urgent"]');
  const mkShown = await window.textContent('#modalMount [data-js="total"]');
  ok(await window.isEnabled('#modalMount .job-sheet-modal [data-act="save"]') && /\d/.test(mkShown), `a part makes it ready, with a total (${mkShown.trim()})`);
  await shot('job-sheet-new');
  await save(); await closed();
  const made = await window.evaluate(() => JSON.parse(JSON.stringify(printLog[0])));
  ok(made.project === 'New sample' && made.status === 'pending' && made.parts.length === 1, 'Take job records a pending job with its part');
  ok(made.priorityLevel === 'urgent', 'at the priority picked');
  ok(mkShown.replace(/[^\d.]/g, '').startsWith(String(made.price.toFixed(2)).replace(/[^\d.]/g, '')), `the job is priced as the sheet showed (${made.price})`);
  await window.waitForSelector('#jobPage:not([hidden]) .jp-title', { timeout: 5_000 });
  ok((await window.textContent('#jobPage .jp-title')).includes('New sample'), 'and its job page opens');
  await window.click('#jobPage [data-jp="back"]');

  await window.click('#btnNewJobSheet');
  await window.waitForSelector('#modalMount .job-sheet', { state: 'visible', timeout: 5_000 });
  await window.fill('#modalMount [data-js="project"]', 'Quoted sample');
  await addPart('q.stl', 30, 0.5);
  await window.click('#modalMount [data-js="asQuote"]');
  await closed();
  const quoted = await window.evaluate(() => JSON.parse(JSON.stringify(printLog[0])));
  ok(quoted.project === 'Quoted sample' && quoted.status === 'quote', 'Save as quote records a quote');
  ok(await window.evaluate(() => printLog.length) === before + 2, 'two jobs were added, no more');

  console.log('e2e-job-sheet: ok');
} catch (err) {
  failed = true;
  console.error('e2e-job-sheet FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
