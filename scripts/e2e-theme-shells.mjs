#!/usr/bin/env node
/**
 * E2E: tab/nav smoke per Khayt-4 design shell (all selectable themes).
 * Linux CI: xvfb-run -a node scripts/e2e-theme-shells.mjs
 */
import fs from 'fs';
import {
  dismissWizard,
  launchApp,
  makeUserDataDir,
  switchTab,
} from './e2e/helpers.mjs';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const THEME_CASES = [
  { id: 'workbench', bodyClass: 'khayt-workbench', appearance: 'light', dashSel: '.wb-dash', dashMin: 80 },
  { id: 'vivid', bodyClass: 'khayt-vivid', appearance: 'light', dashSel: '.vv-dash', dashMin: 80 },
  { id: 'command', bodyClass: 'khayt-command', appearance: 'light', dashSel: '.cmd-dash', dashMin: 80 },
  // Blueprint and Nocturne borrow a shell rather than shipping their own, so
  // the dashboard selector is the HOST shell's (.wb-dash / .cmd-dash) while the
  // body class asserted is the theme's own hook — that pairing is the thing
  // worth pinning, because it is what proves the identity layer actually
  // attached on top of an inherited layout.
  { id: 'khayt', bodyClass: 'khayt-2026', appearance: 'light', dashSel: '.wb-dash', dashMin: 80 },
  { id: 'blueprint', bodyClass: 'khayt-blueprint', appearance: 'light', dashSel: '.wb-dash', dashMin: 80 },
  { id: 'nocturne', bodyClass: 'khayt-nocturne', appearance: 'dark', dashSel: '.cmd-dash', dashMin: 80 },
  // Meridian is the one theme with a shell of its OWN — no borrowed layout, and
  // its dashboard is the schedule rather than a card grid.
  { id: 'meridian', bodyClass: 'khayt-meridian', appearance: 'light', dashSel: '.mrd-dash', dashMin: 80,
    // Meridian has no visible sidebar: its nav entry point is the top bar, so
    // that is what a user clicks and what this suite must click.
    navSelTpl: '#meridianTopbar [data-mrd-tab="{tab}"]',
    reachSel: '#meridianTopbar [data-mrd-tab="converter-tab"]' },
  // Flow also keeps the sidebar; what is bespoke is the HOME — a live board you
  // drag work across rather than a set of tiles you read.
  { id: 'flow', bodyClass: 'khayt-flow', appearance: 'light', dashSel: '.flow-board', dashMin: 80 },
  // Foreman keeps the sidebar; what is bespoke is the HOME — a docket, not a
  // dashboard — so it pins .fm-shell and uses the normal nav.
  { id: 'foreman', bodyClass: 'khayt-foreman', appearance: 'light', dashSel: '.fm-shell', dashMin: 80 },
];

const userData = makeUserDataDir();
let electronApp;

async function applyThemeCase(window, themeCase) {
  await window.evaluate(({ id, appearance }) => {
    settings.designTheme = id;
    settings.theme = appearance;
    if (typeof applyTheme === 'function') applyTheme(appearance);
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
    window.KhaytShell?.switchTab?.('dashboard-tab');
  }, themeCase);

  await window.waitForFunction(
    ({ bodyClass, id }) => document.body.classList.contains(bodyClass)
      && document.documentElement.dataset.design === id,
    themeCase,
    { timeout: 15_000 },
  );
}

