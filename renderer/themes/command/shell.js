/**
 * Command shell — dense pro "command-center" chrome around the shared renderer.
 *
 * Mirrors the proven Workbench shell pattern (reparent + re-skin the SAME DOM,
 * fully reversible on teardown) and adds the extra chrome the Command prototype
 * (design/proto-b-cockpit.html) shows:
 *
 *  - A slim ICON RAIL to the inline-start of the sidebar. Each rail icon is a
 *    thin proxy for an existing `.tab-btn`; clicking it calls the SAME button so
 *    navigation logic is untouched. Module-colored, with live/badge dots.
 *  - The existing sidebar becomes the dense CONTEXT NAV column (grouped Work /
 *    Catalog / Money, module-colored icon dots, pro-only gating preserved).
 *  - The shared top bar becomes the TOOLBAR; an open-tab strip is injected that
 *    reflects recently visited tabs (visual; clicking re-activates the tab).
 *  - A right INSPECTOR panel container (shell-level). Wired for the dashboard /
 *    queue selection where feasible; otherwise it stays hidden. See the
 *    "needs visual iteration" notes in the handoff.
 *  - A bottom STATUS BAR fed from live order / printer / stock counts + clock.
 *
 * Everything is reversed on teardown.
 */
(function (global) {
  // Translate with graceful English fallback (follows language switches).
  const tr = (k, d) => { const s = (typeof t === 'function') ? t(k) : null; return (s && s !== k) ? s : d; };

  // Grouped layout: ordered groups of nav tabs. Tabs not listed here keep their
  // original position (e.g. dashboard stays at top, settings in footer).
  const GROUPS = [
    { key: 'work', labelKey: 'command.group.work', label: 'Work',
      tabs: ['calculator-tab', 'queue-tab', 'printfiles-tab', 'colorstudio-tab', 'converter-tab', 'inventory-tab', 'waste-tab'] },
    { key: 'catalog', labelKey: 'command.group.catalog', label: 'Catalog',
      tabs: ['catalog-tab', 'clients-tab', 'gift-cards-tab', 'portfolio-tab'] },
    { key: 'money', labelKey: 'command.group.money', label: 'Money',
      tabs: ['logs-tab', 'analytics-tab', 'expenses-tab'] },
  ];

  // Per-tab MODULE color (CSS var name from tokens.css) — color codes meaning.
  const MOD = {
    'dashboard-tab': 'var(--cmd-dash)',
    'calculator-tab': 'var(--cmd-calc)',
    'queue-tab': 'var(--cmd-queue)',
    'printfiles-tab': 'var(--cmd-calc)',
    'colorstudio-tab': 'var(--cmd-analytics)',
    'converter-tab': 'var(--cmd-queue)',
    'inventory-tab': 'var(--cmd-inv)',
    'waste-tab': 'var(--cmd-warn)',
    'catalog-tab': 'var(--cmd-dash)',
    'clients-tab': 'var(--cmd-clients)',
    'gift-cards-tab': 'var(--cmd-invoice)',
    'portfolio-tab': 'var(--cmd-calc)',
    'logs-tab': 'var(--cmd-invoice)',
    'analytics-tab': 'var(--cmd-analytics)',
    'expenses-tab': 'var(--cmd-inv)',
    'settings-tab': 'var(--cmd-settings)',
  };

  // Compact rail glyph per tab (reuses the shared nav glyphs where possible).
  const RAIL_GLYPH = {
    'dashboard-tab': '◳',
    'calculator-tab': '∑',
    'queue-tab': '▦',
    'printfiles-tab': '▧',
    'colorstudio-tab': '◑',
    'converter-tab': '⇄',
    'inventory-tab': '▣',
    'waste-tab': '△',
    'catalog-tab': '▤',
    'clients-tab': '☺︎',      /* U+FE0E forces text (monochrome) presentation */
    'gift-cards-tab': '♦︎',
    'portfolio-tab': '◇',
    'logs-tab': '❖',
    'analytics-tab': '◔',
    'expenses-tab': '◧',
    'settings-tab': '⛭︎',
  };

  // The rail mirrors these tabs, top to bottom (settings rides the rail footer).
  const RAIL_ORDER = [
    'dashboard-tab', 'calculator-tab', 'queue-tab',
    'printfiles-tab', 'colorstudio-tab', 'converter-tab',
    'inventory-tab', 'waste-tab',
    'catalog-tab', 'clients-tab', 'gift-cards-tab', 'portfolio-tab',
    'logs-tab', 'analytics-tab', 'expenses-tab',
  ];

  function isOn() { return document.body.classList.contains('khayt-command'); }

  function escHtml(s) {
    return (typeof escapeHtml === 'function') ? escapeHtml(String(s)) : String(s);
  }

  /* ---------- Icon rail (new shell-level chrome) ---------- */

  function ensureRail() {
    const body = document.querySelector('.khayt-body');
    if (!body) return null;
    let rail = document.getElementById('commandRail');
    if (!rail) {
      rail = document.createElement('div');
      rail.id = 'commandRail';
      rail.setAttribute('aria-hidden', 'true'); // duplicate proxy of the real nav
      body.insertBefore(rail, body.firstChild); // inline-start of the sidebar
    }
    return rail;
  }

  function removeRail() {
    document.getElementById('commandRail')?.remove();
  }

  // Build a thin rail proxy that forwards clicks to the real .tab-btn. We
  // re-derive visibility from the real button each sync (pro-only / hidden).
  function syncRail() {
    const rail = ensureRail();
    if (!rail) return;
    const activeTab = document.querySelector('.tab-content.active')?.id
      || document.querySelector('.tab-btn.active')?.dataset.tab
      || 'dashboard-tab';

    const items = RAIL_ORDER.map((tabId) => {
      const realBtn = document.querySelector(`.tab-btn[data-tab="${tabId}"]`);
      if (!realBtn) return '';
      // Skip tabs hidden in simple mode (pro-only collapses the real button).
      const hidden = realBtn.offsetParent === null
        && (realBtn.classList.contains('pro-only') || realBtn.closest('.pro-only'));
      if (hidden) return '';
      const live = realBtn.querySelector('.khayt-live') ? '<span class="cmd-rail-live"></span>' : '';
      const on = tabId === activeTab ? 'active' : '';
      const label = realBtn.querySelector('.nav-label')?.textContent?.trim()
        || tabId.replace('-tab', '');
      return `<button type="button" class="cmd-rail-ic ${on}" data-cmd-rail="${escHtml(tabId)}"
        style="--rc:${MOD[tabId] || 'var(--cmd-settings)'}" title="${escHtml(label)}" tabindex="-1">${
        escHtml(RAIL_GLYPH[tabId] || '•')}${live}</button>`;
    }).join('');

    const settingsBtn = document.querySelector('.tab-btn[data-tab="settings-tab"]');
    const settingsOn = activeTab === 'settings-tab' ? 'active' : '';
    const settingsItem = settingsBtn
      ? `<button type="button" class="cmd-rail-ic ${settingsOn}" data-cmd-rail="settings-tab"
          style="--rc:var(--cmd-settings)" title="${escHtml(tr('tab.settings', 'Settings'))}" tabindex="-1">${
          escHtml(RAIL_GLYPH['settings-tab'])}</button>`
      : '';

    rail.innerHTML = `
      <div class="cmd-rail-mark">خ</div>
      <div class="cmd-rail-list">${items}</div>
      <div class="cmd-rail-sp"></div>
      ${settingsItem}`;

    rail.querySelectorAll('[data-cmd-rail]').forEach((proxy) => {
      proxy.addEventListener('click', () => {
        const tabId = proxy.dataset.cmdRail;
        if (typeof switchTab === 'function') switchTab(tabId);
        else document.querySelector(`.tab-btn[data-tab="${tabId}"]`)?.click();
      });
    });
  }

  /* ---------- Sidebar regrouping (mirrors Workbench, fully reversible) ---------- */

  function applyModuleColors() {
    document.querySelectorAll('.khayt-nav .tab-btn[data-tab], .khayt-navfoot .tab-btn[data-tab]').forEach((btn) => {
      const c = MOD[btn.dataset.tab];
      if (c) btn.style.setProperty('--cmd-mod', c);
    });
  }

  function clearModuleColors() {
    document.querySelectorAll('.tab-btn[data-tab]').forEach((btn) => {
      btn.style.removeProperty('--cmd-mod');
    });
  }

  function buildGroups() {
    const nav = document.querySelector('.khayt-nav');
    if (!nav || nav.querySelector('[data-cmd-group]')) return; // already built

    // Remember each button's original parent + position so teardown can restore.
    nav.querySelectorAll('.tab-btn[data-tab]').forEach((btn) => {
      if (btn.dataset.cmdHome) return;
      const sec = btn.closest('.khayt-navsec');
      if (!sec) return;
      if (!sec.id) sec.id = `cmd-orig-${Math.random().toString(36).slice(2, 8)}`;
      const sibs = [...sec.children];
      btn.dataset.cmdHome = sec.id;
      btn.dataset.cmdHomeIdx = String(sibs.indexOf(btn));
      // Preserve simple-mode gating: a tab hidden only via its `pro-only` parent
      // section must keep that gating after it's reparented into a new group
      // (e.g. analytics-tab, whose button itself has no `pro-only` class).
      if (!btn.classList.contains('pro-only') && sec.classList.contains('pro-only')) {
        btn.classList.add('pro-only');
        btn.dataset.cmdProonly = '1';
      }
    });

    GROUPS.forEach((grp) => {
      const wrap = document.createElement('div');
      wrap.className = 'khayt-navsec nav-group';
      wrap.dataset.cmdGroup = grp.key;
      const head = document.createElement('div');
      head.className = 'eyebrow khayt-navhead nav-group-label';
      head.dataset.cmdGroupHead = '1';
      head.textContent = tr(grp.labelKey, grp.label);
      wrap.appendChild(head);
      grp.tabs.forEach((tabId) => {
        const btn = document.querySelector(`.khayt-nav .tab-btn[data-tab="${tabId}"]`);
        if (btn) wrap.appendChild(btn); // moves the SAME button (events intact)
      });
      nav.appendChild(wrap);
    });

    syncGroupVisibility();
  }

  /**
   * Hide any nav section with nothing showing under it — heading included.
   *
   * The old check asked whether the section still CONTAINED a nav button. That is right
   * for the original sections this regrouping empties out, and wrong for everything else:
   * Bed Ready has no catalog-tab/clients-tab/logs-tab at all, so "Catalog" and "Money"
   * were built, received nothing, and rendered as headings over blank space; Khayt in
   * simple mode DOES have those buttons, hidden by `.biz-only { display: none }`, which
   * a DOM-presence test can never see. The test is what is VISIBLE.
   *
   * Computed style rather than offsetParent on purpose: this runs while the shell is
   * being applied, before the sidebar is necessarily laid out, and offsetParent would
   * then read every button as hidden and take the whole nav with it.
   */
  function syncGroupVisibility() {
    const nav = document.querySelector('.khayt-nav');
    if (!nav) return;
    nav.querySelectorAll('.khayt-navsec').forEach((sec) => {
      const built = !!sec.dataset.cmdGroup;
      const buttons = [...sec.querySelectorAll('.tab-btn[data-tab]')];
      // A group this shell built is empty when nothing in it SHOWS. An original section
      // is empty when the regrouping took its buttons away — left on the DOM-presence
      // test it has always used, because those sections outlive this shell and a stale
      // inline style on one is a section that never comes back.
      const shows = built
        ? buttons.some((btn) => getComputedStyle(btn).display !== 'none')
        : buttons.length > 0;
      sec.classList.toggle('cmd-nav-empty', !shows);
      // The class alone is not enough for the groups. Its rule lives in this theme's
      // shell.css, and Bed Ready loads the shell JS WITHOUT the theme stylesheet — which
      // is exactly where the empty groups show up, so there the class styled nothing. The
      // inline display does not care which stylesheets shipped, and it rides on a wrapper
      // this shell removes wholesale on teardown.
      if (built) sec.style.display = shows ? '' : 'none';
    });
  }

  function relabelGroups() {
    document.querySelectorAll('[data-cmd-group-head]').forEach((head) => {
      const grp = GROUPS.find((g) => g.key === head.closest('[data-cmd-group]')?.dataset.cmdGroup);
      if (grp) head.textContent = tr(grp.labelKey, grp.label);
    });
  }

  function restoreGroups() {
    const buttons = [...document.querySelectorAll('.tab-btn[data-cmd-home]')];
    buttons.sort((a, b) => Number(a.dataset.cmdHomeIdx) - Number(b.dataset.cmdHomeIdx));
    buttons.forEach((btn) => {
      const sec = document.getElementById(btn.dataset.cmdHome);
      if (sec) {
        const idx = Number(btn.dataset.cmdHomeIdx);
        const ref = sec.children[idx] || null;
        sec.insertBefore(btn, ref);
      }
      if (btn.dataset.cmdProonly) {
        btn.classList.remove('pro-only');
        delete btn.dataset.cmdProonly;
      }
      delete btn.dataset.cmdHome;
      delete btn.dataset.cmdHomeIdx;
    });
    document.querySelectorAll('[data-cmd-group]').forEach((el) => el.remove());
    document.querySelectorAll('.khayt-navsec').forEach((sec) => {
      sec.classList.remove('cmd-nav-empty');
      sec.style.removeProperty('display');
    });
  }

  /* ---------- Toolbar: open-tab strip in the shared top bar ---------- */

  // Track recently visited tabs as "open tabs" (visual, like an editor).
  const openTabs = ['dashboard-tab'];

  function ensureToolbar() {
    const top = document.querySelector('.khayt-top');
    if (!top) return null;
    let bar = top.querySelector('.cmd-tabstrip');
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'cmd-tabstrip';
      const titleWrap = top.querySelector('.khayt-toptitle');
      if (titleWrap && titleWrap.nextSibling) top.insertBefore(bar, titleWrap.nextSibling);
      else if (titleWrap) titleWrap.after(bar);
      else top.appendChild(bar);
    }
    return bar;
  }

  function removeToolbar() {
    document.querySelector('.khayt-top .cmd-tabstrip')?.remove();
  }

  function syncToolbar(tabId) {
    const bar = ensureToolbar();
    if (!bar) return;
    const active = tabId || document.querySelector('.tab-content.active')?.id || 'dashboard-tab';
    if (!openTabs.includes(active)) openTabs.push(active);
    // Cap the strip so it never overflows the toolbar.
    while (openTabs.length > 6) openTabs.shift();

    // With a single open tab the strip just echoes the page title beside it —
    // only show the editor-style strip once a second screen has been opened.
    if (openTabs.length < 2) { bar.innerHTML = ''; bar.hidden = true; return; }
    bar.hidden = false;

    bar.innerHTML = openTabs.map((id) => {
      const btn = document.querySelector(`.tab-btn[data-tab="${id}"]`);
      const label = btn?.querySelector('.nav-label')?.textContent?.trim() || id.replace('-tab', '');
      const on = id === active ? 'on' : '';
      return `<button type="button" class="cmd-tab ${on}" data-cmd-tab="${escHtml(id)}"
        style="--tc:${MOD[id] || 'var(--cmd-dash)'}">
        <span class="cmd-tab-dot"></span><span class="cmd-tab-lbl">${escHtml(label)}</span></button>`;
    }).join('');

    bar.querySelectorAll('[data-cmd-tab]').forEach((tab) => {
      tab.addEventListener('click', () => {
        const id = tab.dataset.cmdTab;
        if (typeof switchTab === 'function') switchTab(id);
      });
    });
  }

  /* ---------- Right inspector panel (shell-level container) ---------- */

  function ensureInspector() {
    const body = document.querySelector('.khayt-body');
    if (!body) return null;
    let insp = document.getElementById('commandInspector');
    if (!insp) {
      insp = document.createElement('aside');
      insp.id = 'commandInspector';
      insp.setAttribute('aria-hidden', 'true');
      insp.hidden = true;
      body.appendChild(insp); // inline-end of the body row
    }
    return insp;
  }

  function removeInspector() {
    document.getElementById('commandInspector')?.remove();
    document.body.classList.remove('cmd-has-insp');
  }

  // Public: open the inspector with arbitrary HTML (used by screens.js).
  function openInspector(html, titleHtml) {
    const insp = ensureInspector();
    if (!insp) return;
    insp.innerHTML = `
      <div class="cmd-insp-hd">
        <div class="cmd-insp-t">${titleHtml || ''}</div>
        <button type="button" class="cmd-insp-x" data-cmd-insp-close aria-label="Close">×</button>
      </div>
      <div class="cmd-insp-scroll">${html || ''}</div>`;
    insp.hidden = false;
    // Was created aria-hidden (duplicate-proxy default); it now holds unique,
    // visible content — expose it to assistive tech while open.
    insp.removeAttribute('aria-hidden');
    document.body.classList.add('cmd-has-insp');
    insp.querySelector('[data-cmd-insp-close]')?.addEventListener('click', closeInspector);
  }

  function closeInspector() {
    const insp = document.getElementById('commandInspector');
    if (insp) { insp.hidden = true; insp.innerHTML = ''; insp.setAttribute('aria-hidden', 'true'); }
    document.body.classList.remove('cmd-has-insp');
  }

  /* ---------- Bottom status bar (live counts) ---------- */

  function ensureStatusBar() {
    const appRoot = document.querySelector('.khayt-app');
    if (!appRoot) return null;
    let bar = document.getElementById('commandStatusBar');
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'commandStatusBar';
      bar.setAttribute('aria-hidden', 'true');
      appRoot.appendChild(bar); // sits below .khayt-body in the column
    }
    return bar;
  }

  function removeStatusBar() {
    document.getElementById('commandStatusBar')?.remove();
  }

  function syncStatusBar() {
    const bar = document.getElementById('commandStatusBar');
    if (!bar || !isOn()) return;

    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const mach = (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : [];
    const inv = (typeof inventory !== 'undefined' && Array.isArray(inventory)) ? inventory : [];

    const queue = log.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote').length;
    // "printers active" — reuse the dashboard's single source of truth so the
    // status bar and the KPI always agree (offline/error/100% handled there).
    const printing = (global.KhaytCommand && typeof global.KhaytCommand.activePrinterCount === 'function')
      ? global.KhaytCommand.activePrinterCount()
      : log.filter((o) => o.status === 'printing').length;
    const printers = mach.length;
    const lowStock = (typeof isLowStock === 'function') ? inv.filter(isLowStock).length : 0;

    const today = new Date(); today.setHours(0, 0, 0, 0);
    const todayStr = (typeof localDateStr === 'function') ? localDateStr(today) : localDateStr(today);
    const dueToday = log.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote' && o.dueDate === todayStr).length;
    const todayRev = (typeof orderNetRevenueBase === 'function')
      ? log.filter((o) => KhaytOrderStatus.isFinished(o) && o.date === todayStr).reduce((s, o) => s + orderNetRevenueBase(o), 0)
      : 0;
    const ccy = (typeof currencySymbol === 'function') ? currencySymbol() : 'SAR';
    const revStr = (typeof fmtMoney === 'function') ? fmtMoney(todayRev) : String(Math.round(todayRev));

    const now = new Date();
    const clock = now.toLocaleTimeString(localeTag(), { hour: '2-digit', minute: '2-digit', hour12: false });

    bar.innerHTML = `
      <span class="cmd-seg"><span class="cmd-live"></span><b>${escHtml(printing)}/${escHtml(printers)}</b> ${escHtml(tr('command.status.printers', 'printers active'))}</span>
      <span class="cmd-seg">${escHtml(tr('command.status.queue', 'queue'))} <b>${escHtml(queue)}</b></span>
      <span class="cmd-seg">${escHtml(tr('command.status.due_today', 'due today'))} <b style="color:var(--cmd-warn)">${escHtml(dueToday)}</b></span>
      <span class="cmd-seg">${escHtml(tr('command.status.low_stock', 'low stock'))} <b style="color:var(--cmd-danger)">${escHtml(lowStock)}</b></span>
      <span class="cmd-sp"></span>
      <span class="cmd-seg">${escHtml(tr('command.status.palette', '⌘K palette'))}</span>
      ${(typeof KhaytTiers === 'undefined' || KhaytTiers.showsBusiness(settings.mode)) ? `<span class="cmd-seg">${escHtml(tr('command.status.today', 'today'))} <b>${escHtml(revStr)} ${escHtml(ccy)}</b></span>` : ''}
      <span class="cmd-seg cmd-clock">${escHtml(clock)}</span>`;
  }

  let clockTimer = null;
  function startClock() {
    stopClock();
    clockTimer = setInterval(() => {
      const clk = document.querySelector('#commandStatusBar .cmd-clock');
      if (clk) clk.textContent = new Date().toLocaleTimeString(localeTag(), { hour: '2-digit', minute: '2-digit', hour12: false });
      else stopClock();
    }, 1000);
  }
  function stopClock() {
    if (clockTimer) { clearInterval(clockTimer); clockTimer = null; }
  }

  /* ---------- Lifecycle ---------- */

  function syncCommandPageHead(tabId) {
    if (!isOn()) return;
    syncGroupVisibility();
    relabelGroups();
    applyModuleColors();
    syncRail();
    syncToolbar(tabId);
    syncStatusBar();
    // Selection-driven; clear the inspector on plain navigation.
    closeInspector();
  }

  function applyCommandShell() {
    document.getElementById('appSidebar')?.classList.remove('collapsed');
    ensureRail();
    buildGroups();
    applyModuleColors();
    ensureToolbar();
    ensureInspector();
    ensureStatusBar();
    syncRail();
    syncToolbar();
    syncStatusBar();
    startClock();
  }

  function teardownCommandShell() {
    stopClock();
    restoreGroups();
    clearModuleColors();
    removeRail();
    removeToolbar();
    removeInspector();
    removeStatusBar();
    openTabs.length = 0;
    openTabs.push('dashboard-tab');
  }

  global.KhaytCommandShell = {
    applyCommandShell,
    teardownCommandShell,
    syncCommandPageHead,
    syncGroupVisibility,
    syncStatusBar,
    syncRail,
    openInspector,
    closeInspector,
    GROUPS,
    MOD,
  };
})(typeof window !== 'undefined' ? window : globalThis);
