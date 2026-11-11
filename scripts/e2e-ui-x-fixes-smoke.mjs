/**
 * E2E smoke — the Nov 11 desktop UI review's "fix first" items X1, X5, X6,
 * X13, X14 and X15, on the app's own sample book.
 *
 *  X1  a real change of view opens at the top; re-showing the same view keeps the place
 *  X5  board column footers say "0 orders", "1 order", "2 orders", with a space before the total
 *  X6  an Orders Log row shows its date and its completion in one format
 *  X13 list searches have their own names; Orders Log tag chips are buttons Tab reaches;
 *      Help / Notifications / Language are named in the app's language
 *  X14 Simple Analytics' top products are products / job names, never tags
 *  X15 no VAT Return card for a shop that charges no VAT; it opens on the return being
 *      worked on; the New vs returning card has a heading and hides with no jobs
 *
 * Run: npm run test:e2e:uixfixes
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

// Each item is its own step, and a failed check is recorded rather than thrown,
// so one run reports every item that is broken.
const failures = [];
const ok = (c, m) => { if (c) console.log('  ✓ ' + m); else { failures.push(m); console.log('  ✗ ' + m); } };
async function step(name, fn) {
  try { await fn(); } catch (e) { failures.push(name + ': ' + (e && e.message)); console.log('  ✗ ' + name + ' threw: ' + (e && e.message)); }
}

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.waitForFunction(() => typeof KhaytSampleData !== 'undefined' && typeof initialRender === 'function', null, { timeout: 30000 });
  await window.evaluate(() => {
    const data = KhaytSampleData.buildSampleData({ today: localDateStr() });
    const targets = { machines, clients, products, inventory, printLog };
    for (const key of KhaytSampleData.SAMPLE_COLLECTIONS) {
      const arr = targets[key]; if (!Array.isArray(arr)) continue;
      for (const rec of data[key]) if (!arr.some((x) => x && x.id === rec.id)) arr.push(rec);
    }
    settings.firstRun = false; settings.mode = 'professional'; settings.lang = 'en';
    applyMode(); saveAll(); initialRender();
  });

  await step('X1', async () => {
    /* ── X1: scroll position ─────────────────────────────────── */
    await switchTab(window, 'calculator-tab');
    await window.waitForTimeout(300);
    const x1 = await window.evaluate(async () => {
      const sc = document.getElementById('mainContent');
      // Make sure there is something to scroll, whatever the window size.
      const pad = document.createElement('div'); pad.id = 'x1pad'; pad.style.height = '3000px';
      document.getElementById('calculator-tab').appendChild(pad);
      sc.scrollTop = 900;
      const before = sc.scrollTop;
      KhaytShell.switchTab('calculator-tab'); // the same view again: a re-render
      const same = sc.scrollTop;
      KhaytShell.switchTab('logs-tab');
      const other = sc.scrollTop;
      pad.remove();
      return { before, same, other };
    });
    ok(x1.before > 0 && x1.same === x1.before, `re-showing the same view keeps its place (${x1.same}/${x1.before})`);
    ok(x1.other === 0, `switching to another view opens it at the top (scrollTop ${x1.other})`);
  });

  await step('X6', async () => {
    /* ── X6: one date format per Orders Log row ─────────────── */
    await switchTab(window, 'logs-tab');
    await window.waitForTimeout(300);
    const x6 = await window.evaluate(() => {
      const row = [...document.querySelectorAll('#logs-tab tbody tr')].find((tr) => /Completed:/.test(tr.textContent));
      if (!row) return null;
      const date = row.querySelectorAll('td')[1].textContent.trim();
      const done = (/Completed:\s*(.+)$/m.exec(row.innerText) || [])[1]?.trim();
      return { date, done };
    });
    const FMT = /^[A-Z][a-z]{2} \d{2}, \d{4}$/; // formatPrintDate in en-US: "Nov 05, 2026"
    ok(x6 && FMT.test(x6.date) && FMT.test(x6.done), `a Logs row shows its date and completion in one format (${JSON.stringify(x6)})`);
  });

  await step('X13', async () => {
    /* ── X13: names and keyboard ──────────────────────────────── */
    const names = await window.evaluate(() => {
      // poSearch is drawn by the purchase-orders list.
      try { renderPurchaseOrders(); } catch (_) {}
      return ['kanSearch', 'logSearch', 'clientSearch', 'invSearch', 'supplierSearch', 'poSearch', 'catalogSearch', 'portfolioSearch', 'wasteSearch']
        .map((id) => { const el = document.getElementById(id); return [id, el ? (el.getAttribute('aria-label') || '') : null]; });
    });
    const unnamed = names.filter(([, n]) => !n);
    ok(unnamed.length === 0, `every list search has its own accessible name (${unnamed.map(([id]) => id).join(', ') || 'all named'})`);

    const chip = await window.evaluate(() => {
      const c = document.querySelector('#logs-tab [data-act="filter-tag"]');
      return c ? { tag: c.tagName, type: c.getAttribute('type') } : null;
    });
    ok(chip && chip.tag === 'BUTTON' && chip.type === 'button', `an Orders Log tag chip is a button (${JSON.stringify(chip)})`);
    // Reach it by Tab from the row's checkbox, then Enter filters by it.
    await window.evaluate(() => {
      const c = document.querySelector('#logs-tab [data-act="filter-tag"]');
      c.closest('tr').querySelector('.log-sel').focus();
    });
    let reached = false;
    for (let i = 0; i < 6 && !reached; i++) {
      await window.keyboard.press('Tab');
      reached = await window.evaluate(() => document.activeElement?.dataset?.act === 'filter-tag');
    }
    ok(reached, 'Tab reaches the tag chip');
    await window.keyboard.press('Enter');
    await window.waitForTimeout(300);
    const filtered = await window.evaluate(() => document.getElementById('logTagFilter')?.value);
    ok(filtered === 'sample', `Enter on the chip filters by its tag (${filtered})`);
    await window.evaluate(() => { logTagFilter = ''; const s = document.getElementById('logTagFilter'); if (s) s.value = ''; renderLogs(); });

    const ar = await window.evaluate(() => {
      i18n.set('ar');
      const r = ['btnHelp', 'btnNotifBell', 'langSelect'].map((id) => document.getElementById(id)?.getAttribute('aria-label'));
      i18n.set('en');
      return r;
    });
    ok(ar.every((n) => n && !/^(Help|Notifications|Language)$/.test(n)), `Help / Notifications / Language are named in Arabic (${ar.join(' | ')})`);
  });

  await step('X5', async () => {
    /* ── X5: column footers ───────────────────────────────────── */
    const feet = await window.evaluate(() => {
      // The footer is drawn by the Bed Ready board; Khayt shares the code.
      document.body.classList.add('bedready-ui');
      const base = printLog.find((o) => o.status === 'printing');
      printLog.push({ ...base, id: 'X5-a', status: 'post', date: localDateStr() });
      printLog.push({ ...base, id: 'X5-b', status: 'post', date: localDateStr() });
      renderKanban();
      const foot = (st) => document.querySelector(`.kanban-col[data-status="${st}"] .khayt-kcol-foot`)?.textContent || '';
      const out = { none: foot('on_hold'), one: foot('printing'), two: foot('post') };
      printLog.splice(printLog.findIndex((o) => o.id === 'X5-a'), 1);
      printLog.splice(printLog.findIndex((o) => o.id === 'X5-b'), 1);
      document.body.classList.remove('bedready-ui');
      document.querySelectorAll('.khayt-kcol-foot').forEach((f) => f.remove());
      renderKanban();
      return out;
    });
    ok(/^0 orders \S/.test(feet.none), `an empty column says "0 orders" and a space before its total (${feet.none})`);
    ok(/^1 order \S/.test(feet.one), `a column with one says "1 order" (${feet.one})`);
    ok(/^2 orders \S/.test(feet.two), `a column with two says "2 orders" (${feet.two})`);
    const counts = await window.evaluate(() => [
      t('mach.active_jobs_one', { n: 1 }), t('mach.active_jobs_many', { n: 3 }),
      t('inv.low_stock_count_one', { n: 1 }), t('inv.low_stock_count_many', { n: 2 }),
    ]);
    ok(counts.join('|') === '1 active job|3 active jobs|1 spool low|2 spools low', `printer and stock counts read as English (${counts.join(' | ')})`);
  });

  await step('X15', async () => {
    /* ── X15: analytics orphans ───────────────────────────────── */
    await switchTab(window, 'analytics-tab');
    await window.waitForTimeout(500);
    const noVat = await window.evaluate(() => ({
      vat: KhaytTax.profileFromSettings(settings).rates.length,
      shown: getComputedStyle(document.getElementById('vatReturnContainer')).display !== 'none',
    }));
    ok(noVat.vat === 0 && !noVat.shown, `no VAT Return card for a shop that charges no VAT (${JSON.stringify(noVat)})`);
    const withVat = await window.evaluate(() => {
      settings.enableVat = true; settings.vatRate = 15; saveAll();
      applyAnalyticsModeView();
      const today = KhaytVatPeriods.localDay(new Date().toISOString());
      return {
        shown: getComputedStyle(document.getElementById('vatReturnContainer')).display !== 'none',
        body: document.getElementById('vatFilingSection').textContent.trim().length,
        picked: document.getElementById('vatReturnPeriod').value,
        want: KhaytVatPeriods.returnPeriodFor(today, KhaytVatPeriods.frequencyOf(settings)),
      };
    });
    ok(withVat.shown && withVat.body > 0, 'with VAT on, the card shows with its filing list');
    ok(withVat.picked === withVat.want, `its picker opens on the return being worked on (${withVat.picked}, want ${withVat.want})`);
    const nvr = await window.evaluate(() => {
      const card = document.getElementById('newVsReturningCard');
      const head = card?.querySelector('h3')?.textContent.trim();
      const shownWith = card && getComputedStyle(card).display !== 'none';
      const saved = printLog.splice(0, printLog.length);
      renderNewVsReturning();
      const shownWithout = card && getComputedStyle(card).display !== 'none';
      printLog.push(...saved);
      renderNewVsReturning();
      return { head, shownWith, shownWithout };
    });
    ok(nvr.head && nvr.shownWith && !nvr.shownWithout, `New vs returning has a heading and hides with no jobs (${JSON.stringify(nvr)})`);
  });

  await step('X14', async () => {
    /* ── X14: Simple top products ─────────────────────────────── */
    const top = await window.evaluate(() => {
      printLog.push({ id: 'X14-lamp', project: 'Desk lamp', status: 'completed', date: localDateStr(), completedAt: new Date().toISOString(),
        price: 500, currency: settings.currency || 'SAR', tags: ['sample'], parts: [] });
      settings.mode = 'simple'; applyMode();
      renderSimpleReports();
      const names = [...document.querySelectorAll('#simpleReportsCard .leaderboard .name')].map((n) => n.textContent.trim());
      settings.mode = 'professional'; applyMode();
      return names;
    });
    ok(top.includes('Desk lamp') && !top.includes('sample'), `Simple top products lists job names, not tags (${top.join(', ')})`);
  });

  if (failures.length) throw new Error(failures.length + ' check(s) failed:\n  - ' + failures.join('\n  - '));
  console.log('e2e-ui-x-fixes: ok (scroll, counts, dates, a11y, top products, analytics cards)');
} catch (err) {
  failed = true;
  console.error('e2e-ui-x-fixes FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