// The top-bar global search (⌕ + input + ⌘K) is a flexbox row. Its base layout
// lived in studio/shell.css and reached Khayt only because index.html linked that
// CSS globally; the Bed Ready rebase moved the layer out and the flexbox went with
// it, so the three children stacked and overlapped. Every theme relies on the base,
// so assert it here — this is exactly the regression that shipped unnoticed.
async function assertSearchBarLaidOut(window, themeCase) {
  const r = await window.evaluate(() => {
    const el = document.querySelector('.khayt-search');
    if (!el || el.offsetParent === null) return { skip: true };   // some shells hide it
    const cs = getComputedStyle(el);
    const box = el.getBoundingClientRect();
    const mid = (box.top + box.bottom) / 2;
    const childrenOnOneRow = [...el.children].every((c) => {
      const cr = c.getBoundingClientRect();
      return Math.abs((cr.top + cr.bottom) / 2 - mid) < 8;
    });
    const input = el.querySelector('input');
    return { display: cs.display, childrenOnOneRow, inputWidth: input ? Math.round(input.getBoundingClientRect().width) : 0 };
  });
  if (r.skip) return;
  if (r.display !== 'flex') throw new Error(`${themeCase.id}: search bar is not a flex row (display:${r.display}) — base layout lost`);
  if (!r.childrenOnOneRow) throw new Error(`${themeCase.id}: search bar children stacked instead of one row`);
  if (r.inputWidth < 40) throw new Error(`${themeCase.id}: search input collapsed (${r.inputWidth}px) — flex:1 missing`);
}

async function assertDashboard(window, themeCase) {
  const dash = await window.evaluate(({ dashSel, dashMin }) => {
    const el = document.querySelector(dashSel);
    return { found: !!el, len: el?.innerHTML?.length || 0, min: dashMin };
  }, themeCase);
  if (!dash.found || dash.len < dash.min) {
    throw new Error(`${themeCase.id}: dashboard not rendered (${JSON.stringify(dash)})`);
  }
}

async function navigateSecondaryTab(window, themeCase) {
  // Click the entry point this shell actually presents. Every sidebar shell
  // exposes the real .tab-btn; Meridian clips the sidebar and proxies it in the
  // top bar, so clicking the hidden original would test nothing a user can do.
  await window.click(themeCase.navSelTpl
    ? themeCase.navSelTpl.replace('{tab}', 'queue-tab')
    : '#tabbtn-queue-tab');
  await window.waitForFunction(
    () => document.getElementById('queue-tab')?.classList.contains('active') === true,
    { timeout: 10_000 },
  );
  const queueReady = await window.evaluate(
    () => !!document.querySelector('#list-pending') && document.querySelectorAll('.kanban-col').length >= 5,
  );
  if (!queueReady) throw new Error(`${themeCase.id}: queue tab did not render kanban`);

  await switchTab(window, 'settings-tab');
  const settingsReady = await window.evaluate(
    () => document.getElementById('settings-tab')?.classList.contains('active') === true
      && !!document.querySelector('#settings-panel-general'),
  );
  if (!settingsReady) throw new Error(`${themeCase.id}: settings tab did not activate`);
}

// Guard the theme tab-reachability regression: the 3.1 tabs (printfiles/colorstudio/
// converter) and others must have a nav entry point in every shell.
async function assertNewTabsReachable(window, themeCase) {
  // "Reachable" means reachable in THIS shell's chrome. The sidebar check below
  // would pass for Meridian on a technicality — its sidebar is clipped, not
  // display:none, so offsetParent stays non-null — which is exactly the kind of
  // true-but-meaningless assertion worth avoiding.
  const ok = await window.evaluate((sel) => {
    if (sel) return !!document.querySelector(sel);
    const b = document.getElementById('tabbtn-converter-tab');
    return !!(b && b.offsetParent !== null);
  }, themeCase.reachSel || null);
  if (!ok) throw new Error(`${themeCase.id}: converter tab has no visible nav entry`);
}

// Enthusiast (hobbyist) mode must not leak revenue/margin into the bespoke
// per-theme dashboards. Seed a completed order with revenue + cost, render each
// themed dashboard in enthusiast mode, and assert the currency symbol and the
// word "margin" are absent from the dashboard (and, for cockpit, its stats bar).
/**
 * Every shell must be able to reach the bottom of a long screen.
 *
 * html and body are `overflow: hidden` app-wide, so the page itself never
 * scrolls — each shell has to bound its own height and nominate an inner
 * scroll container. Meridian nominated none and used `min-height: 100vh`, so
 * .khayt-app grew past the window instead of filling it: 1548px of inventory
 * in a 700px window, with 848px of it simply unreachable. No scrollbar, no
 * overflow, no way down.
 *
 * Static CSS review cannot catch this — the rules each look reasonable — so
 * this asserts the behaviour: shrink the window until content must overflow,
 * then check something actually scrolls, and that scrolling it MOVES.
 */
