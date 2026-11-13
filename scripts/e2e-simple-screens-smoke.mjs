/**
 * E2E smoke — Simple's reduced Loyalty, Expenses and Money screens (S4 cards 3–5,
 * lib/feature-tiers.js SIMPLE_MAP rows `loyalty`, `expenses`, `money`).
 *
 * With real clicks it switches the shop to Simple in Settings › General, then:
 *   - Pricing & Tax › Loyalty is the small card: on/off and up to three tiers
 *     by completed orders; "Add tier" greys at three; Remove, Add and an edit
 *     save; a tier Professional gave a spend bar is read-only and kept;
 *   - Expenses opens (it was hidden in Simple) as a short list with this
 *     month's total, and "Add expense" files one;
 *   - Analytics is "Money": earned / owed / spent / VAT tiles, who owes me,
 *     best customers, top products — and a name opens the jobs behind it;
 * and switches back with a click to check Professional is unchanged.
 *
 * Run: npm run test:e2e:simplescreens
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  const visible = (sel) => window.evaluate((s) => {
    const el = document.querySelector(s);
    if (!el) return false;
    for (let n = el; n && n !== document.body; n = n.parentElement) {
      if (getComputedStyle(n).display === 'none') return false;
    }
    return true;
  }, sel);
  const text = (sel) => window.evaluate((s) => document.querySelector(s)?.innerText?.trim() ?? null, sel);
  const clearToasts = () => window.evaluate(() => document.querySelectorAll('.toast, #toastContainer > *').forEach((n) => n.remove()));
  const nav = async (tab) => { await clearToasts(); await window.click(`.tab-btn[data-tab="${tab}"]`); };
  const pane = async (section) => {
    await nav('settings-tab');
    await window.click(`.settings-nav-item[data-settings-section="${section}"]`);
  };
  const clickMode = async (id) => { await pane('general'); await window.click(id); await window.waitForTimeout(200); };

  // A sample shop: three tiers, two customers, jobs and expenses this month, VAT on.
  await window.evaluate(() => {
    const day = (d) => `${localMonthStr()}-${String(d).padStart(2, '0')}`;
    const today = localDateStr();
    const d = (n) => (day(n) > today ? today : day(n));
    settings.enableVat = true; settings.vatRate = 15;
    settings.loyaltyEnabled = true;
    settings.loyaltyTiers = [
      { name: 'Regular', minOrders: 3, minSpend: 0, discountPct: 5 },
      { name: 'Silver', minOrders: 10, minSpend: 0, discountPct: 8 },
      { name: 'Gold', minOrders: 25, minSpend: 0, discountPct: 12 },
    ];
    clients.push({ id: 'C-najd', nameEn: 'Najd Architects' }, { id: 'C-rsg', nameEn: 'Red Sea Global' });
    printLog.push(
      { id: 'ORD-m1', project: 'Facade model', clientId: 'C-rsg', client: 'Red Sea Global', status: 'completed', date: d(2), price: 1150, paidAmount: 1150, paymentStatus: 'paid', parts: [] },
      { id: 'ORD-m2', project: 'Site model', clientId: 'C-najd', client: 'Najd Architects', status: 'completed', date: d(1), price: 2300, paidAmount: 0, paymentStatus: 'unpaid', parts: [] },
    );
    expenses.push(
      { id: 'EXP-1', date: d(1), category: 'other', amount: 1500, note: 'Workshop rent' },
      { id: 'EXP-2', date: d(1), category: 'filament', amount: 640, note: 'Filament, PLA+ 10 kg' },
    );
    saveAll();
    renderLoyaltyTiersSettings();
  });

  // ── Professional, before ──
  await clickMode('#btnModePro');
  const proSnapshot = async () => {
    await pane('pricing');
    const loyaltyEditor = await visible('#loyaltyTiersSection');
    const loyaltySimple = await visible('#loyaltySimple');
    await nav('expenses-tab');
    const expTracker = await visible('#expenseTable');
    const expSimple = await visible('#expSimple');
    const proTag = await visible('#tabbtn-expenses-tab .khayt-pro');
    await nav('analytics-tab');
    const anLabel = await text('#tabbtn-analytics-tab .nav-label');
    const anPro = await visible('#analyticsProWrap');
    const anToolbar = await visible('#btnTaxExport');
    const money = await visible('#moneyPage');
    return { loyaltyEditor, loyaltySimple, expTracker, expSimple, proTag, anLabel, anPro, anToolbar, money };
  };
  const before = await proSnapshot();
  ok(before.loyaltyEditor && !before.loyaltySimple, 'Professional: the full loyalty editor, not the small card');
  ok(before.expTracker && !before.expSimple && before.proTag, 'Professional: the full expense tracker with its PRO tag');
  ok(before.anLabel === 'Analytics' && before.anPro && before.anToolbar && !before.money, `Professional: Analytics as before (${before.anLabel})`);

  // ── Simple, by clicking the mode switch ──
  await clickMode('#btnModeSimple');
  ok(await window.evaluate(() => settings.mode) === 'simple', 'the Simple pill switches the shop to Simple');

  // Card 3 · Loyalty
  await pane('pricing');
  ok(await visible('#loyaltySimple') && !(await visible('#loyaltyTiersSection')), 'Simple: Pricing & Tax shows the small loyalty card, not the full editor');
  const loy = () => window.evaluate(() => ({
    rows: [...document.querySelectorAll('#loyaltySimple tbody tr')].map((tr) => tr.querySelector('.sm-loy-name')?.value ?? tr.querySelector('th').innerText),
    addDisabled: document.querySelector('#loyaltySimple [data-act="loy-add"]').disabled,
    count: document.getElementById('loyaltySimpleCount').innerText,
    pill: document.querySelector('#loyaltySimple [data-act="loy-toggle"]').getAttribute('aria-checked'),
    heads: [...document.querySelectorAll('#loyaltySimple thead th')].map((th) => th.textContent.trim()),
  }));
  let l = await loy();
  ok(JSON.stringify(l.rows) === '["Regular","Silver","Gold"]' && l.count === '3 of 3 tiers' && l.addDisabled, `three tiers; "Add tier" greyed at three (${JSON.stringify(l)})`);
  ok(l.heads.slice(0, 3).join('|') === 'Tier|After|Discount' && l.pill === 'true', 'columns Tier · After · Discount; the switch says On');
  await window.click('#loyaltySimple tbody tr:nth-child(3) [data-act="loy-remove"]');
  l = await loy();
  ok(l.rows.length === 2 && !l.addDisabled && l.count === '2 of 3 tiers', `Remove takes Gold off and frees "Add tier" (${l.count})`);
  await window.click('#loyaltySimple [data-act="loy-add"]');
  l = await loy();
  ok(l.rows.length === 3 && l.addDisabled, `Add tier adds a third (${JSON.stringify(l.rows)})`);
  await window.fill('#loyaltySimple tbody tr:nth-child(3) .sm-loy-name', 'Gold');
  await window.fill('#loyaltySimple tbody tr:nth-child(3) .sm-loy-disc', '12');
  await window.press('#loyaltySimple tbody tr:nth-child(3) .sm-loy-disc', 'Tab');
  const saved = await window.evaluate(() => settings.loyaltyTiers.map((t) => `${t.name}:${t.minOrders}:${t.discountPct}`));
  ok(JSON.stringify(saved) === '["Regular:3:5","Silver:10:8","Gold:15:12"]', `edits save to settings.loyaltyTiers (${JSON.stringify(saved)})`);
  await window.click('#loyaltySimple [data-act="loy-toggle"]');
  const off = await window.evaluate(() => ({ on: settings.loyaltyEnabled, box: document.getElementById('set_loyaltyEnabled').checked, pill: document.querySelector('#loyaltySimple [data-act="loy-toggle"]').getAttribute('aria-checked') }));
  ok(!off.on && !off.box && off.pill === 'false', `the switch turns loyalty off, and the pane's own box agrees (${JSON.stringify(off)})`);
  await window.click('#loyaltySimple [data-act="loy-toggle"]');
  // A tier made in Professional with a spend bar: read-only here, never dropped.
  await window.evaluate(() => { settings.loyaltyTiers.push({ name: 'VIP', minOrders: 0, minSpend: 5000, discountPct: 20 }); saveAll(); renderLoyaltyTiersSettings(); });
  const ro = await window.evaluate(() => {
    const tr = document.querySelector('#loyaltySimple tbody tr:last-child');
    return { inputs: tr.querySelectorAll('input').length, remove: !!tr.querySelector('[data-act="loy-remove"]'), text: tr.innerText, count: document.getElementById('loyaltySimpleCount').innerText };
  });
  ok(ro.inputs === 0 && !ro.remove && /VIP/.test(ro.text) && /Set in Professional/.test(ro.text) && ro.count === '4 tiers', `a Professional tier is shown read-only (${JSON.stringify(ro)})`);

  // Card 4 · Expenses
  ok(await visible('#tabbtn-expenses-tab'), 'Simple: Expenses is in the sidebar');
  ok(!(await visible('#tabbtn-expenses-tab .khayt-pro')), 'Simple: …without a PRO tag');
  await nav('expenses-tab');
  ok(await visible('#expSimple') && !(await visible('#expenseTable')) && !(await visible('#btnAddExpense')), 'Simple: Expenses is the short list, not the tracker');
  ok(await window.evaluate(() => !document.getElementById('expenses-tab').classList.contains('sm-gated')), 'Simple: Expenses is not the "Part of Professional" panel');
  const exp = () => window.evaluate(() => ({
    total: document.getElementById('expSimpleTotal').innerText,
    rows: [...document.querySelectorAll('#expSimpleList .sm-list-row')].map((r) => `${r.querySelector('.sm-list-name').innerText}=${r.querySelector('.sm-num').innerText}`),
  }));
  let e = await exp();
  ok(/2,140\.00/.test(e.total) && e.rows.length === 2 && e.rows.includes('Workshop rent=1,500.00'), `this month's expenses and total (${JSON.stringify(e)})`);
  await window.click('#btnSimpleAddExpense');
  await window.waitForSelector('#smExpAmount');
  await window.fill('#smExpAmount', '270');
  await window.fill('#smExpNote', 'Nozzles ×4');
  await window.selectOption('#smExpCategory', 'maintenance');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForTimeout(200);
  e = await exp();
  ok(/2,410\.00/.test(e.total) && e.rows.length === 3 && e.rows.includes('Nozzles ×4=270.00'), `"Add expense" files one and the total follows (${JSON.stringify(e)})`);
  ok(await window.evaluate(() => expenses.some((x) => x.note === 'Nozzles ×4' && x.amount === 270 && x.category === 'maintenance')), 'the expense is in the book');

  // Card 5 · Money
  ok(await text('#tabbtn-analytics-tab .nav-label') === 'Money', 'Simple: the Analytics tab is called Money');
  await nav('analytics-tab');
  ok(await visible('#moneyPage') && !(await visible('#analyticsProWrap')) && !(await visible('#btnTaxExport')), 'Simple: the one-page Money summary, without the analytics toolbar');
  ok(await window.evaluate(() => !document.getElementById('analytics-tab').classList.contains('sm-gated')), 'Simple: Money is not the "Part of Professional" panel');
  const money = await window.evaluate(() => ({
    earned: document.querySelector('#moneyEarned .sm-tile-value')?.innerText,
    earnedSub: document.querySelector('#moneyEarned .sm-tile-sub')?.innerText,
    owed: document.querySelector('#moneyOwed .sm-tile-value')?.innerText,
    spent: document.querySelector('#moneySpent .sm-tile-value')?.innerText,
    spentSub: document.querySelector('#moneySpent .sm-tile-sub')?.innerText,
    vat: !!document.getElementById('moneyVat'),
    who: [...document.querySelectorAll('#moneyWhoOwes li')].map((li) => li.innerText.replace(/\s+/g, ' ')),
    best: [...document.querySelectorAll('#moneyBest li')].map((li) => li.innerText.replace(/\s+/g, ' ')),
  }));
  ok(money.earned === '3,000' && money.earnedSub === 'from 2 jobs', `Earned this month, net of VAT (${money.earned}, ${money.earnedSub})`);
  ok(money.owed === '2,300' && money.spent === '2,410' && money.spentSub === '3 expenses', `Owed and Spent (${money.owed}, ${money.spent}, ${money.spentSub})`);
  ok(money.vat, 'a VAT-registered shop sees VAT due this period');
  ok(money.who.length === 1 && /Najd Architects/.test(money.who[0]) && /2,300\.00/.test(money.who[0]), `Who owes me (${JSON.stringify(money.who)})`);
  ok(/Najd Architects 2,000/.test(money.best[0] || '') && /Red Sea Global 1,000/.test(money.best[1] || ''), `Best customers this year (${JSON.stringify(money.best)})`);
  await window.click('#moneyWhoOwes button[data-act="money-client-owes"]');
  await window.waitForTimeout(200);
  const jobs = await window.evaluate(() => ({ tab: document.querySelector('.tab-content.active')?.id, client: logClientFilter, rows: document.querySelectorAll('#logTable tbody tr[data-id], #logTable tbody tr[data-order-id]').length }));
  ok(jobs.tab === 'logs-tab' && jobs.client === 'C-najd', `a name opens the jobs behind it (${JSON.stringify(jobs)})`);
  await window.evaluate(() => clearLogFilters());

  // ── Professional, after: nothing changed ──
  await clickMode('#btnModePro');
  const after = await proSnapshot();
  ok(JSON.stringify(after) === JSON.stringify(before), `Professional is unchanged after a round trip (${JSON.stringify(after)})`);
  ok(await window.evaluate(() => settings.loyaltyTiers.length === 4 && settings.loyaltyTiers.some((t) => t.name === 'VIP' && t.minSpend === 5000)), 'Professional keeps every tier, the spend-bar one included');

  console.log('e2e-simple-screens: ok');
} catch (err) {
  failed = true;
  console.error('e2e-simple-screens FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
