/**
 * E2E smoke — consumables through the whole reorder chain, in a real window.
 *
 * The unit tests check the forecast and the wiring tests grep the source. Neither
 * can answer the question that actually matters here: when someone clicks the
 * button, does stock move?
 *
 * The chain has four links and three of them were built for filament, so this
 * drives all of it against real DOM: the modal renders → the draft button is
 * clicked → a purchase order exists → it is received through its own dialog →
 * the CONSUMABLE's stock goes up and the expense is not filament.
 *
 * Run: npm run test:e2e:consumables
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  // Purchase orders are a pro surface — #poSection is `pro-only`, so in any other
  // mode the whole receive path is display:none and nothing here is clickable.
  await window.evaluate(() => { settings.mode = 'pro'; applyMode(); saveAll(); });

  // Four shelves in four states, and completed orders to give two of them a rate.
  await window.evaluate(() => {
    consumables.length = 0;
    consumables.push(
      { id: 'CNS-IPA', name: 'Isopropyl', stock: 20, minStock: 1, unit: 'ml', cost: 0.1, usagePerHour: 6 },
      { id: 'CNS-BAG', name: 'Mailer bags', stock: 0, minStock: 0, unit: 'boxes', cost: 12, isPackaging: true },
      { id: 'CNS-GLUE', name: 'Glue stick', stock: 2, minStock: 10, unit: 'pcs', cost: 3 },
      { id: 'CNS-SAND', name: 'Sandpaper', stock: 500, minStock: 5, unit: 'sheets', cost: 1 },
    );
    const day = 86400000;
    for (let i = 1; i <= 3; i++) {
      printLog.push({
        id: 'E2E-CR-' + i, client: 'reorder e2e', status: 'completed',
        completedAt: new Date(Date.now() - i * day).toISOString(),
        printTime: 10, materialDeducted: true, packagingDeducted: true, parts: [],
      });
    }
    purchaseOrders.length = 0;
    expenses.length = 0;
    saveAll();
  });

  // ---- the modal, rendered for real ----
  await window.evaluate(() => openReorderSuggestions());
  await window.waitForSelector('.modal', { timeout: 5000 });

  const seen = await window.evaluate(() => {
    const heads = [...document.querySelectorAll('.modal h4')].map((h) => h.textContent.trim());
    const rows = [...document.querySelectorAll('.modal table')].pop();
    return { heads, text: rows ? rows.innerText : '' };
  });
  ok(seen.heads.some((h) => /consumab/i.test(h)), `consumables section rendered (${seen.heads.join('|')})`);
  ok(/Mailer bags/.test(seen.text), 'the empty shelf is listed');
  ok(/Glue stick/.test(seen.text), 'the below-minimum shelf is listed');
  ok(/Isopropyl/.test(seen.text), 'the forecast-to-deplete shelf is listed');
  ok(!/Sandpaper/.test(seen.text), 'a healthy shelf is left off the list');

  // The unit is the shop's own, and no consumable row claims grams.
  ok(/boxes/.test(seen.text), 'the unit "boxes" is shown');
  ok(!/\d+\s*g\b/.test(seen.text), `no consumable quantity claims grams:\n${seen.text}`);

  // ---- click the real button, confirm the real dialog ----
  const btn = await window.$('#reorderDraftPo');
  ok(!!btn, 'the draft-purchase-orders button is present');
  await btn.click();
  await window.waitForSelector('[data-act="ok"]', { timeout: 5000 });
  await window.click('[data-act="ok"]');
  await window.waitForTimeout(400);

  const pos = await window.evaluate(() => purchaseOrders.map((p) => ({
    kind: p.kind, itemId: p.itemId, itemName: p.itemName, qty: p.qty, unit: p.unit, status: p.status,
  })));
  const bagPo = pos.find((p) => p.itemId === 'CNS-BAG');
  const gluePo = pos.find((p) => p.itemId === 'CNS-GLUE');
  ok(pos.length >= 2, `draft POs created (${JSON.stringify(pos)})`);
  ok(gluePo && gluePo.kind === 'consumable', 'the glue PO is marked as a consumable order');
  ok(gluePo && gluePo.itemName === 'Glue stick', `the PO is named, not undefined (${gluePo && gluePo.itemName})`);
  ok(gluePo && gluePo.unit === 'pcs', 'the PO carries the unit');
  ok(gluePo && gluePo.qty === 8, `glue tops up to its minimum: 10 − 2 (${gluePo && gluePo.qty})`);
  ok(!bagPo || bagPo.qty !== 1000, 'no spool-sized default quantity leaked onto a consumable');

  // ---- receive it through the real dialog ----
  // Close the suggestions modal first: its overlay sits over the PO list, so the
  // receive button is in the DOM but not clickable.
  await window.click('.modal [data-act="cancel"]');
  await window.waitForSelector('.modal', { state: 'detached', timeout: 5000 });

  // ---- the badge on a drafted order ----
  // Every order the draft button writes is `status: 'draft'`, and the badge
  // renders t('po.status.' + po.status). i18n.t() falls back to the KEY, so a
  // missing entry does not degrade to English — it prints "po.status.draft" in
  // the table. Assert against the rendered badge rather than the locale file:
  // the key existing proves nothing if the status the code writes is a third
  // spelling. Any status reachable here must resolve.
  await window.evaluate(() => renderPurchaseOrders());
  const badges = await window.evaluate(() =>
    [...document.querySelectorAll('#poSection .po-badge')].map((b) => b.textContent.trim()));
  ok(badges.length >= 2, `the drafted orders have badges (${JSON.stringify(badges)})`);
  ok(!badges.some((b) => /^po\.status\./.test(b)),
    `no badge shows a raw locale key (${JSON.stringify(badges)})`);

  // ---- the status filter offers the statuses that exist ----
  // The filter compares po.status to the option value, so an option for a status
  // nothing writes can only ever empty the table. Drive the real <select> rather
  // than reading its markup: pick `draft` and the orders just drafted must survive
  // the filter. `pending` is asserted absent — it was the offered-but-unreachable
  // one, and its label borrowed a print-queue string besides.
  const opts = await window.evaluate(() =>
    [...document.querySelectorAll('#poStatusSel option')].map((o) => ({ v: o.value, t: o.textContent.trim() })));
  ok(opts.some((o) => o.v === 'draft'), `the filter offers draft (${JSON.stringify(opts)})`);
  ok(!opts.some((o) => o.v === 'pending'), `the filter does not offer pending (${JSON.stringify(opts)})`);
  ok(!opts.some((o) => /^(po|queue)\./.test(o.t)),
    `no option shows a raw locale key (${JSON.stringify(opts)})`);

  const draftRows = await window.evaluate(() => {
    const sel = document.querySelector('#poStatusSel');
    sel.value = 'draft';
    sel.dispatchEvent(new Event('change', { bubbles: true }));
    return document.querySelectorAll('#poSection .po-table tbody tr').length;
  });
  ok(draftRows >= 2, `filtering by draft keeps the drafted orders (${draftRows} rows)`);
  await window.evaluate(() => {
    const sel = document.querySelector('#poStatusSel');
    sel.value = '';
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  });

  const stockBefore = await window.evaluate(() => consumables.find((c) => c.id === 'CNS-GLUE').stock);
  await window.evaluate(() => {
    const po = purchaseOrders.find((p) => p.itemId === 'CNS-GLUE');
    po.status = 'ordered';
    saveAll(); renderPurchaseOrders();
  });
  await switchTab(window, 'inventory-tab');
  await window.waitForTimeout(200);
  const recvBtn = await window.$(`[data-act="po-receive"]`);
  ok(!!recvBtn, 'the receive button is present on the drafted order');
  await recvBtn.click();
  await window.waitForSelector('#poRecvWeight', { timeout: 5000 });

  const caption = await window.evaluate(() => {
    const lbl = [...document.querySelectorAll('.modal label')].find((l) => /\(/.test(l.textContent));
    return lbl ? lbl.textContent.trim() : '';
  });
  ok(/\(pcs\)/.test(caption), `the dialog asks in the shop's unit (got "${caption}")`);
  // The label must carry ONE unit. `po.weight_received` bakes "(g)" into 8 of the 9
  // locales, so appending to it produced "Weight received (g) (pcs)" — and called a
  // count of boxes a weight.
  ok(!/\(g\)/.test(caption), `no grams caption survives on a consumable: "${caption}"`);
  ok((caption.match(/\(/g) || []).length === 1, `the caption carries exactly one unit: "${caption}"`);

  const asked = await window.evaluate(() => +document.querySelector('#poRecvWeight').value);
  ok(asked === 8, `it offers the outstanding quantity, not 1000 (${asked})`);

  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(500);

  const after = await window.evaluate(() => ({
    stock: consumables.find((c) => c.id === 'CNS-GLUE').stock,
    spoolTouched: inventory.some((i) => i.id === 'CNS-GLUE'),
    po: purchaseOrders.find((p) => p.itemId === 'CNS-GLUE').status,
    exp: expenses.map((e) => ({ cat: e.category, amt: e.amount })),
  }));
  ok(after.stock === stockBefore + 8, `the CONSUMABLE was restocked ${stockBefore} → ${after.stock}`);
  ok(!after.spoolTouched, 'no spool row was invented for a consumable');
  ok(after.po === 'received', `the order completed rather than sticking at partial (${after.po})`);
  const filamentExp = after.exp.filter((e) => e.cat === 'filament');
  ok(filamentExp.length === 0, `glue is not booked as filament spend: ${JSON.stringify(after.exp)}`);
  ok(after.exp.some((e) => e.cat === 'other' && Math.abs(e.amt - 24) < 0.01),
    `the expense is 8 × 3 = 24 as general spend (${JSON.stringify(after.exp)})`);

  // ---- the filament path, drafted by the app rather than by this script ----
  //
  // A hand-built fixture proves nothing here: it can agree with the receive
  // handler while the code that really writes purchase orders disagrees, which
  // is exactly the state this repo shipped in. createPurchaseOrder wrote
  // `unitPrice` and the receipt read `unitCost`/`totalCost`, so every
  // auto-drafted spool was restocked and booked NO expense — invisible, because
  // the goods did arrive and nothing threw.
  //
  // So the order below comes out of maybeAutoDraftPurchaseOrders(): the boot-time
  // automation, running the real resolveReorderPrice → createPurchaseOrder chain
  // against a spool the app itself decides is short.
  const drafted = await window.evaluate(() => {
    const spool = inventory[0];
    // An 85/kg spool with 300 g left, against 800 g already committed by a job
    // in the queue. reorderSuggestions covers the shortfall: ceil(800 − 300) =
    // 500 g, rounded to the quarter-kilo the drafter buys in.
    spool.cost = 85;
    spool.spoolWeight = 1000;
    spool.weight = 300;
    spool.reorderPoint = 500;
    printLog.push({
      id: 'E2E-FIL-OPEN', client: 'reorder e2e', status: 'printing', parts: [
        { spoolId: spool.id, printWeight: 800, qty: 1 },
      ],
    });
    settings.autoDraftPo = true;
    // resolveReorderPrice prefers a supplier price-list match over the spool's
    // own cost, so a sample supplier quoting PLA would decide the rate instead.
    suppliers.length = 0;
    purchaseOrders.length = 0;   // the consumable orders have made their point
    expenses.length = 0;
    maybeAutoDraftPurchaseOrders();
    const po = purchaseOrders.find((p) => p.itemId === spool.id);
    if (po) { po.status = 'ordered'; saveAll(); renderPurchaseOrders(); }
    return po ? { id: po.id, qty: po.qty, unitPrice: po.unitPrice, spoolId: spool.id } : null;
  });
  ok(!!drafted, 'the auto-drafter produced a filament purchase order');
  ok(drafted.qty === 500, `it asks for the 500 g shortfall, rounded to a quarter kilo (${drafted.qty})`);
  // The rate the app resolved for itself: 85 / 1000 g. If this is undefined the
  // order carries no price at all and the receipt below cannot book anything.
  ok(Math.abs(drafted.unitPrice - 0.085) < 1e-9,
    `the drafted order carries a per-gram price (${drafted.unitPrice})`);

  // `po.weight_received` already ends in "(g)" in 8 of 9 locales, so the caption
  // must NOT have a unit appended to it here either.
  const filBefore = await window.evaluate((id) => +inventory.find((i) => i.id === id).weight || 0, drafted.spoolId);
  await window.click(`[data-act="po-receive"][data-id="${drafted.id}"]`);
  await window.waitForSelector('#poRecvWeight', { timeout: 5000 });
  const filCaption = await window.evaluate(() => {
    const lbl = [...document.querySelectorAll('.modal label')].find((l) => /\(/.test(l.textContent));
    return lbl ? lbl.textContent.trim() : '';
  });
  ok(/\(g\)/.test(filCaption), `filament still asks in grams (got "${filCaption}")`);
  ok((filCaption.match(/\(/g) || []).length === 1, `the filament caption carries exactly one unit: "${filCaption}"`);
  const filAsked = await window.evaluate(() => +document.querySelector('#poRecvWeight').value);
  ok(filAsked === 500, `it offers what was ordered, not a flat 1000 g (${filAsked})`);

  // Take 200 of the 500 first: a part shipment must book its own share and leave
  // the order open, with a progress bar that can finally measure itself.
  await window.evaluate(() => { document.querySelector('#poRecvWeight').value = '200'; });
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(500);
  const partial = await window.evaluate((d) => ({
    w: +inventory.find((i) => i.id === d.spoolId).weight || 0,
    status: purchaseOrders.find((p) => p.id === d.id).status,
    exp: expenses.filter((e) => e.category === 'filament').map((e) => e.amount),
    progress: document.querySelector('.po-table')?.innerText || '',
  }), drafted);
  ok(partial.w === filBefore + 200, `the spool was restocked ${filBefore} → ${partial.w}`);
  ok(partial.status === 'partial', `200 of 500 leaves the order open (${partial.status})`);
  ok(partial.exp.length === 1 && Math.abs(partial.exp[0] - 17) < 0.01,
    `the part shipment books 200 × 0.085 = 17 (${JSON.stringify(partial.exp)})`);
  ok(/200g \/ 500g/.test(partial.progress),
    `the progress row counts against what was ordered:\n${partial.progress}`);

  // And the rest, which must complete the order and total to the spool's price.
  await window.click(`[data-act="po-receive"][data-id="${drafted.id}"]`);
  await window.waitForSelector('#poRecvWeight', { timeout: 5000 });
  const restAsked = await window.evaluate(() => +document.querySelector('#poRecvWeight').value);
  ok(restAsked === 300, `it offers the outstanding 300 g (${restAsked})`);
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(500);
  const filAfter = await window.evaluate((d) => ({
    w: +inventory.find((i) => i.id === d.spoolId).weight || 0,
    status: purchaseOrders.find((p) => p.id === d.id).status,
    exp: expenses.filter((e) => e.category === 'filament'),
  }), drafted);
  ok(filAfter.w === filBefore + 500, `the whole order reached the shelf (${filAfter.w})`);
  ok(filAfter.status === 'received', `the order completed rather than sticking at partial (${filAfter.status})`);
  ok(filAfter.exp.length === 2, `each receipt booked its own expense (${filAfter.exp.length})`);
  // The figure that used to be zero: 500 g of an 85/kg spool is 42.50, and it is
  // material spend — the number pricing and the per-kilo analytics are built on.
  const filTotal = filAfter.exp.reduce((s, e) => s + (+e.amount || 0), 0);
  ok(Math.abs(filTotal - 42.5) < 0.01, `the received half-kilo cost 42.50 (${filTotal})`);
  ok(filAfter.exp.every((e) => e.poId === drafted.id), 'each expense is traceable back to its order');

  console.log('e2e-consumable-reorder: ok (modal → draft → receive → restock, units and expense intact; an auto-drafted filament order books its own cost)');
} catch (err) {
  failed = true;
  console.error('e2e-consumable-reorder FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