async function assertEveryShellScrolls(window, themeCases) {
  // viewportSize() is null for an Electron window, so ask the page itself.
  const original = await window.evaluate(() => ({ width: window.innerWidth, height: window.innerHeight }));
  await window.setViewportSize({ width: 1100, height: 420 });
  try {
    for (const th of themeCases) {
      await applyThemeCase(window, th);
      for (const tab of ['inventory-tab', 'settings-tab']) {
        await window.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
        await window.waitForTimeout(450);
        const r = await window.evaluate(() => {
          const scrollers = [...document.querySelectorAll('*')].filter((el) => {
            const cs = getComputedStyle(el);
            return /(auto|scroll)/.test(cs.overflowY)
              && el.scrollHeight > el.clientHeight + 8
              && el.getClientRects().length;
          });
          if (!scrollers.length) {
            const doc = document.documentElement;
            return { ok: false, why: `nothing scrolls (document ${doc.scrollHeight}px in ${window.innerHeight}px)` };
          }
          const s = scrollers.sort((a, b) =>
            (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight))[0];
          const before = s.scrollTop;
          s.scrollTop = 99_999;
          const moved = s.scrollTop - before;
          s.scrollTop = before;
          return moved > 0 ? { ok: true } : { ok: false, why: 'a scroll container exists but will not move' };
        });
        if (!r.ok) throw new Error(`${th.id} on ${tab}: ${r.why}`);
      }
    }
  } finally {
    await window.setViewportSize(original);
  }
}

/**
 * No control may sit off the edge of a narrow window with no way back to it.
 *
 * Command pinned its top-bar actions with `flex-shrink: 0` next to a `nowrap`,
 * so the block kept its full 535px and pushed the last control — the language
 * picker — past the right edge on any window under ~1100px. html and body are
 * overflow:hidden, so past the edge means gone: no scrollbar, no way to reach
 * it. The same shape as Meridian's scroll bug, in the other axis.
 *
 * The skip-to-content link is exempt: sitting off-screen until focused is what
 * it is for.
 */
async function assertNoControlsOffscreen(window, themeCases) {
  const original = await window.evaluate(() => ({ width: window.innerWidth, height: window.innerHeight }));
  await window.setViewportSize({ width: 1024, height: 640 });   // small laptop
  try {
    for (const th of themeCases) {
      await applyThemeCase(window, th);
      for (const tab of ['dashboard-tab', 'settings-tab']) {
        await window.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
        await window.waitForTimeout(400);
        const lost = await window.evaluate(() => {
          const out = [];
          const vw = window.innerWidth, vh = window.innerHeight;
          for (const el of document.querySelectorAll('button, a[href], input, select, textarea, [role="button"]')) {
            const cs = getComputedStyle(el);
            if (cs.display === 'none' || cs.visibility === 'hidden' || +cs.opacity === 0) continue;
            if (/skip/i.test(el.className) || /skip/i.test(el.id)) continue;
            const r = el.getBoundingClientRect();
            if (r.width < 1 || r.height < 1) continue;
            if (!(r.right <= 0 || r.bottom <= 0 || r.left >= vw || r.top >= vh)) continue;
            // an ancestor that scrolls can still bring it into view
            let p = el.parentElement, rescuable = false;
            while (p && p !== document.body) {
              const pcs = getComputedStyle(p);
              if (/(auto|scroll)/.test(pcs.overflowX + pcs.overflowY)) { rescuable = true; break; }
              p = p.parentElement;
            }
            if (!rescuable) out.push(el.id || String(el.className).slice(0, 30) || el.tagName);
          }
          return [...new Set(out)];
        });
        if (lost.length) {
          throw new Error(`${th.id} on ${tab} at 1024x640: ${lost.length} control(s) off-screen and unreachable — ${lost.slice(0, 4).join(', ')}`);
        }
      }
    }
  } finally {
    await window.setViewportSize(original);
  }
}

