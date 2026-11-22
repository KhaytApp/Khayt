#!/usr/bin/env node
/**
 * Bed Ready flavor smoke test.
 *
 * Boots the app with KHAYT_FLAVOR=bedready and asserts the standalone maker
 * experience: it loads renderer/bedready.html, forces the commerce-free
 * enthusiast mode, exposes the maker surfaces (converter / colour studio /
 * print files / queue / inventory), does NOT ship the business modules, shows
 * no business navigation, and boots with no uncaught renderer errors.
 *
 * Requires a display (use xvfb-run on Linux CI). Run: node scripts/e2e-bedready-smoke.mjs
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { _electron as electron } from 'playwright-core';
import { makeUserDataDir } from './e2e/helpers.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
// The brief the website is written from. Read here so the guard below can hold
// the app and the marketing claim apart rather than assuming they move together.
const brief = fs.readFileSync(path.join(root, 'docs/BEDREADY-WEBSITE-FEATURES.md'), 'utf8');

const userData = makeUserDataDir();
let electronApp;
const pageErrors = [];

function assert(label, cond) {
  if (!cond) throw new Error(`ASSERT FAILED: ${label}`);
  console.log(`  ✓ ${label}`);
}

async function main() {
  electronApp = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    // The flavor is what routes main.js to bedready.html and skips business wiring.
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_FLAVOR: 'bedready' },
    timeout: 120_000,
  });

  const window = await electronApp.firstWindow();
  // Generous default so the boot/tab gates don't trip on a busy dev machine (Electron boot can lag
  // past 30s under load — the failure mode that looks like a hang). CI is fast; this only adds headroom.
  window.setDefaultTimeout(120_000);
  // Fail loudly on any uncaught renderer error (this is how a ReferenceError from a
  // dropped business module would surface at boot).
  window.on('pageerror', (err) => pageErrors.push(String(err && err.message || err)));

  await window.waitForSelector('.khayt-app', { timeout: 60_000 });
  await window.waitForFunction(
    () => typeof window.hubAPI?.loadStore === 'function'
      && (document.querySelector('#dashboardContent')?.innerHTML?.length || 0) > 100,
    { timeout: 60_000 }
  );

  console.log('\n[flavor + entry]');
  const entry = await window.evaluate(() => ({
    href: location.pathname,
    flavor: document.body.dataset.flavor || null,
    mode: (typeof settings !== 'undefined' && settings) ? settings.mode : null,
    modeClass: document.body.classList.contains('mode-enthusiast'),
    title: document.title,
  }));
  assert('entry document is bedready.html', entry.href.endsWith('bedready.html'));
  assert('body[data-flavor="bedready"]', entry.flavor === 'bedready');
  assert('mode forced to enthusiast', entry.mode === 'enthusiast');
  assert('body has mode-enthusiast class', entry.modeClass === true);
  assert('document title is "Bed Ready"', entry.title === 'Bed Ready');

  console.log('\n[business modules NOT shipped]');
  const bizScripts = await window.evaluate(() => {
    const BUSINESS = ['analytics.js', 'order-flows.js', 'integrations.js', 'invoicing.js',
      'clients.js', 'operations-extras.js', 'expenses.js', 'logs.js', 'waiting-list.js',
      'views.js', 'online.js'];
    const srcs = [...document.querySelectorAll('script[src]')].map((s) => s.getAttribute('src'));
    return {
      present: BUSINESS.filter((b) => srcs.includes(b)),
      shimFirst: srcs[0] === 'bedready-shim.js',
      // The error reporter goes immediately after the shim, not before it: the
      // shim declares the business globals this flavour does not ship, and
      // anything loading first would be running against undeclared identifiers.
      // The shim is pure declarations and cannot reject, so nothing is lost by
      // being second — but Bed Ready must not be the flavour whose boot errors
      // go unreported, which is what "just leave it at the bottom" would mean.
      reporterSecond: srcs[1] === 'error-report.js',
    };
  });
  assert(`no business <script> tags in document (${bizScripts.present.join(',') || 'none'})`, bizScripts.present.length === 0);
  assert('bedready-shim.js is the first script', bizScripts.shimFirst === true);
  assert('error-report.js is the second script', bizScripts.reporterSecond === true);

  console.log('\n[maker modules present + shared core]');
  const maker = await window.evaluate(() => ({
    renderKanban: typeof renderKanban,
    renderInventory: typeof renderInventory,
    renderDashboard: typeof renderDashboard,
    converter: typeof window.hubAPI?.mfAnalyze,
    switchTab: typeof window.KhaytShell?.switchTab,
  }));
  assert('renderKanban present (kanban.js)', maker.renderKanban === 'function');
  assert('renderInventory present (inventory.js)', maker.renderInventory === 'function');
  assert('renderDashboard present (dashboard.js home)', maker.renderDashboard === 'function');
  assert('converter IPC bridge present', maker.converter === 'function');
  assert('shell.switchTab present', maker.switchTab === 'function');

  console.log('\n[maker tabs reachable + populate]');
  for (const tab of ['converter-tab', 'colorstudio-tab', 'printfiles-tab', 'inventory-tab', 'queue-tab']) {
    const ok = await window.evaluate(async (id) => {
      window.KhaytShell.switchTab(id);
      await new Promise((r) => setTimeout(r, 150));
      const el = document.getElementById(id);
      return el && el.classList.contains('active') && (el.innerHTML.length > 20);
    }, tab);
    assert(`${tab} activates and renders content`, ok === true);
  }

  // The website brief (docs/BEDREADY-WEBSITE-FEATURES.md) has to state whether a maker
  // can reach printer setup at all, and which adapters they are offered. Both were
  // "best answered by opening the app" — so they are answered here, in the app, and
  // stay answered: if a flavour gate ever hides printers from Bed Ready, or the adapter
  // list changes, the sentence on the website becomes false and this fails.
  //
  // Settings must be OPENED first. #settings-tab is aria-hidden until switched to, so
  // every element inside it has offsetParent === null and a naive visibility check
  // reports "hidden" for the whole pane regardless of any flavour gate.
  console.log('\n[printer setup is reachable, and its adapter list is the documented one]');
  const printers = await window.evaluate(async () => {
    window.KhaytShell.switchTab('settings-tab');
    await new Promise((r) => setTimeout(r, 200));
    const btn = document.querySelector('[data-settings-section="printers"]');
    const out = {
      exists: !!btn,
      visible: !!btn && btn.offsetParent !== null,
      gated: !!btn && (btn.classList.contains('biz-only') || btn.classList.contains('pro-only')),
      topLevelTab: !!document.querySelector('.tab-btn[data-tab="printers-tab"]'),
      adapters: [],
    };
    if (btn) { btn.click(); await new Promise((r) => setTimeout(r, 250)); }
    // The adapter picker lives in the machine editor, not on the settings page.
    if (typeof openMachineEditor === 'function') {
      openMachineEditor();
      await new Promise((r) => setTimeout(r, 300));
    }
    const sel = document.getElementById('machApiType');
    out.selectExists = !!sel;
    if (sel) {
      out.adapters = [...sel.options].map((o) => o.value).filter((v) => v && v !== 'none').sort();
      // The decisive one: present in the DOM is not the same as reachable by a maker.
      out.selectVisible = sel.offsetParent !== null;
      out.proGated = !!sel.closest('.pro-only');
      out.bodyMode = document.body.className.match(/mode-\w+/)?.[0] || '(none)';
    }
    const scan = document.getElementById('btnScanNetwork');
    out.scanReachable = !!scan && !scan.closest('.pro-only') && !scan.closest('.biz-only');
    return out;
  });
  assert('Settings has a Printers section', printers.exists === true);
  assert('it is reachable in Bed Ready — no biz-only/pro-only gate',
    printers.visible === true && printers.gated === false);
  // So the brief cannot describe a top-level "Printers view": setup lives in Settings,
  // in both flavours.
  assert('there is no top-level Printers tab', printers.topLevelTab === false);
  // What the app OFFERS, which since 2026-08-24 is seven: the SDCP socket layer
  // landed and resin printers are selectable.
  //
  // The website may still name only SIX, and that gap is the point of this guard
  // rather than an oversight. The seventh has never met a printer — there is no
  // Elegoo on the bench — so it ships marked untested, and a shop that bought on
  // the strength of a website line would have been misled by us rather than by
  // its hardware. docs/BEDREADY-WEBSITE-FEATURES.md carries the same split and
  // says what to delete when a Mars or a Saturn confirms it.
  const EXPECTED = ['bambu', 'duet', 'moonraker', 'octoprint', 'prusalink', 'repetier', 'sdcp'];
  const WEBSITE_MAY_NAME = 6;
  console.log(`    [machApiType] exists=${printers.selectExists} visible=${printers.selectVisible} `
    + `insidePfroOnly=${printers.proGated} bodyMode=${printers.bodyMode}`);
  console.log(`    [adapters] ${printers.adapters.join(', ') || '(none)'}`);
  assert(`the adapter list is the documented set (${printers.adapters.join(', ') || 'none found'})`,
    JSON.stringify(printers.adapters) === JSON.stringify(EXPECTED));
  // Said separately so the reason survives: adding an adapter is allowed, and
  // quietly promoting it to a marketing claim is what must not happen by
  // accident. If this number ever rises it should be because someone verified
  // the adapter against hardware and edited the brief on purpose.
  assert(`the website still names ${WEBSITE_MAY_NAME}, not every adapter that exists`,
    /Six adapters/.test(brief) && /never met a printer/.test(brief));
  // The picker itself is inside a .pro-only block, which enthusiast mode hides — so in
  // Bed Ready it is NOT the path to connecting a printer. Scan-and-pick is: it lives
  // outside the gate and applyFound() writes the adapter type, host and port straight
  // into the hidden fields, which the save path then reads back.
  //
  // That makes discovery load-bearing rather than a convenience here, and it is why the
  // website line "nobody types an IP address" is literally true for this app: in Bed
  // Ready nobody CAN. If the scan button ever moves inside the gate, a maker loses the
  // only route to printer monitoring at all — so that is what is pinned.
  assert('the adapter picker is Pro-only, as the docs now say', printers.proGated === true && printers.selectVisible === false);
  assert('network scan — the maker route to a printer — is reachable', printers.scanReachable === true);

  // Kits in Bed Ready. Khayt builds them from the orders list's batch bar, which
  // this app does not ship (no logs-tab at all), so the home carries the tray.
  //
  // Asserted in the running app because the failure mode here is a ReferenceError
  // inside a string-building function: `esc` is not file-scoped in
  // bedready-home.js and `tr` does not exist in it, so a helper assumed rather
  // than declared takes the whole home down. A source grep cannot see that; the
  // pageerror assertion further down and this render check can.
  console.log('\n[kits reach the maker app]');
  const kits = await window.evaluate(async () => {
    window.KhaytShell.switchTab('dashboard-tab');
    await new Promise((r) => setTimeout(r, 200));
    const out = { libLoaded: typeof KhaytPrintKits !== 'undefined', card: false, tray: false, rendered: false };
    if (!out.libLoaded) return out;
    // Two completed prints with no kit is what the tray needs to appear.
    if (typeof printLog !== 'undefined' && Array.isArray(printLog)) {
      printLog.length = 0;
      printLog.push(
        { id: 'ORD-A', project: 'Head', status: 'completed', currency: 'SAR', printTime: 2, actualPrintTime: 1.9, actualWeight: 20, costBasis: 1, parts: [{ printWeight: 20 }] },
        { id: 'ORD-B', project: 'Body', status: 'completed', currency: 'SAR', printTime: 3, actualPrintTime: 2.9, actualWeight: 30, costBasis: 2, parts: [{ printWeight: 30 }] },
      );
    }
    if (typeof renderDashboard === 'function') renderDashboard();
    await new Promise((r) => setTimeout(r, 250));
    out.rendered = true;
    out.tray = !!document.querySelector('.br-kit-pick');
    out.card = !!document.querySelector('[data-kit-add]');
    return out;
  });
  assert('lib/print-kits.js is loaded in the Bed Ready shell', kits.libLoaded === true);
  assert('the home offers unfiled prints to group', kits.tray === true);
  assert('the home has a way to create the kit', kits.card === true);

  // Rendering is not working. The first version of this asserted only that the
  // tray appeared, and five mutations survived it — an unwired button, a disband
  // that deleted prints, duplicate kits, and a hidden measured count all passed.
  // So the tray is actually driven here.
  const acted = await window.evaluate(async () => {
    // Re-render first: the home self-heals on a timer, and the previous block's
    // DOM may already have been replaced.
    if (typeof renderDashboard === 'function') renderDashboard();
    await new Promise((r) => setTimeout(r, 300));
    const pick = () => [...document.querySelectorAll('.br-kit-pick')];
    if (!document.querySelector('#brKitName')) {
      return { diag: true,
        picks: pick().length,
        addBtn: !!document.querySelector('[data-kit-add]'),
        logLen: (typeof printLog !== 'undefined' ? printLog.length : -1),
        completedUnfiled: (typeof printLog !== 'undefined'
          ? printLog.filter((o) => o.status === 'completed' && !o.kitId).length : -1),
        cardHtml: (document.querySelector('.br-card')?.outerHTML || '(no .br-card)').slice(0, 200) };
    }
    pick().forEach((c) => { c.checked = true; });
    document.querySelector('#brKitName').value = 'Figure';
    document.querySelector('[data-kit-add]').click();
    await new Promise((r) => setTimeout(r, 300));
    const out = {};
    out.kitsDefined = (settings.kits || []).length;
    out.jobsFiled = printLog.filter((o) => o.kitId).length;
    out.rowShown = !!document.querySelector('[data-kit-disband]');
    out.rowText = (document.querySelector('.br-kit-row')?.textContent || '').replace(/\s+/g, ' ').trim();

    // Same name again must reuse the kit, not split the rollup across two.
    printLog.push({ id: 'ORD-C', project: 'Legs', status: 'completed', currency: 'SAR',
      printTime: 1, actualPrintTime: 0.9, actualWeight: 10, costBasis: 1, parts: [{ printWeight: 10 }] });
    renderDashboard();
    await new Promise((r) => setTimeout(r, 250));
    pick().forEach((c) => { c.checked = true; });
    document.querySelector('#brKitName').value = 'figure';        // different case, same kit
    document.querySelector('[data-kit-add]').click();
    await new Promise((r) => setTimeout(r, 300));
    out.kitsAfterDup = (settings.kits || []).length;

    // A partly-measured kit must say so rather than showing a confident total.
    printLog.push({ id: 'ORD-D', project: 'Base', status: 'completed', currency: 'SAR',
      printTime: 1, actualPrintTime: null, actualWeight: null, costBasis: 1, parts: [{ printWeight: 10 }],
      kitId: (settings.kits[0] || {}).id });
    renderDashboard();
    await new Promise((r) => setTimeout(r, 250));
    out.partialText = (document.querySelector('.br-kit-row')?.textContent || '').replace(/\s+/g, ' ').trim();

    // Rename, driven rather than read. window.prompt is stubbed because Electron
    // blocks on the real one; the point is the handler's behaviour around it.
    const realPrompt = window.prompt;
    window.prompt = () => 'Dragon';
    document.querySelector('[data-kit-rename]').click();
    await new Promise((r) => setTimeout(r, 300));
    out.renamedTo = (settings.kits[0] || {}).name;
    out.kitsAfterRename = (settings.kits || []).length;

    // Renaming onto a second kit's name must refuse, not merge.
    settings.kits.push({ id: 'KIT-other', name: 'Taken' });
    window.prompt = () => 'taken';
    renderDashboard();
    await new Promise((r) => setTimeout(r, 250));
    document.querySelector('[data-kit-rename]').click();
    await new Promise((r) => setTimeout(r, 300));
    out.afterClash = (settings.kits.filter((k) => k.id !== 'KIT-other')[0] || {}).name;
    settings.kits = settings.kits.filter((k) => k.id !== 'KIT-other');
    window.prompt = realPrompt;
    renderDashboard();
    await new Promise((r) => setTimeout(r, 250));

    // Disband unfiles the jobs and must not remove a single print.
    const before = printLog.length;
    document.querySelector('[data-kit-disband]').click();
    await new Promise((r) => setTimeout(r, 300));
    out.printsAfterDisband = printLog.length;
    out.printsBefore = before;
    out.stillFiled = printLog.filter((o) => o.kitId).length;
    out.kitsAfterDisband = (settings.kits || []).length;
    return out;
  });
  assert(`creating a kit files the ticked jobs (${acted.jobsFiled} filed)`,
    acted.kitsDefined === 1 && acted.jobsFiled === 2);
  assert(`the kit's rollup row renders (${acted.rowText.slice(0, 60)})`, acted.rowShown === true);
  assert(`the same name twice reuses one kit (${acted.kitsAfterDup} defined)`, acted.kitsAfterDup === 1);
  assert(`a partly-measured kit says so (${acted.partialText.slice(0, 70)})`, /\/\s*\d/.test(acted.partialText));
  assert(`rename takes effect (${acted.renamedTo})`, acted.renamedTo === 'Dragon' && acted.kitsAfterRename === 1);
  assert(`renaming onto another kit's name refuses (${acted.afterClash})`, acted.afterClash === 'Dragon');
  assert(`disband removes no prints (${acted.printsBefore} -> ${acted.printsAfterDisband})`,
    acted.printsAfterDisband === acted.printsBefore);
  assert('disband unfiles every job', acted.stillFiled === 0 && acted.kitsAfterDisband === 0);

  console.log('\n[no visible business navigation]');
  const bizNavVisible = await window.evaluate(() => {
    const bizButtons = [...document.querySelectorAll('.tab-btn.biz-only, .nav-group.biz-only')];
    // offsetParent === null => not rendered/visible
    return bizButtons.filter((b) => b.offsetParent !== null).length;
  });
  assert('zero visible .biz-only nav elements', bizNavVisible === 0);

  const modeSwitchVisible = await window.evaluate(() => {
    const card = document.querySelector('#brExperienceCard');
    return card ? card.offsetParent !== null : false;
  });
  assert('mode switcher card hidden', modeSwitchVisible === false);

  // The grouping theme shells build Work / Catalog / Money sections and move the shared
  // nav buttons into them. They hid any ORIGINAL section the regrouping emptied, but
  // never asked the same of the sections they had just built — and Bed Ready ships no
  // catalog-tab, clients-tab, logs-tab or expenses-tab at all, so "Catalog" and "Money"
  // rendered as two headings over blank space on every screen.
  //
  // Khayt cannot reach this: its buttons exist, and enthusiast mode (where they would be
  // CSS-hidden) migrates to simple in applyMode(). So this is asserted HERE, in the only
  // app where it can happen.
  const emptyNavHeadings = await window.evaluate(() => [...document.querySelectorAll('.khayt-nav .khayt-navsec')]
    .filter((sec) => getComputedStyle(sec).display !== 'none')
    .filter((sec) => ![...sec.querySelectorAll('.tab-btn[data-tab]')]
      .some((btn) => getComputedStyle(btn).display !== 'none'))
    .map((sec) => (sec.querySelector('.khayt-navhead')?.textContent || '(unlabelled)').trim()));
  assert(`no nav heading standing over nothing (${emptyNavHeadings.join(', ') || 'none'})`,
    emptyNavHeadings.length === 0);

  // Commerce-free affordances (the enthusiast/maker gating, now Bed-Ready-only after the
  // Khayt "enthusiast mode" retirement): the calculator shows no selling-price knobs and
  // the production queue exposes no invoice/pay actions.
  console.log('\n[commerce-free affordances]');
  const aff = await window.evaluate(async () => {
    const vis = (id) => { const b = document.getElementById(id); return !!(b && b.offsetParent !== null); };
    window.KhaytShell.switchTab('calculator-tab');
    await new Promise((r) => setTimeout(r, 120));
    const calc = { margin: vis('margin'), discount: vis('discountPct'), aiPrice: vis('btnAiPrice'), saveQuote: vis('btnSaveAsQuote') };
    if (Array.isArray(printLog)) printLog.unshift({ id: 'BR-e2e', project: 'E2E', status: 'completed', parts: [{ material: 'PLA' }], date: '2026-01-01' });
    window.KhaytShell.switchTab('queue-tab');
    if (typeof renderKanban === 'function') renderKanban();
    await new Promise((r) => setTimeout(r, 120));
    const qhtml = document.getElementById('queue-tab')?.innerHTML || '';
    return { ...calc, queueNoCommerce: !qhtml.includes('data-act="invoice"') && !qhtml.includes('data-act="pay"') && !qhtml.includes('data-act="bnpl-pay"') };
  });
  assert('calculator hides margin', aff.margin === false);
  assert('calculator hides discount', aff.discount === false);
  assert('calculator hides AI price-suggest', aff.aiPrice === false);
  assert('calculator hides save-as-quote', aff.saveQuote === false);
  assert('production queue exposes no commerce actions', aff.queueNoCommerce === true);

  console.log('\n[bespoke Bed Ready identity]');
  const design = await window.evaluate(() => ({
    dataApp: document.documentElement.dataset.app || null,
    designTheme: (typeof settings !== 'undefined') ? settings.designTheme : null,
    bedreadyUiClass: document.body.classList.contains('bedready-ui'),
    uiLayerLoaded: typeof window.KhaytBedReadyUI !== 'undefined',
    // Bed Ready must not depend on Khayt's theme registry any more.
    studioStillAThemeInKhayt: !!(window.KhaytThemeRegistry
      && window.KhaytThemeRegistry.BUILTIN_THEMES
      && window.KhaytThemeRegistry.BUILTIN_THEMES.studio),
    designPickerHidden: (() => { const el = document.querySelector('#brDesignFields'); return el ? el.offsetParent === null : true; })(),
    altThemeCss: [...document.styleSheets].map((s) => s.href || '')
      .filter((h) => /themes\/(ledger|console|atelier|vitrine|cockpit|atlas|workbench|vivid|command)\//.test(h)).length,
    accent: getComputedStyle(document.documentElement).getPropertyValue('--accent-h').trim(),
    brandFont: getComputedStyle(document.querySelector('h1, h2, .sec-title') || document.body).fontFamily,
  }));
  assert('html[data-app="bedready"] set', design.dataApp === 'bedready');
  // Was: `designTheme === 'studio'`. Bed Ready used to borrow a Khayt design id
  // to reach its own look. Since 3.3 it owns renderer/bedready/ and is keyed off
  // the html marker, so the identity to assert is the body class and the layer —
  // not a theme id in a registry it no longer participates in.
  assert('bedready-ui body class set', design.bedreadyUiClass === true);
  assert('Bed Ready UI layer loaded', design.uiLayerLoaded === true);
  assert('studio is not a Khayt theme any more', design.studioStillAThemeInKhayt === false);
  assert('design/theme picker hidden', design.designPickerHidden === true);
  assert(`no alternate-theme CSS loaded (${design.altThemeCss})`, design.altThemeCss === 0);
  // Cyanotype Draft identity — blueprint-blue accent (hue 209) + Archivo display face.
  assert(`blueprint accent applied (--accent-h=${design.accent})`, design.accent === '209');
  assert(`Archivo display font on headings (${design.brandFont.slice(0, 24)}…)`, /Archivo/.test(design.brandFont));

  console.log('\n[branded Bed Ready home]');
  const home = await window.evaluate(() => {
    if (window.KhaytShell?.switchTab) window.KhaytShell.switchTab('dashboard-tab');
    const hero = document.querySelector('.br-hero');
    return {
      hasHero: !!hero,
      headline: (hero?.querySelector('h1')?.textContent || '').replace(/\s+/g, ' ').trim(),
      stickers: document.querySelectorAll('.br-hero .br-sticker').length,
      noKhaytText: !/\bKhayt\b/i.test(document.querySelector('#dashboardContent')?.textContent || ''),
    };
  });
  assert('Bed Ready home hero renders on dashboard', home.hasHero === true);
  assert(`hero headline is the Bed Ready tagline (${home.headline.slice(0, 32)}…)`, /any bed/i.test(home.headline));
  assert(`hero shows sticker badges (${home.stickers})`, home.stickers >= 3);
  assert('dashboard home has no "Khayt" text', home.noKhaytText === true);

  // Orca filament installer: home card present + the modal API is exposed (Bed Ready flavor only).
  const orcaFila = await window.evaluate(() => ({
    card: !!document.querySelector('#dashboardContent [data-filaments]'),
    api: typeof window.BedReadyFilaments?.open,
    bridge: typeof window.hubAPI?.orcaFilaManifest,
  }));
  assert('filament installer card present on home', orcaFila.card === true);
  assert('window.BedReadyFilaments.open exposed', orcaFila.api === 'function');
  assert('hubAPI.orcaFilaManifest bridge exposed', orcaFila.bridge === 'function');

  // MakerRun catalogue: bridges exist, the home card opens the panel, and the browse modal renders
  // a result. The browse handler is REPLACED in the main process with a fixture, so this never touches
  // the network and needs no test seam in the app itself.
  console.log('\n[MakerRun catalogue]');
  const mr = await window.evaluate(() => {
    const names = ['makerrunBrowse', 'makerrunDesign', 'makerrunDownloadToLib', 'makerrunPublishCreate',
      'makerrunPublishFile', 'makerrunPublishImages', 'makerrunStatus', 'makerrunDelete',
      'makerrunOpenAge', 'makerrunOpenPage'];
    return {
      missing: names.filter((n) => typeof window.hubAPI?.[n] !== 'function'),
      open: typeof window.BedReadyMakerRun?.open,
      publish: typeof window.BedReadyMakerRun?.publish,
      card: !!document.querySelector('#dashboardContent [data-makerrun]'),
      terms: Array.isArray(window.BedReadyMakerRunTerms?.CATEGORIES) ? window.BedReadyMakerRunTerms.CATEGORIES.length : 0,
    };
  });
  assert(`all MakerRun catalogue bridges exposed (${mr.missing.join(', ') || 'none missing'})`, mr.missing.length === 0);
  assert('window.BedReadyMakerRun.open / .publish exposed', mr.open === 'function' && mr.publish === 'function');
  assert('MakerRun catalogue card present on home', mr.card === true);
  assert(`MakerRun vocabularies loaded (${mr.terms} categories)`, mr.terms === 14);

  const MR_FIXTURE = {
    ok: true,
    designs: [{
      slug: 'e2e-desk-hook-a1b2c3', title: 'E2E desk hook', description: 'fixture', creator: null,
      license: 'CC-BY-4.0', commercialUse: true, category: 'household', material: 'rigid', nsfw: false,
      url: 'https://makerrun.com/designs/e2e-desk-hook-a1b2c3', cover: null, sale: null,
      verification: { badge: true, fileChecked: true, printPhotoConfirmed: false, printer: null },
    }],
    page: { limit: 24, offset: 0, total: 1, returned: 1 },
  };
  await electronApp.evaluate(({ ipcMain }, fixture) => {
    ipcMain.removeHandler('hub:makerrun-browse');
    ipcMain.handle('hub:makerrun-browse', () => fixture);
  }, MR_FIXTURE);
  await window.evaluate(() => document.querySelector('#dashboardContent [data-makerrun]').click());
  await window.waitForSelector('.mr-overlay .mr-card', { timeout: 15_000 });
  const mrModal = await window.evaluate(() => ({
    cards: document.querySelectorAll('.mr-overlay .mr-card').length,
    title: document.querySelector('.mr-overlay .mr-card')?.textContent || '',
    dialog: !!document.querySelector('.mr-overlay [role="dialog"][aria-modal="true"]'),
  }));
  assert(`browse modal renders the stubbed result (${mrModal.cards} card)`, mrModal.cards === 1 && /E2E desk hook/.test(mrModal.title));
  assert('browse modal is an aria-modal dialog', mrModal.dialog === true);
  await window.evaluate(() => document.querySelector('.mr-overlay .mr-close').click());

  // ── Branding guard: the standalone product must never surface "Khayt" ──────────────────────────────
  // Bed Ready shares Khayt's locale files + shared core, so leaks recur as features land. Assert the
  // three surfaces that have leaked before: localized strings, generated files, and the native menu.
  console.log('\n[branding — no "Khayt" leaks]');

  // (a) Every en-locale value that contains "Khayt" must rebrand when rendered via t().
  const locale = await window.evaluate(() => {
    const en = (window.KhaytLocales && window.KhaytLocales.en) || {};
    const bearing = Object.keys(en).filter((k) => typeof en[k] === 'string' && /Khayt/.test(en[k]));
    const leaks = bearing.filter((k) => /\bKhayt\b/.test(window.t(k)));
    return { checked: bearing.length, leaks };
  });
  assert(
    `all ${locale.checked} "Khayt"-bearing locale keys rebrand via t() (${locale.leaks.length ? 'LEAKS: ' + locale.leaks.slice(0, 6).join(', ') : '0 leaks'})`,
    locale.checked > 0 && locale.leaks.length === 0
  );

  // (b) The generated recovery-code file must be product-branded, not "Khayt".
  const recovery = await window.evaluate(() =>
    (window.KhaytAppSecurity && typeof window.KhaytAppSecurity.buildRecoveryCodeFile === 'function')
      ? String(window.KhaytAppSecurity.buildRecoveryCodeFile('AAAA-BBBB-CCCC-DDDD') || '') : '(unavailable)');
  assert(`recovery-code file is not "Khayt"-branded (${recovery.split('\n')[0]})`, recovery !== '' && !/Khayt/.test(recovery));

  // (c) The native macOS menu bar (About / Hide / Quit …) must read the product name, not "khayt".
  // The app menu only exists on darwin; on other platforms items[0] is the File menu, so skip there.
  if (process.platform === 'darwin') {
    const menu = await electronApp.evaluate(({ Menu }) => {
      const appMenu = Menu.getApplicationMenu()?.items?.[0];
      return {
        label: appMenu?.label || '',
        items: (appMenu?.submenu?.items || []).map((i) => i.label).filter(Boolean),
      };
    });
    assert(`native menu app label not "khayt" (${menu.label})`, !/khayt/i.test(menu.label));
    assert(`native menu items free of "khayt" (${menu.items.join(', ')})`, menu.items.length > 0 && !menu.items.some((l) => /khayt/i.test(l)));
  } else {
    console.log('  – native menu check skipped (darwin-only)');
  }

  console.log('\n[no uncaught renderer errors during boot]');
  assert(`pageerror count === 0 (${pageErrors.join(' | ') || 'none'})`, pageErrors.length === 0);

  console.log('\n✅ Bed Ready smoke: all assertions passed');
}

main()
  .then(async () => { await electronApp?.close(); process.exit(0); })
  .catch(async (err) => {
    console.error('\n❌ Bed Ready smoke FAILED:', err.message);
    if (pageErrors.length) console.error('   pageerrors:', pageErrors);
    await electronApp?.close();
    process.exit(1);
  });
