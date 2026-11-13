/**
 * E2E smoke — six plain UI fixes from the Nov 11 desktop review (Windows/Linux).
 *
 *   F3  the production board starts at its first stage (no empty first cell);
 *   F5  Settings shows the crash-report / usage switches and the API tokens list;
 *   F6  icons outside the queue are drawn (the Clients "More" button);
 *   F8  no empty macOS title strip off macOS, in any design;
 *   F12 no build tag in the HueForge title;
 *   F13 Inventory fits a 1280 px window.
 *
 * Run: npm run test:e2e:plainfixes
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await electronApp.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(1280, 800));
  await window.evaluate(() => {
    settings.mode = 'professional'; applyMode();
    inventory.push({ id: 'S-wide', material: 'PLA+ 2.0 Extra Long Brand Name Matte', brand: 'Some Very Long Brand Name', color: '#F5A623', weight: 1000, cost: 75 });
    printLog.push({ id: 'J-pf', project: 'Cup', status: 'pending', price: 10, parts: [], date: '2026-11-01' });
    saveAll();
  });

  // F3
  await window.evaluate(() => switchTab('queue-tab'));
  await window.waitForTimeout(500);
  const board = await window.evaluate(() => {
    const k = document.querySelector('.kanban');
    const first = [...k.children].find((c) => c.offsetParent !== null && getComputedStyle(c).display !== 'none');
    const host = document.getElementById('queueListView');
    return { firstIsColumn: !!first && first.classList.contains('kanban-col'), hostHidden: !host || host.hidden, dx: Math.round(first.getBoundingClientRect().left - k.getBoundingClientRect().left) };
  });
  ok(board.firstIsColumn && board.hostHidden && board.dx < 24, `the board starts with a stage column, at the left edge (${JSON.stringify(board)})`);

  // F5
  await window.evaluate(() => openSettingsSection('advanced'));
  await window.waitForTimeout(300);
  const tel = await window.evaluate(() => ({ crash: !!document.getElementById('tel_crash'), usage: !!document.getElementById('tel_usage') }));
  ok(tel.crash && tel.usage, 'Settings shows the crash-report and usage switches without any click first');

  // F6
  await window.evaluate(() => switchTab('clients-tab'));
  await window.waitForTimeout(300);
  const icons = await window.evaluate(() => [...document.querySelectorAll('#clients-tab [data-khayt-icon]')].map((el) => ({ n: el.getAttribute('data-khayt-icon'), svg: !!el.querySelector('svg') })));
  ok(icons.length > 0 && icons.every((i) => i.svg), `every icon on the Clients toolbar is drawn (${JSON.stringify(icons)})`);

  // F12
  await window.evaluate(() => switchTab('hueforge-tab'));
  await window.waitForTimeout(500);
  const hf = await window.evaluate(() => (document.querySelector('.hf-title') || {}).textContent || '');
  ok(hf && !/build|selective/i.test(hf), `the HueForge title has no build tag ("${hf.trim()}")`);

  // F13
  await window.evaluate(() => switchTab('inventory-tab'));
  await window.waitForTimeout(500);
  const inv = await window.evaluate(() => {
    const tab = document.getElementById('inventory-tab');
    const grid = tab.querySelector('.inv-grid');
    const r = grid.getBoundingClientRect(); const t = tab.getBoundingClientRect();
    return { gridRight: Math.round(r.right), tabRight: Math.round(t.right), docOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
  });
  ok(inv.gridRight <= inv.tabRight + 1 && inv.docOverflow <= 0, `Inventory fits a 1280 px window (${JSON.stringify(inv)})`);

  // F8 — as Windows/Linux see it (preload tags <html> with the platform).
  const strips = await window.evaluate(() => {
    const root = document.documentElement; const was = [...root.classList].filter((c) => c.startsWith('platform-'));
    was.forEach((c) => root.classList.remove(c)); root.classList.add('platform-win32');
    const res = {};
    for (const id of Object.keys(KhaytThemes.DESIGNS || {})) { applyDesignTheme(id); const tb = document.querySelector('.khayt-titlebar'); res[id] = tb ? tb.getBoundingClientRect().height : 0; }
    root.classList.remove('platform-win32'); was.forEach((c) => root.classList.add(c));
    return res;
  });
  ok(Object.values(strips).every((h) => h === 0), `no design shows the macOS title strip off macOS (${JSON.stringify(strips)})`);

  console.log('e2e-plain-fixes: ok');
} catch (err) {
  failed = true;
  console.error('e2e-plain-fixes FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