/**
 * Flow's whole premise is that dragging a card moves the work. If that breaks,
 * the design is a picture of a board.
 *
 * Dispatches real DragEvents rather than driving the mouse: Playwright's
 * dragAndDrop is mouse-based and does not start HTML5 native drag inside
 * Electron, so a mouse-driven version of this test fails against code that
 * works — which it did, before this was written this way.
 */
/**
 * Every theme opens the production queue on the board.
 *
 * The website sells a "Kanban production queue". It shipped behind a toggle
 * button nobody is told about, with a grouped list in front of it, so the
 * advertised feature was real and unfindable.
 *
 * The board is now the default until a shop works the toggle. That distinction
 * is the whole design: every install predating it carries queueView: 'list' on
 * disk because that WAS the default, not because anyone asked — honouring the
 * stored value would keep the feature hidden from exactly the people already
 * using Khayt.
 */
async function assertEveryThemeOpensOnTheBoard(window) {
  for (const themeCase of THEME_CASES) {
    await applyThemeCase(window, themeCase);
    const r = await window.evaluate(() => ({
      list: window.KhaytQueueList.isListView(),
      chosen: !!settings.queueViewChosen,
    }));
    if (r.chosen) throw new Error('nothing has worked the toggle, yet the choice reads as made');
    if (r.list) throw new Error(`${themeCase.id}: the queue opened as a list, not the board`);
  }

  // A shop that asks for the list keeps it — in every theme, and permanently.
  await window.evaluate(() => { window.KhaytQueueList.setQueueView('list'); });
  for (const themeCase of THEME_CASES) {
    await applyThemeCase(window, themeCase);
    const stillList = await window.evaluate(() => window.KhaytQueueList.isListView());
    if (!stillList) throw new Error(`${themeCase.id}: overrode the shop's own choice of list`);
  }

  // And a stored 'list' from before this change must NOT be read as a choice.
  const legacy = await window.evaluate(() => {
    delete settings.queueViewChosen;
    settings.queueView = 'list';
    return window.KhaytQueueList.isListView();
  });
  if (legacy) throw new Error('an old install\'s default was mistaken for a decision');
  await window.evaluate(() => { window.KhaytQueueList.setQueueView('kanban'); });
}

async function assertFlowDragMovesWork(window) {
  await applyThemeCase(window, THEME_CASES.find((c) => c.id === 'flow'));
  await window.waitForTimeout(400);

  const r = await window.evaluate(() => {
    const card = document.querySelector('.flow-col[data-status="pending"] .flow-card');
    const col = document.querySelector('.flow-col[data-status="printing"]');
    if (!card || !col) return { skip: 'no pending card or printing column to drag between' };
    const id = card.dataset.orderId;
    const dt = new DataTransfer();
    card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: dt }));
    col.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt }));
    col.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }));
    const after = printLog.find((o) => o.id === id);
    return { id, status: after?.status };
  });
  if (r.skip) throw new Error(`flow: ${r.skip}`);
  if (r.status !== 'printing') {
    throw new Error(`flow: dragging ${r.id} from pending to printing left it as "${r.status}"`);
  }
}

/**
 * No nav group heading standing over nothing — the invariant, across Khayt's themes.
 *
 * The grouping shells build a Work / Catalog / Money section each and move the shared nav
 * buttons into them. They hid any ORIGINAL section the regrouping emptied but never asked
 * the same of the sections they had just built.
 *
 * That defect is not reachable from HERE, and this test does not pretend to catch it: it
 * needs a group with nothing visible in it, which in Khayt would take enthusiast mode —
 * and applyMode() migrates Khayt out of enthusiast into simple. The case that actually
 * broke is Bed Ready, which ships no catalog-tab/clients-tab/logs-tab at all, and it is
 * asserted in e2e-bedready-smoke.mjs where it can genuinely fail.
 *
 * What this holds is the forward invariant for the modes Khayt CAN be in: whatever the
 * theme, no heading is left over an empty section.
 */
