/**
 * E2E smoke — a saved product price never changes silently.
 *
 * A product whose stored price differs from what today's rules give (as one
 * saved before the catalogue counted each part's quantity) keeps that price
 * through an edit that does not touch its pricing, and the editor says what
 * today's costs would give. An edit that does re-price it says "was → now"
 * before Save, and Save stores the new price. The Mac keeps the stored price
 * on an untouched save the same way. A part's unset prep/post time stays
 * unset through the editor (the shop's default, as a hint).
 *
 * Run: npm run test:e2e:pricekeep
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await switchTab(window, 'catalog-tab').catch(() => {});
  const seeded = await window.evaluate(() => {
    const p = {
      id: 'PROD-keep', nameEn: 'Stand', nameAr: '', description: 'old', defaultMargin: 30, priceTiers: [],
      parts: [{ id: 'PRT-1', name: 'leg', material: 'PETG', printWeight: 180, supportWeight: 0, printTime: 4.5, qty: 3, spoolCost: 85, spoolWeight: 1000 }],
      createdAt: '2026-10-01',
    };
    const today = KhaytProductPricing.priceProduct(p, { inventory, settings, consumables: typeof consumables !== 'undefined' ? consumables : [] });
    // Stored as an older rule left it: a third of today's figure.
    p.baseCost = Math.round(today.cost / 3 * 100) / 100;
    p.basePrice = Math.round(today.basePrice / 3 * 100) / 100;
    p.price = Math.round(today.price / 3 * 100) / 100;
    products.push(p); saveAll();
    return { stored: p.price, today: today.price };
  });
  ok(seeded.today > seeded.stored, `the stored price (${seeded.stored}) is below today's (${seeded.today})`);

  // An edit that does not touch pricing.
  await window.evaluate(() => openProductEditor('PROD-keep'));
  await window.waitForSelector('#prodPriceVal');
  const hint = await window.evaluate(() => ({ price: document.getElementById('prodPriceVal').textContent, why: document.getElementById('prodPriceWhy').textContent }));
  ok(/Saved price kept/.test(hint.why), `the editor shows the saved price and says today's would differ (${hint.price} ${hint.why})`);
  await window.fill('.modal [data-f="group"]', 'Stands');
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(400);
  const kept = await window.evaluate(() => { const p = products.find((x) => x.id === 'PROD-keep'); return { price: p.price, group: p.group }; });
  ok(kept.group === 'Stands' && kept.price === seeded.stored, `an edit that does not touch pricing keeps the saved price (${kept.price})`);

  // An edit that re-prices it.
  await window.evaluate(() => openProductEditor('PROD-keep'));
  await window.waitForSelector('#prodPriceVal');
  await window.fill('.modal [data-f="defaultMargin"]', '40');
  await window.dispatchEvent('.modal [data-f="defaultMargin"]', 'input');
  await window.waitForTimeout(200);
  const moved = await window.evaluate(() => document.getElementById('prodPriceWhy').textContent);
  ok(/was .+ → now /.test(moved), `a pricing edit says "was → now" before Save (${moved})`);
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(400);
  const repriced = await window.evaluate(() => products.find((x) => x.id === 'PROD-keep').price);
  ok(repriced > seeded.stored, `and Save stores the new price (${repriced})`);

  // A part that never said its prep/post time shows the shop's default as a
  // hint, not a typed 0, and saving leaves it unset (costed at the default).
  await window.evaluate(() => openProductEditor('PROD-keep'));
  await window.waitForSelector('.modal .part-row [data-f="prepTime"]');
  const prep = await window.evaluate(() => {
    const el = document.querySelector('.modal .part-row [data-f="prepTime"]');
    return { value: el.value, ph: el.placeholder, want: String(KhaytPrintRates.ratesFor({ settings }).prepTime) };
  });
  ok(prep.value === '' && prep.ph === prep.want, `an unset prep time is drawn empty with the default as its hint (${JSON.stringify(prep)})`);
  await window.fill('.modal .part-row [data-f="postTime"]', '2');
  await window.dispatchEvent('.modal .part-row [data-f="postTime"]', 'input');
  await window.fill('.modal .part-row [data-f="postTime"]', '');
  await window.dispatchEvent('.modal .part-row [data-f="postTime"]', 'input');
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(400);
  const part = await window.evaluate(() => products.find((x) => x.id === 'PROD-keep').parts[0]);
  ok(!('prepTime' in part) && !('postTime' in part), `a blank prep/post time saves as unset, not 0 (${JSON.stringify({ prepTime: part.prepTime, postTime: part.postTime })})`);

  // A new product is priced as before.
  const fresh = await window.evaluate(() => {
    const p = { id: 'PROD-new', nameEn: 'New', defaultMargin: 30, priceTiers: [], parts: [{ id: 'PRT-2', name: 'x', material: 'PLA', printWeight: 50, printTime: 1, qty: 2, spoolCost: 80, spoolWeight: 1000 }] };
    return KhaytProductPricing.priceProduct(p, { inventory, settings, consumables: typeof consumables !== 'undefined' ? consumables : [] }).price > 0;
  });
  ok(fresh, 'a new product still gets a computed price');

  console.log('e2e-product-price-keep: ok (untouched save keeps the stored price and says so; a pricing edit says was → now and stores it)');
} catch (err) {
  failed = true;
  console.error('e2e-product-price-keep FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
