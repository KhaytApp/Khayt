/**
 * Workbench shell — native productivity chrome around the shared renderer.
 *
 * What it does on mount:
 *  - Regroups the existing `.tab-btn` nav into Work / Catalog / Money groups
 *    (relabel + reparent the SAME buttons — navigation logic is untouched).
 *  - Paints a color tile behind each nav icon.
 *  - Builds a per-screen toolbar segment in the shared top bar.
 *  - Builds a bottom status bar fed from live order/printer counts.
 *
 * Everything is reversed on teardown: buttons return to their original
 * sections, injected chrome is removed, and inline tile colors are cleared.
 */
(function (global) {
  // Translate with graceful English fallback (follows language switches).
  const tr = (k, d) => { const s = (typeof t === 'function') ? t(k) : null; return (s && s !== k) ? s : d; };

  // Grouped layout: ordered groups of nav tabs. Tabs not listed here keep
  // their original position (e.g. dashboard stays at top, settings in footer).
  const GROUPS = [
    { key: 'work', labelKey: 'workbench.group.work', label: 'Work',
      tabs: ['calculator-tab', 'queue-tab', 'printfiles-tab', 'colorstudio-tab', 'converter-tab', 'inventory-tab', 'waste-tab'] },
    { key: 'catalog', labelKey: 'workbench.group.catalog', label: 'Catalog',
      tabs: ['catalog-tab', 'clients-tab', 'gift-cards-tab', 'portfolio-tab'] },
    { key: 'money', labelKey: 'workbench.group.money', label: 'Money',
      tabs: ['logs-tab', 'analytics-tab', 'expenses-tab'] },
  ];



  function isOn() { return document.body.classList.contains('khayt-workbench'); }

  /* ---------- Sidebar regrouping ---------- */

  // Deliberately a no-op: nav tiles are now styled entirely in shell.css, in one
  // quiet monochrome treatment with the accent reserved for the active item.
  // Kept (with clearTiles) so any --wb-tile left on a button by an older build
  // is still cleared on teardown.
  function applyTiles() {}

  function clearTiles() {
    document.querySelectorAll('.tab-btn[data-tab]').forEach((btn) => {
      btn.style.removeProperty('--wb-tile');
    });
  }

  function buildGroups() {
    const nav = document.querySelector('.khayt-nav');
    if (!nav || nav.querySelector('[data-wb-group]')) return; // already built

    // Remember each button's original parent + position so teardown can restore.
    nav.querySelectorAll('.tab-btn[data-tab]').forEach((btn) => {
      if (btn.dataset.wbHome) return;
      const sec = btn.closest('.khayt-navsec');
      if (!sec) return;
      if (!sec.id) sec.id = `wb-orig-${Math.random().toString(36).slice(2, 8)}`;
      const sibs = [...sec.children];
      btn.dataset.wbHome = sec.id;
      btn.dataset.wbHomeIdx = String(sibs.indexOf(btn));
      // Preserve simple-mode gating: a tab hidden only via its `pro-only` parent
      // section must keep that gating after it's reparented into a new group
      // (e.g. analytics-tab, whose button itself has no `pro-only` class).
      if (!btn.classList.contains('pro-only') && sec.classList.contains('pro-only')) {
        btn.classList.add('pro-only');
        btn.dataset.wbProonly = '1';
      }
    });

    GROUPS.forEach((grp) => {
      const wrap = document.createElement('div');
      wrap.className = 'khayt-navsec nav-group';
      wrap.dataset.wbGroup = grp.key;
      const head = document.createElement('div');
      head.className = 'eyebrow khayt-navhead nav-group-label';
      head.dataset.wbGroupHead = '1';
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
   * Two ways a section ends up empty, and the old check only caught one of them.
   * It asked whether the section still CONTAINED a nav button, which is right for the
   * original sections this regrouping empties out, and wrong for everything else:
   *
   *   - Bed Ready has no catalog-tab, clients-tab, logs-tab and so on at all, so the
   *     "Catalog" and "Money" groups were built, received nothing, and rendered as two
   *     headings with blank space under them.
   *   - Khayt in simple mode DOES have those buttons in the DOM, hidden by
   *     `.biz-only { display: none !important }`. Same two headings, same blank space,
   *     and a DOM-presence test can never see it.
   *
   * So the test is what is VISIBLE. Deliberately computed style rather than
   * offsetParent: this runs while the shell is being applied, before the sidebar is
   * necessarily laid out, and offsetParent would then read every button as hidden and
   * hide the whole nav. The mode gating is `display: none`, which computed style
   * reports whether or not anything has been laid out yet.
   */
  function syncGroupVisibility() {
    const nav = document.querySelector('.khayt-nav');
    if (!nav) return;
    nav.querySelectorAll('.khayt-navsec').forEach((sec) => {
      const built = !!sec.dataset.wbGroup;
      const buttons = [...sec.querySelectorAll('.tab-btn[data-tab]')];
      // A group this shell built is empty when nothing in it SHOWS. An original section
      // is empty when the regrouping took its buttons away — left on the DOM-presence
      // test it has always used, because those sections outlive this shell and a stale
      // inline style on one is a section that never comes back.
      const shows = built
        ? buttons.some((btn) => getComputedStyle(btn).display !== 'none')
        : buttons.length > 0;
      sec.classList.toggle('wb-nav-empty', !shows);
      // The class alone is not enough for the groups. Its rule lives in this theme's
      // shell.css, and Bed Ready loads the shell JS WITHOUT the theme stylesheet — which
      // is exactly where the empty groups show up, so there the class styled nothing. The
      // inline display does not care which stylesheets shipped, and it rides on a wrapper
      // this shell removes wholesale on teardown.
      if (built) sec.style.display = shows ? '' : 'none';
    });
  }

  function relabelGroups() {
    document.querySelectorAll('[data-wb-group-head]').forEach((head) => {
      const grp = GROUPS.find((g) => g.key === head.closest('[data-wb-group]')?.dataset.wbGroup);
      if (grp) head.textContent = tr(grp.labelKey, grp.label);
    });
  }

  function restoreGroups() {
    // Move each button back to its recorded home section + index.
    const buttons = [...document.querySelectorAll('.tab-btn[data-wb-home]')];
    // Restore in ascending original index so insertion lands correctly.
    buttons.sort((a, b) => Number(a.dataset.wbHomeIdx) - Number(b.dataset.wbHomeIdx));
    buttons.forEach((btn) => {
      const sec = document.getElementById(btn.dataset.wbHome);
      if (sec) {
        const idx = Number(btn.dataset.wbHomeIdx);
        const ref = sec.children[idx] || null;
        sec.insertBefore(btn, ref);
      }
      // Undo the pro-only class we added during regrouping (the button returns
      // to its original pro-only section, which gates it again).
      if (btn.dataset.wbProonly) {
        btn.classList.remove('pro-only');
        delete btn.dataset.wbProonly;
      }
      delete btn.dataset.wbHome;
      delete btn.dataset.wbHomeIdx;
    });
    document.querySelectorAll('[data-wb-group]').forEach((el) => el.remove());
    document.querySelectorAll('.khayt-navsec').forEach((sec) => {
      sec.classList.remove('wb-nav-empty');
      sec.style.removeProperty('display');
    });
  }

  /* ---------- Toolbar (per-screen segment in the shared top bar) ---------- */

  // The per-screen segment pills (Kanban/List, All/Unpaid/Paid, …) were purely
  // decorative — rendered aria-hidden/tabindex=-1 and only toggled a class, so
  // they did nothing but mislead users. Removed for accessibility; re-add here
  // wired to real view-switches if/when those land.

  function removeToolbar() {
    document.querySelector('.khayt-top .wb-toolbar')?.remove();
  }

  function syncToolbar() {
    removeToolbar();
  }

  /* ---------- Bottom status bar (live counts) ---------- */

  function ensureStatusBar() {
    const appRoot = document.querySelector('.khayt-app');
    if (!appRoot) return null;
    let bar = document.getElementById('workbenchStatusBar');
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'workbenchStatusBar';
      // NOT aria-hidden: the open-orders count moved here from the dashboard,
      // so hiding the bar hides that number from assistive tech entirely.
      bar.setAttribute('role', 'status');
      bar.setAttribute('aria-label', tr('workbench.status.aria', 'Shop status'));
      appRoot.appendChild(bar); // sits below .khayt-body in the column
    }
    return bar;
  }

  function removeStatusBar() {
    document.getElementById('workbenchStatusBar')?.remove();
  }

  function syncStatusBar() {
    const bar = document.getElementById('workbenchStatusBar');
    if (!bar || !isOn()) return;

    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const openOrders = log.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote').length;
    const printing = log.filter((o) => o.status === 'printing').length;

    // Filament used today (kg) — sum of grams on today's orders, if present.
    let gramsToday = 0;
    try {
      const today = new Date(); today.setHours(0, 0, 0, 0);
      const dayStr = (typeof localDateStr === 'function')
        ? localDateStr(today)
        : localDateStr(today);
      gramsToday = log
        .filter((o) => dayStr && (o.date || '').startsWith(dayStr))
        .reduce((s, o) => s + (Number(o.grams) || Number(o.weight) || 0), 0);
    } catch (_) { gramsToday = 0; }
    const kgToday = (gramsToday / 1000).toFixed(1);

    const now = new Date();
    const clock = now.toLocaleTimeString(localeTag(), { hour: '2-digit', minute: '2-digit', hour12: false });

    /**
     * Map the real cloud-sync state to a status-bar segment. Only a genuinely
     * healthy state gets the green tick; anything the shop should act on is
     * named plainly. Returns html:'' when sync is off — the leading dot then
     * reflects the app being up rather than a sync claim.
     */
    function syncSegment() {
      const api = window.KhaytCloudSync;
      let state = 'off';
      try { if (api && api.isOn && api.isOn()) state = String(api.status() || 'idle'); } catch (_) { state = 'error'; }
      const seg = (cls, key, dflt, tick) =>
        ({ html: `<span class="${cls}">${escapeHtml(tr(key, dflt))}${tick ? ' ✓' : ''}</span>`, state });
      switch (state) {
        case 'off':      return { html: '', dot: 'var(--wb-green)', state };
        case 'synced':
        case 'idle':     return { ...seg('wb-ok', 'workbench.status.synced', 'synced', true), dot: 'var(--wb-green)' };
        case 'syncing':  return { ...seg('wb-dim', 'workbench.status.syncing', 'syncing…', false), dot: 'var(--wb-blue)' };
        case 'offline':  return { ...seg('wb-warn', 'workbench.status.offline', 'offline', false), dot: 'var(--wb-amber)' };
        case 'locked':   return { ...seg('wb-warn', 'workbench.status.locked', 'sync locked', false), dot: 'var(--wb-amber)' };
        case 'conflict': return { ...seg('wb-warn', 'workbench.status.conflict', 'sync conflict', false), dot: 'var(--wb-amber)' };
        default:         return { ...seg('wb-bad', 'workbench.status.sync_error', 'sync error', false), dot: 'var(--wb-red)' };
      }
    }

    // Sync state is READ, not asserted. This used to be a hardcoded green
    // "synced ✓" that nothing computed — so it claimed healthy while sync was
    // failing, offline, or switched off entirely. When cloud sync is off there
    // is nothing to claim, so the segment is omitted rather than reassuring.
    const sync = syncSegment();

    bar.innerHTML = `
      <span class="wb-dot" style="background:${sync.dot}"></span>
      <span><b>${escapeHtml(String(openOrders))}</b> ${escapeHtml(tr('workbench.status.orders', 'orders'))}</span>
      <span class="sepr">·</span>
      <span><b style="color:var(--wb-blue)">${escapeHtml(String(printing))}</b> ${escapeHtml(tr('workbench.status.printing', 'printing'))}</span>
      <span class="sepr">·</span>
      <span><b>${escapeHtml(kgToday)} kg</b> ${escapeHtml(tr('workbench.status.today', 'today'))}</span>
      ${sync.html ? `<span class="sepr">·</span>${sync.html}` : ''}
      <span class="wb-sb-right">
        <span>${escapeHtml(tr('workbench.status.updated', 'Updated'))} ${escapeHtml(clock)}</span>
      </span>`;
  }

  /* ---------- Lifecycle ---------- */

  function syncWorkbenchPageHead(tabId) {
    if (!isOn()) return;
    relabelGroups();
    syncGroupVisibility();
    applyTiles();
    syncToolbar(tabId);
    syncStatusBar();
  }

  function applyWorkbenchShell() {
    document.getElementById('appSidebar')?.classList.remove('collapsed');
    buildGroups();
    applyTiles();
    removeToolbar();
    ensureStatusBar();
    syncStatusBar();
  }

  function teardownWorkbenchShell() {
    restoreGroups();
    clearTiles();
    removeToolbar();
    removeStatusBar();
  }

  global.KhaytWorkbenchShell = {
    applyWorkbenchShell,
    teardownWorkbenchShell,
    syncWorkbenchPageHead,
    syncGroupVisibility,
    syncStatusBar,
    GROUPS,
  };
})(typeof window !== 'undefined' ? window : globalThis);