async function assertNoEmptyNavGroups(window) {
  const THEMES = ['workbench', 'vivid', 'command'];
  const MODES = ['professional', 'simple', 'enthusiast'];
  for (const id of THEMES) {
    for (const mode of MODES) {
      const bad = await window.evaluate(({ id, mode }) => {
        settings.designTheme = id;
        settings.mode = mode;
        if (typeof applyDesignSettings === 'function') applyDesignSettings();
        if (typeof applyMode === 'function') applyMode();
        return [...document.querySelectorAll('.khayt-nav .khayt-navsec')]
          .filter((sec) => getComputedStyle(sec).display !== 'none')
          .filter((sec) => ![...sec.querySelectorAll('.tab-btn[data-tab]')]
            .some((btn) => getComputedStyle(btn).display !== 'none'))
          .map((sec) => (sec.querySelector('.khayt-navhead')?.textContent || '(unlabelled)').trim());
      }, { id, mode });
      if (bad.length) {
        throw new Error(`${id}/${mode}: nav heading(s) with nothing visible under them: ${bad.join(', ')}`);
      }
    }
  }
  await window.evaluate(() => {
    settings.mode = 'professional';
    settings.designTheme = 'workbench';
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
    if (typeof applyMode === 'function') applyMode();
  });
}

async function assertEnthusiastThemesNoMoney(window) {
  const THEMES = [
    { id: 'command', sel: '.cmd-dash', extra: '#commandStatusBar' },
    { id: 'workbench', sel: '.wb-dash', extra: null },
    { id: 'vivid', sel: '.vv-dash', extra: null },
    { id: 'khayt', sel: '.wb-dash', extra: null },
    { id: 'blueprint', sel: '.wb-dash', extra: null },
    { id: 'nocturne', sel: '.cmd-dash', extra: '#commandStatusBar' },
    { id: 'meridian', sel: '.mrd-dash', extra: '#meridianTopbar' },
    { id: 'foreman', sel: '.fm-shell', extra: '#foremanDocketBar' },
  ];
  for (const th of THEMES) {
    const r = await window.evaluate(({ id, sel, extra }) => {
      const ccy = (typeof currencySymbol === 'function') ? currencySymbol() : 'SAR';
      const todayStr = (typeof localDateStr === 'function') ? localDateStr(new Date()) : new Date().toISOString().slice(0, 10);
      printLog.unshift({ id: 'REV-e2e', project: 'Rev probe', status: 'completed', price: 73219, cost: 21000, date: todayStr, printTime: 3, clientId: '' });
      settings.mode = 'enthusiast';
      settings.designTheme = id;
      if (typeof applyDesignSettings === 'function') applyDesignSettings();
      window.KhaytShell?.switchTab?.('dashboard-tab');
      const root = document.querySelector(sel);
      let html = root ? root.innerHTML : null;
      if (extra) { const e = document.querySelector(extra); if (e) html = (html || '') + e.innerHTML; }
      // Match the profit-margin KPI label specifically ("Avg margin") — a bare
      // /margin/i would false-match CSS "margin:" in inline styles.
      const out = {
        found: !!root,
        hasCcy: html != null && html.includes(ccy),
        hasMargin: html != null && /Avg margin|profit margin/i.test(html),
        ccy,
      };
      printLog.shift();
      settings.mode = 'professional';
      if (typeof applyDesignSettings === 'function') applyDesignSettings();
      return out;
    }, th);
    if (!r.found) throw new Error(`${th.id}: enthusiast dashboard ${th.sel} not found`);
    if (r.hasCcy) throw new Error(`${th.id}: enthusiast dashboard leaks currency (${r.ccy})`);
    if (r.hasMargin) throw new Error(`${th.id}: enthusiast dashboard leaks "margin"`);
  }
}

