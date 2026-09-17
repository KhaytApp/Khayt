/**
 * Vivid shell — bold, colorful chrome around the shared renderer.
 *
 * Built faithfully on the proven Workbench shell pattern, plus the signature
 * Vivid mechanic: a colored toolbar BAND + screen accents that RECOLOR per
 * active module (Dashboard indigo, Queue blue, Fleet/Inventory violet, Money
 * green, …). The hue is set live on <html> as --hue / --hue-2 on every tab
 * switch, so the band, gradient primary action, charts and accents all shift.
 *
 * What it does on mount:
 *  - Regroups the existing `.tab-btn` nav into Work / Catalog / Money groups
 *    (relabel + reparent the SAME buttons — navigation logic is untouched).
 *  - Paints a color tile behind each nav icon.
 *  - Builds the colored toolbar band (recolors per active tab).
 *  - Builds a bottom status bar fed from live order/printer counts.
 *
 * Everything is reversed on teardown: buttons return to their original
 * sections, injected chrome is removed, inline tile colors + the --hue
 * overrides are cleared.
 */
(function (global) {
  // Translate with graceful English fallback (follows language switches).
  const tr = (k, d) => { const s = (typeof t === 'function') ? t(k) : null; return (s && s !== k) ? s : d; };

  // Grouped layout: ordered groups of nav tabs. Tabs not listed here keep
  // their original position (e.g. dashboard stays at top, settings in footer).
  const GROUPS = [
    { key: 'work', labelKey: 'vivid.group.work', label: 'Work',
      tabs: ['calculator-tab', 'queue-tab', 'printfiles-tab', 'colorstudio-tab', 'converter-tab', 'inventory-tab', 'waste-tab'] },
    { key: 'catalog', labelKey: 'vivid.group.catalog', label: 'Catalog',
      tabs: ['catalog-tab', 'clients-tab', 'gift-cards-tab', 'portfolio-tab'] },
    { key: 'money', labelKey: 'vivid.group.money', label: 'Money',
      tabs: ['logs-tab', 'analytics-tab', 'expenses-tab'] },
  ];

  // Per-tab tile color (CSS var name from tokens.css).
  const TILE = {
    'dashboard-tab': 'var(--vivid-dashboard)',
    'calculator-tab': 'var(--vivid-calculator)',
    'queue-tab': 'var(--vivid-queue)',
    'inventory-tab': 'var(--vivid-inventory)',
    'waste-tab': 'var(--vivid-waste)',
    'catalog-tab': 'var(--vivid-catalog)',
    'clients-tab': 'var(--vivid-clients)',
    'gift-cards-tab': 'var(--vivid-gift)',
    'portfolio-tab': 'var(--vivid-portfolio)',
    'logs-tab': 'var(--vivid-money)',
    'analytics-tab': 'var(--vivid-analytics)',
    'expenses-tab': 'var(--vivid-money)',
    'settings-tab': 'var(--vivid-settings)',
  };

  // Per-tab hue PAIR (concrete hex from tokens) — drives --hue / --hue-2 so the
  // toolbar band, charts and accents recolor with the active module.
  const HUE = {
    'dashboard-tab':  ['var(--vivid-dashboard)', 'var(--vivid-dashboard-2)'],
    'calculator-tab': ['var(--vivid-calculator)', 'var(--vivid-calculator-2)'],
    'queue-tab':      ['var(--vivid-queue)', 'var(--vivid-queue-2)'],
    'inventory-tab':  ['var(--vivid-inventory)', 'var(--vivid-inventory-2)'],
    'waste-tab':      ['var(--vivid-waste)', 'var(--vivid-waste-2)'],
    'catalog-tab':    ['var(--vivid-catalog)', 'var(--vivid-catalog-2)'],
    'clients-tab':    ['var(--vivid-clients)', 'var(--vivid-clients-2)'],
    'gift-cards-tab': ['var(--vivid-gift)', 'var(--vivid-gift-2)'],
    'portfolio-tab':  ['var(--vivid-portfolio)', 'var(--vivid-portfolio-2)'],
    'logs-tab':       ['var(--vivid-money)', 'var(--vivid-money-2)'],
    'analytics-tab':  ['var(--vivid-analytics)', 'var(--vivid-analytics-2)'],
    'expenses-tab':   ['var(--vivid-money)', 'var(--vivid-money-2)'],
    'settings-tab':   ['var(--vivid-settings)', 'var(--vivid-settings-2)'],
  };

  function isOn() { return document.body.classList.contains('khayt-vivid'); }

  /* ---------- Per-module hue ---------- */

  function applyHue(tabId) {
    const root = document.documentElement;
    const pair = HUE[tabId] || HUE['dashboard-tab'];
    root.style.setProperty('--hue', pair[0]);
    root.style.setProperty('--hue-2', pair[1]);
  }

  function clearHue() {
    const root = document.documentElement;
    root.style.removeProperty('--hue');
    root.style.removeProperty('--hue-2');
  }

  /* ---------- Sidebar regrouping ---------- */

  function applyTiles() {
    document.querySelectorAll('.khayt-nav .tab-btn[data-tab], .khayt-navfoot .tab-btn[data-tab]').forEach((btn) => {
      const tile = TILE[btn.dataset.tab];
      if (tile) btn.style.setProperty('--vv-tile', tile);
    });
  }

  function clearTiles() {
    document.querySelectorAll('.tab-btn[data-tab]').forEach((btn) => {
      btn.style.removeProperty('--vv-tile');
    });
  }

  function buildGroups() {
    const nav = document.querySelector('.khayt-nav');
    if (!nav || nav.querySelector('[data-vv-group]')) return; // already built

    // Remember each button's original parent + position so teardown can restore.
    nav.querySelectorAll('.tab-btn[data-tab]').forEach((btn) => {
      if (btn.dataset.vvHome) return;
      const sec = btn.closest('.khayt-navsec');
      if (!sec) return;
      if (!sec.id) sec.id = `vv-orig-${Math.random().toString(36).slice(2, 8)}`;
      const sibs = [...sec.children];
      btn.dataset.vvHome = sec.id;
      btn.dataset.vvHomeIdx = String(sibs.indexOf(btn));
      // Preserve simple-mode gating: a tab hidden only via its `pro-only` parent
      // section must keep that gating after it's reparented into a new group
      // (e.g. analytics-tab, whose button itself has no `pro-only` class).
      if (!btn.classList.contains('pro-only') && sec.classList.contains('pro-only')) {
        btn.classList.add('pro-only');
        btn.dataset.vvProonly = '1';
      }
    });

    GROUPS.forEach((grp) => {
      const wrap = document.createElement('div');
      wrap.className = 'khayt-navsec nav-group';
      wrap.dataset.vvGroup = grp.key;
      const head = document.createElement('div');
      head.className = 'eyebrow khayt-navhead nav-group-label';
      head.dataset.vvGroupHead = '1';
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
      const built = !!sec.dataset.vvGroup;
      const buttons = [...sec.querySelectorAll('.tab-btn[data-tab]')];
      // A group this shell built is empty when nothing in it SHOWS. An original section
      // is empty when the regrouping took its buttons away — left on the DOM-presence
      // test it has always used, because those sections outlive this shell and a stale
      // inline style on one is a section that never comes back.
      const shows = built
        ? buttons.some((btn) => getComputedStyle(btn).display !== 'none')
        : buttons.length > 0;
      sec.classList.toggle('vv-nav-empty', !shows);
      // The class alone is not enough for the groups. Its rule lives in this theme's
      // shell.css, and Bed Ready loads the shell JS WITHOUT the theme stylesheet — which
      // is exactly where the empty groups show up, so there the class styled nothing. The
      // inline display does not care which stylesheets shipped, and it rides on a wrapper
      // this shell removes wholesale on teardown.
      if (built) sec.style.display = shows ? '' : 'none';
    });
  }

  function relabelGroups() {
    document.querySelectorAll('[data-vv-group-head]').forEach((head) => {
      const grp = GROUPS.find((g) => g.key === head.closest('[data-vv-group]')?.dataset.vvGroup);
      if (grp) head.textContent = tr(grp.labelKey, grp.label);
    });
  }

  function restoreGroups() {
    // Move each button back to its recorded home section + index.
    const buttons = [...document.querySelectorAll('.tab-btn[data-vv-home]')];
    // Restore in ascending original index so insertion lands correctly.
    buttons.sort((a, b) => Number(a.dataset.vvHomeIdx) - Number(b.dataset.vvHomeIdx));
    buttons.forEach((btn) => {
      const sec = document.getElementById(btn.dataset.vvHome);
      if (sec) {
        const idx = Number(btn.dataset.vvHomeIdx);
        const ref = sec.children[idx] || null;
        sec.insertBefore(btn, ref);
      }
      // Undo the pro-only class we added during regrouping (the button returns
      // to its original pro-only section, which gates it again).
      if (btn.dataset.vvProonly) {
        btn.classList.remove('pro-only');
        delete btn.dataset.vvProonly;
      }
      delete btn.dataset.vvHome;
      delete btn.dataset.vvHomeIdx;
    });
    document.querySelectorAll('[data-vv-group]').forEach((el) => el.remove());
    document.querySelectorAll('.khayt-navsec').forEach((sec) => {
      sec.classList.remove('vv-nav-empty');
      sec.style.removeProperty('display');
    });
  }

  /* ---------- Toolbar (per-screen segment in the shared top bar) ---------- */

  // The per-screen segment pills (Board/By machine/Calendar, All/Unpaid/Paid, …)
  // were purely decorative — rendered aria-hidden/tabindex=-1 and only toggled a
  // class, so they did nothing but mislead users. Removed for accessibility;
  // re-add here wired to real view-switches if/when those land.

  function removeToolbar() {
    document.querySelector('.khayt-top .vv-toolbar')?.remove();
  }

  function syncToolbar() {
    removeToolbar();
  }

  /* ---------- Bottom status bar (live counts) ---------- */

  function ensureStatusBar() {
    const appRoot = document.querySelector('.khayt-app');
    if (!appRoot) return null;
    let bar = document.getElementById('vividStatusBar');
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'vividStatusBar';
      bar.setAttribute('aria-hidden', 'true');
      appRoot.appendChild(bar); // sits below .khayt-body in the column
    }
    return bar;
  }

  function removeStatusBar() {
    document.getElementById('vividStatusBar')?.remove();
  }

  function syncStatusBar() {
    const bar = document.getElementById('vividStatusBar');
    if (!bar || !isOn()) return;

    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const openOrders = log.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote').length;
    const printing = log.filter((o) => o.status === 'printing').length;

    // Filament used today (kg) — inventory usageHistory, the SAME source as the
    // dashboard "Filament used" tile (so the two chrome surfaces never disagree).
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const dayStr = (typeof localDateStr === 'function')
      ? localDateStr(today)
      : localDateStr(today);
    const inv = (typeof inventory !== 'undefined' && Array.isArray(inventory)) ? inventory : [];
    const gramsToday = inv.reduce((s, item) => s
      + (item.usageHistory || [])
        .filter((h) => h.date === dayStr)
        .reduce((a, h) => a + (+h.weightUsed || 0), 0), 0);
    const kgToday = (gramsToday / 1000).toFixed(1);

    // Honest LAN indicator — only "online" when LAN/online serving is actually enabled.
    const lanOn = !!((typeof settings !== 'undefined' && settings)
      && (settings.onlineEnabled || (settings.lanApi && settings.lanApi.bindLan)));

    const now = new Date();
    const clock = now.toLocaleTimeString(localeTag(), { hour: '2-digit', minute: '2-digit', hour12: false });

    bar.innerHTML = `
      <span class="vv-live" aria-hidden="true"></span>
      <span class="vv-sb-item"><b>${escapeHtml(String(printing))}</b> ${escapeHtml(tr('vivid.status.printing', 'printing'))}</span>
      <span class="sepr"></span>
      <span class="vv-sb-item"><b>${escapeHtml(String(openOrders))}</b> ${escapeHtml((typeof KhaytTiers === 'undefined' || KhaytTiers.showsBusiness(settings.mode)) ? tr('vivid.status.orders', 'orders') : tr('dash.pstat_jobs', 'jobs'))}</span>
      <span class="sepr"></span>
      <span class="vv-sb-item"><b>${escapeHtml(kgToday)} kg</b> ${escapeHtml(tr('vivid.status.today', 'today'))}</span>
      <span class="vv-sb-grow"></span>
      <span class="vv-sb-item ${lanOn ? 'vv-ok' : ''}">${escapeHtml(lanOn ? tr('vivid.status.synced', 'LAN online') : tr('vivid.status.lan_off', 'LAN off'))}</span>
      <span class="sepr"></span>
      <span class="vv-sb-item kbd-hint">${escapeHtml(tr('vivid.status.updated', 'Updated'))} ${escapeHtml(clock)}</span>`;
  }

  /* ---------- Lifecycle ---------- */

  function syncVividPageHead(tabId) {
    if (!isOn()) return;
    syncGroupVisibility();
    const active = tabId || document.querySelector('.tab-content.active')?.id || 'dashboard-tab';
    applyHue(active);
    relabelGroups();
    applyTiles();
    syncToolbar(active);
    syncStatusBar();
  }

  function applyVividShell() {
    document.getElementById('appSidebar')?.classList.remove('collapsed');
    const active = document.querySelector('.tab-content.active')?.id || 'dashboard-tab';
    applyHue(active);
    buildGroups();
    applyTiles();
    removeToolbar();
    ensureStatusBar();
    syncStatusBar();
  }

  function teardownVividShell() {
    restoreGroups();
    clearTiles();
    clearHue();
    removeToolbar();
    removeStatusBar();
  }

  global.KhaytVividShell = {
    applyVividShell,
    teardownVividShell,
    syncVividPageHead,
    syncGroupVisibility,
    syncStatusBar,
    GROUPS,
  };
})(typeof window !== 'undefined' ? window : globalThis);
