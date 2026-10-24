/**
 * E2E smoke — the shop owner picks a Khayt Cloud plan in Settings.
 *
 * Owner's decision (2026-10-24): Settings → Cloud lists the server's plans
 * with real prices; the owner switches plan, free during the beta, after a
 * warning that the beta's end leaves 30 days to start paying or the shop
 * moves back to Free. Nothing is charged. Before the server opens upgrades,
 * Upgrade reads "Opens soon". Only the owner gets buttons.
 *
 * The server is stood in for by replacing the three main-process handlers
 * (shapes from khayt-cloud #142: GET /v1/plans, POST /v1/shops/{id}/plan,
 * GET /v1/billing/me), so this checks the window's side end to end.
 *
 * Run: npm run test:e2e:planpicker
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  // Khayt Cloud's card is in the Professional view.
  await window.evaluate(() => { settings.mode = 'professional'; applyMode(); saveAll(); });
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="online"]');
  const stand = (open) => electronApp.evaluate(({ ipcMain }, open) => {
    const GB = 1024 ** 3;
    const S = globalThis.__plan || (globalThis.__plan = { plan: 'free', status: 'active', posts: [] });
    const plans = [
      { name: 'free', label: 'Free', priceSar: 0, priceUsd: null, period: 'month', limits: { maxStoreBytes: 0, maxVaultBytes: 2 * GB, maxActiveLinks: 0 } },
      { name: 'maker', label: 'Maker', priceSar: 25, priceUsd: null, period: 'month', limits: { maxStoreBytes: 0, maxVaultBytes: 150 * GB, maxActiveLinks: 50 } },
      { name: 'creator', label: 'Creator', priceSar: 65, priceUsd: null, period: 'month', limits: { maxStoreBytes: 0, maxVaultBytes: 400 * GB, maxActiveLinks: 200, publishing: true } },
      { name: 'labs', label: 'Labs', priceSar: 99, priceUsd: null, period: 'month', limits: { maxStoreBytes: 0, maxVaultBytes: 3 * 1024 * GB, maxActiveLinks: 5, publishing: true } },
    ];
    const me = () => ({ ok: true, billingEnabled: true, plan: S.plan, label: plans.find((p) => p.name === S.plan).label,
      status: S.status, active: true, limits: {}, priceSar: 0, period: 'month', beta: { upgrade: S.status === 'trialing', endsAt: null, graceEndsAt: null, graceDays: 30 } });
    for (const h of ['hub:cloud-plans', 'hub:cloud-billing-me', 'hub:cloud-set-plan']) ipcMain.removeHandler(h);
    ipcMain.handle('hub:cloud-plans', () => ({ ok: true, plans, defaultPlan: 'free', pricesInclusive: true, beta: { freeUpgrades: open, endsAt: null, graceDays: 30 } }));
    ipcMain.handle('hub:cloud-billing-me', () => me());
    ipcMain.handle('hub:cloud-set-plan', (_e, req) => {
      S.posts.push(req.plan);
      if (req.plan !== 'free' && !open) return { ok: false, reason: 'upgrades-closed', error: 'Plan upgrades are not open' };
      S.plan = req.plan; S.status = req.plan === 'free' ? 'active' : 'trialing';
      return me();
    });
  }, open);

  const render = async () => {
    await window.evaluate(() => {
      settings.cloud = { enabled: true, shopId: 'shop-e2e', url: 'https://cloud.khaytapp.com', email: 'owner@example.com', token: 'tok', role: settings.cloud?.role || 'owner', verified: true };
      renderCloudSettings();
    });
    await window.waitForFunction(() => document.querySelectorAll('#cloudPlanCards [data-plan-card]').length === 4, null, { timeout: 10000 });
  };
  const cards = () => window.evaluate(() => Object.fromEntries([...document.querySelectorAll('#cloudPlanCards [data-plan-card]')]
    .map((c) => [c.dataset.planCard, { text: c.innerText.replace(/\s+/g, ' '), btn: c.querySelector('button')?.innerText || '', disabled: !!c.querySelector('button[disabled]'), pick: !!c.querySelector('[data-plan-pick]') }])));

  // Upgrades not open: the server today.
  await stand(false);
  await render();
  let c = await cards();
  ok(/Your plan/.test(c.free.text) && !c.free.pick, `Free is marked as this shop's plan (${c.free.text})`);
  ok(/25 SAR/.test(c.maker.text) && /Free during beta/.test(c.maker.text), `Maker shows its real price, free during the beta (${c.maker.text})`);
  ok(c.maker.disabled && /Opens soon/.test(c.maker.btn), 'before upgrades open, the button reads "Opens soon" and is off');
  ok(/3 TB/.test(c.labs.text) && /5 share links/.test(c.labs.text) && /makerrun/.test(c.labs.text), `a plan only the server knows is described from its limits (${c.labs.text})`);

  // Upgrades open.
  await stand(true);
  await render();
  c = await cards();
  ok(c.maker.pick && /free during the beta/i.test(c.maker.btn), `with upgrades open, Maker offers "${c.maker.btn}"`);
  const note = await window.evaluate(() => document.getElementById('cloudPlanPickNote').innerText);
  ok(/30 days to start paying/.test(note) && /Nothing is deleted/.test(note) && /read-only/.test(note), 'the beta warning is on the card, in the Mac pane\'s words');
  await window.click('#cloudPlanCards [data-plan-pick="maker"]');
  await window.waitForSelector('.confirm-modal-overlay [data-act="ok"]');
  const ask = await window.evaluate(() => document.querySelector('.confirm-modal-overlay .modal').innerText);
  ok(/Move this shop to Maker\?/.test(ask) && /30 days to start paying/.test(ask), 'upgrading asks first, with the warning');
  await window.click('.confirm-modal-overlay [data-act="ok"]');
  await window.waitForFunction(() => /Your plan/.test(document.querySelector('#cloudPlanCards [data-plan-card="maker"]')?.innerText || ''), null, { timeout: 10000 });
  c = await cards();
  ok(c.free.pick && /Switch to Free/.test(c.free.btn), 'on Maker: Maker is the plan, and Free is offered back');
  ok((await electronApp.evaluate(() => globalThis.__plan.posts)).join() === 'maker', 'one POST, for maker');

  // Back to Free.
  await window.click('#cloudPlanCards [data-plan-pick="free"]');
  await window.waitForSelector('.confirm-modal-overlay [data-act="ok"]');
  const downAsk = await window.evaluate(() => document.querySelector('.confirm-modal-overlay .modal').innerText);
  ok(/Nothing is deleted/.test(downAsk) && /Existing links keep working/.test(downAsk) && !/makerrun/.test(downAsk), 'going back to Free asks, and says what stops (nothing deleted; no selling note from Maker)');
  await window.click('.confirm-modal-overlay [data-act="ok"]');
  await window.waitForFunction(() => /Your plan/.test(document.querySelector('#cloudPlanCards [data-plan-card="free"]')?.innerText || ''), null, { timeout: 10000 });
  ok(true, 'back on Free');

  // A refusal is said in words.
  await stand(false);
  await window.evaluate(async () => { await window.hubAPI.cloudSetPlan({ url: settings.cloud.url, shopId: 'shop-e2e', token: 'tok', plan: 'maker' }).then((r) => { window.__r = r; }); });
  const reason = await window.evaluate(() => KhaytCloudPlanPicker.refusalKey(window.__r.reason));
  ok(reason === 'cplan.refused.upgrades_closed' && /aren't open yet/.test(await window.evaluate((k) => t(k), reason)), 'the server\'s "upgrades-closed" has its own words');

  // Not the owner: no buttons, and a line saying who can.
  await stand(true);
  await window.evaluate(() => { settings.cloud.role = 'operator'; });
  await render();
  c = await cards();
  ok(Object.values(c).every((x) => !x.pick), 'a team member sees the plans but no buttons');
  ok(/Only the shop's owner/.test(await window.evaluate(() => document.getElementById('cloudPlanPickNote').innerText)), 'and is told only the owner can change it');

  // Arabic.
  await window.evaluate(() => { settings.cloud.role = 'owner'; settings.lang = 'ar'; i18n.set('ar'); });
  await render();
  const ar = await window.evaluate(() => document.getElementById('cloudPlanCards').innerText);
  ok(/خطتك الحالية/.test(ar) && !/cplan\./.test(ar), 'the cards are translated');

  console.log('e2e-plan-picker: ok (server plans drawn; opens-soon before upgrades open; upgrade asks with the beta warning; back to Free; owner only)');
} catch (err) {
  failed = true;
  console.error('e2e-plan-picker FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