// RTL smoke. This used to run against atlas; that theme was deleted, so it now
// covers workbench — the default, and the one carrying the rebuilt dashboard.
async function testRtlWorkbench(window) {
  await window.evaluate(() => {
    settings.lang = 'ar';
    settings.designTheme = 'workbench';
    settings.theme = 'dark';
    i18n.set('ar');
    if (typeof applyTheme === 'function') applyTheme('dark');
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
    window.KhaytShell?.switchTab?.('dashboard-tab');
  });
  await window.waitForFunction(
    () => document.documentElement.dir === 'rtl'
      && document.body.classList.contains('khayt-workbench')
      && !!document.querySelector('.wb-dash'),
    { timeout: 15_000 },
  );
  // The attention bar must mirror with the layout, not stay pinned left.
  const bar = await window.evaluate(() => {
    const el = document.querySelector('.wb-dash .dash-attn');
    if (!el) return { present: false };
    const cs = getComputedStyle(el);
    return { present: true, left: cs.borderLeftWidth, right: cs.borderRightWidth };
  });
  // Assert presence separately — an absent bar must fail, not pass quietly.
  if (!bar.present) throw new Error('RTL: attention bar missing from the workbench dashboard');
  if (bar.right === '0px') {
    throw new Error(`RTL: attention bar accent edge did not mirror (${JSON.stringify(bar)})`);
  }
}

// A missed poll is not a fault. Every themed dashboard has independently gotten
// this wrong — workbench, command and vivid each shipped `m.isOffline ||
// cache.error`, which paints a printer red on the first missed poll while the
// attention bar (correctly) stays silent. Three separate regressions of the same
// shape, so guard it rather than fix it a fourth time.
//
// Seeds two machines: one genuinely gone (past the miss threshold) and one that
// blipped once. The dead one must read offline; the blip must not.
async function assertReconnectingNotOffline(window) {
  // Render a fleet of exactly one machine per case, so the dashboard's wording
  // is unambiguous without needing per-theme selectors to pair a name with its
  // state label (workbench puts them on separate lines, command/vivid don't).
  const CASES = [
    { misses: 1, mustNotMatch: /offline/i, mustMatch: /reconnect/i, label: 'one missed poll' },
    { misses: 5, mustMatch: /offline/i, label: 'past the miss threshold' },
  ];
  for (const id of ['workbench', 'command', 'vivid']) {
    for (const c of CASES) {
      const r = await window.evaluate(({ theme, misses }) => {
        // Seed our own fleet rather than leaning on the demo store: that store
        // emits `machines` while the persisted schema uses `printers`, so it
        // does not survive the save/reload and the rest of this suite runs
        // against an empty fleet.
        const saved = machines;
        machines = [{ id: 'E2E-M', name: 'E2E Probe Printer', color: '#c00' }];
        machineStatusCache['E2E-M'] = {
          error: 'ETIMEDOUT', consecutiveFailures: misses, state: 'Printing', progress: 61,
        };
        settings.designTheme = theme;
        if (typeof applyDesignSettings === 'function') applyDesignSettings();
        window.KhaytShell?.switchTab?.('dashboard-tab');
        if (typeof renderDashboard === 'function') renderDashboard();
        const root = document.querySelector('.wb-dash, .cmd-dash, .vv-dash');
        const out = {
          rendered: !!root,
          barPresent: !!document.querySelector('.dash-attn'),
          text: ((root && root.innerText) || '').replace(/\s+/g, ' '),
        };
        machines = saved;
        delete machineStatusCache['E2E-M'];
        return out;
      }, { theme: id, misses: c.misses });

      if (!r.rendered) throw new Error(`${id}: dashboard did not render (${c.label})`);
      if (!r.barPresent) throw new Error(`${id}: attention bar missing from the dashboard`);
      if (c.mustMatch && !c.mustMatch.test(r.text)) {
        throw new Error(`${id}: ${c.label} should match ${c.mustMatch} — got "${r.text.slice(0, 160)}"`);
      }
      if (c.mustNotMatch && c.mustNotMatch.test(r.text)) {
        throw new Error(`${id}: ${c.label} must not read offline — got "${r.text.slice(0, 160)}"`);
      }
    }
  }
}

async function seedDemoStore(window) {
  const demoStore = buildScreenshotDemoStore();
  demoStore.settings = demoStore.settings || {};
  demoStore.settings.firstRun = false;
  demoStore.settings.firstRunDone = true;
  demoStore.settings.designTheme = 'workbench';
  // Seeding via saveStore alone loses the data: boot schedules a debounced
  // saveAll() (300ms) built from the still-empty globals, and that write lands
  // AFTER this one and overwrites it. The suite then ran every theme against an
  // empty app — dashboards rendered, so nothing failed, but nothing was really
  // being tested either. Empty states flatter a design.
  //
  // Apply the snapshot to the in-memory globals first, so any save the renderer
  // performs writes the demo data rather than emptiness, then flush it.
  const saveResult = await window.evaluate(async (store) => {
    if (typeof applyStoreFromSnapshot === 'function') applyStoreFromSnapshot(store);
    if (typeof flushSave === 'function') await flushSave();
    return window.hubAPI.saveStore(store);
  }, demoStore);
  if (!saveResult?.ok) throw new Error(`saveStore failed: ${JSON.stringify(saveResult)}`);
  await window.reload({ waitUntil: 'domcontentloaded' });
  await window.waitForSelector('.khayt-app', { timeout: 90_000 });
  await dismissWizard(window);

  // Prove the seed survived — the whole point of this function.
  const seeded = await window.evaluate(() => ({
    machines: typeof machines !== 'undefined' ? machines.length : -1,
    orders: typeof printLog !== 'undefined' ? printLog.length : -1,
  }));
  if (seeded.machines < 2 || seeded.orders < 1) {
    throw new Error(`demo store did not survive the reload: ${JSON.stringify(seeded)}`);
  }
}

/**
 * Two redesign promises that are easy to regress silently:
 *  - the queue group head must be an operable control. It rendered
 *    `is-collapsed` from lib/queue-groups.js but nothing ever toggled it, so
 *    "Finished today" showed totals that could never be opened.
 *  - nav chrome must stay quiet. All 13 items used to carry a saturated tile
 *    from the STATUS palette, making permanent navigation louder than the
 *    attention bar it sits beside.
 */
async function assertQuietChromeAndOperableGroups(window) {
  await applyThemeCase(window, THEME_CASES.find((c) => c.id === 'workbench'));
  // This asserts the GROUPED LIST's headers are operable, and it used to get
  // the list for free because the list was the default. The board is the
  // default now, so the view it is testing has to be asked for — a test that
  // depends on a default is a test that stops testing when the default moves.
  await window.evaluate(() => { window.KhaytQueueList.setQueueView('list'); });

  const g = await window.evaluate(() => {
    const head = document.querySelector('.ql-group .ql-group-head');
    if (!head) return { missing: true };
    const before = head.getAttribute('aria-expanded');
    head.click();
    return { tag: head.tagName, before, after: head.getAttribute('aria-expanded') };
  });
  if (g.missing) throw new Error('no queue group head rendered — cannot verify it is operable');
  if (g.tag !== 'BUTTON') throw new Error(`queue group head is <${g.tag}>, expected BUTTON`);
  if (!g.before || !g.after || g.before === g.after) {
    throw new Error(`clicking the group head did not flip aria-expanded (${g.before} -> ${g.after})`);
  }

  // The invariant is "chrome is quiet", not "exactly one colour" — a second
  // neutral is fine. What must not happen is a nav icon carrying a saturated
  // hue from the STATUS palette, which is reserved for conditions.
  // .nav-icon animates background over 120ms. Measuring immediately after a
  // navigation reads a mid-transition colour on the tab we just left — it has
  // already lost .active but is still fading down from the accent.
  //
  // A fixed sleep was doing this, and it flaked roughly one run in six: under
  // load the fade had not finished and the assertion caught Vivid's indigo
  // still on the settings icon. (Verified it is only a stale FRAME, not a
  // teardown leak — switching away from Vivid clears --vv-tile and --hue every
  // time.) Wait for the condition itself to hold instead of for a clock, and
  // fall through on timeout so a genuine violation still reports the colour
  // rather than a bare timeout.
  await window
    .waitForFunction(() => {
      const sat = (c) => {
        const m = String(c).match(/rgba?\(([^)]+)\)/);
        if (!m) return 0;
        const [r, g, b] = m[1].split(',').slice(0, 3).map((n) => parseFloat(n));
        const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
        return mx === 0 ? 0 : (mx - mn) / mx;
      };
      return [...document.querySelectorAll('.khayt-navitem')].every((b) => {
        if (b.classList.contains('active') || b.getAttribute('aria-selected') === 'true') return true;
        const icon = b.querySelector('.nav-icon');
        return !icon || sat(getComputedStyle(icon).backgroundColor) <= 0.25;
      });
    }, { timeout: 4000 })
    .catch(() => {});
  // A row that paints a hover highlight must actually open the order — and a
  // click on the row's own action button must NOT also open it, or advancing a
  // job would pop the editor every time.
  const rowClick = await window.evaluate(() => {
    const out = { opened: null, openedFromButton: null };
    const realOpen = window.openOrderEditor;
    let lastId = null;
    window.openOrderEditor = (id) => { lastId = id; };
    try {
      const row = document.querySelector('.ql-row.is-openable');
      if (!row) return { skipped: true };
      const wantId = row.dataset.orderId;

      lastId = null;
      row.click();
      out.opened = (lastId === wantId);

      const btn = row.querySelector('button[data-act="status"]');
      if (btn) { lastId = null; btn.click(); out.openedFromButton = (lastId !== null); }
      return out;
    } finally { window.openOrderEditor = realOpen; }
  });
  if (!rowClick.skipped) {
    if (!rowClick.opened) throw new Error('clicking a queue row did not open its order');
    if (rowClick.openedFromButton) throw new Error('clicking the row action button also opened the order editor');
  }

  const nav = await window.evaluate(() => {
    const sat = (css) => {
      const m = /rgba?\(([^)]+)\)/.exec(css || '');
      if (!m) return 0;
      const [r, g, b] = m[1].split(',').slice(0, 3).map((n) => parseFloat(n));
      const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
      return mx === 0 ? 0 : (mx - mn) / mx;   // HSV saturation, 0..1
    };
    const items = [...document.querySelectorAll('.khayt-navitem')];
    const loud = [];
    for (const b of items) {
      // The active item legitimately takes the accent. Check both signals:
      // the class and aria-selected, since nav state is mirrored in both.
      if (b.classList.contains('active') || b.getAttribute('aria-selected') === 'true') continue;
      const icon = b.querySelector('.nav-icon');
      if (!icon) continue;
      const bg = getComputedStyle(icon).backgroundColor;
      if (sat(bg) > 0.25) loud.push(`${b.dataset.tab}=${bg}`);
    }
    return { count: items.length, loud, inlineTiles: items.filter((b) => b.style.getPropertyValue('--wb-tile')).length };
  });
  if (nav.count > 3) {
    if (nav.loud.length) throw new Error(`nav chrome is not quiet — saturated icons: ${nav.loud.join(', ')}`);
    if (nav.inlineTiles) throw new Error(`${nav.inlineTiles} nav items still carry an inline --wb-tile colour`);
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  await seedDemoStore(window);

  for (const themeCase of THEME_CASES) {
    await applyThemeCase(window, themeCase);
    await assertDashboard(window, themeCase);
    await assertSearchBarLaidOut(window, themeCase);
    await navigateSecondaryTab(window, themeCase);
    await assertNewTabsReachable(window, themeCase);
    console.log(`  ${themeCase.id}: dashboard + queue + settings + reach ok`);
  }

  await assertEveryShellScrolls(window, THEME_CASES);
  console.log('  every shell reaches the bottom of a long screen: ok');

  await assertNoControlsOffscreen(window, THEME_CASES);
  console.log('  no control is stranded off a narrow window: ok');

  await assertEveryThemeOpensOnTheBoard(window);
  await assertFlowDragMovesWork(window);
  console.log('  Flow: dragging a card actually moves the work: ok');

  await assertEnthusiastThemesNoMoney(window);
  console.log('  enthusiast themed dashboards: no revenue/margin ok');

  await assertNoEmptyNavGroups(window);
  console.log('  nav groups: no heading left standing over nothing ok');

  await assertReconnectingNotOffline(window);
  console.log('  a missed poll reads reconnecting, not offline: ok');

  await assertQuietChromeAndOperableGroups(window);
  console.log('  quiet nav chrome + operable queue groups: ok');

  await testRtlWorkbench(window);
  console.log('  workbench + ar RTL: ok');

  console.log(`e2e-theme-shells: ok (${THEME_CASES.length} themes + RTL workbench)`);
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
