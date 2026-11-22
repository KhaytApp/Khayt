/**
 * Meridian shell — a time-first layout, not a restyled sidebar app.
 *
 * WHAT IS ACTUALLY DIFFERENT
 *
 * Workbench, Command and Vivid are the same shape: a persistent left nav beside
 * a scrolling content column, with the dashboard as a grid of summary cards.
 * They differ in chrome and colour. Meridian changes the shape:
 *
 *   1. THE LEFT SIDEBAR IS GONE. Not narrowed to a rail — removed. Navigation
 *      moves to a horizontal bar across the top. A schedule is read across, and
 *      a 236px column down the side is the one thing a wide time axis cannot
 *      afford.
 *   2. THE DASHBOARD IS A SCHEDULE. Machine lanes on an hour axis with a live
 *      now-line, rather than tiles summarising the same data (see screens.js).
 *   3. TIME IS PERSISTENT CHROME. The top bar carries the working date and a
 *      running clock, because every figure on this screen is relative to now.
 *
 * The nav bar is a PROXY: it forwards clicks to the real .tab-btn elements in
 * the untouched sidebar, and re-derives its own contents from them on every
 * sync. That is the same technique the Command rail uses, and it matters — tab
 * visibility depends on mode (simple/professional), feature tier and location
 * scope, and duplicating those rules here would mean two sources of truth that
 * drift. The sidebar stays in the DOM, hidden, as the single source.
 *
 * Teardown restores everything it touched: the shell must be switchable in both
 * directions from Settings without a reload.
 */
(function (global) {
  const NAV_ID = 'meridianTopbar';
  const CLOCK_ID = 'meridianClock';
  let clockTimer = null;
  let navObserver = null;
  let syncing = false;

  function isOn() { return document.body.classList.contains('khayt-meridian'); }

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  function tr(key, fallback) {
    try {
      const v = (typeof t === 'function') ? t(key) : null;
      return (v && v !== key) ? v : fallback;
    } catch (_) { return fallback; }
  }

  /* ---------------------------------------------------------------- topbar */

  function ensureTopbar() {
    const app = document.querySelector('.khayt-app');
    if (!app) return null;
    let bar = document.getElementById(NAV_ID);
    if (!bar) {
      bar = document.createElement('nav');
      bar.id = NAV_ID;
      bar.className = 'mrd-topbar';
      // aria-hidden: this is a duplicate proxy of the real nav, which stays in
      // the DOM. Exposing both would announce every destination twice.
      bar.setAttribute('aria-hidden', 'true');
      const body = app.querySelector('.khayt-body');
      if (body) app.insertBefore(bar, body); else app.appendChild(bar);
    }
    return bar;
  }

  function removeTopbar() {
    document.getElementById(NAV_ID)?.remove();
  }

  /**
   * Rebuild the proxy from the real sidebar buttons.
   * Reads: label, active state, badge, and whether the real button is visible.
   */
  function syncTopbar() {
    if (!isOn() || syncing) return;
    const bar = ensureTopbar();
    if (!bar) return;
    syncing = true;
    try { buildTopbar(bar); } finally { syncing = false; }
  }

  function buildTopbar(bar) {

    const real = [...document.querySelectorAll('#appSidebar .tab-btn')];
    const items = real
      // Same visibility rule the rest of the app uses. It only works because the
      // sidebar is clipped rather than display:none — see shell.css — otherwise
      // every button reports hidden and this list collapses to one item.
      .filter((btn) => btn.offsetParent !== null || btn.classList.contains('active'))
      .map((btn) => {
        const id = btn.dataset.tab || btn.getAttribute('data-tab') || '';
        // .nav-label is the text; .nav-icon beside it is a decorative glyph, so
        // falling back to btn.textContent would render the icon as the name.
        const label = (btn.querySelector('.nav-label')?.textContent || '').trim()
          || (btn.getAttribute('title') || '').trim()
          || (btn.dataset.tab || '').replace('-tab', '');
        const badge = (btn.querySelector('.khayt-badge, .tab-badge, .nav-badge')?.textContent || '').trim();
        return { id, label, badge, active: btn.classList.contains('active') };
      })
      .filter((x) => x.id && x.label);

    const links = items.map((x) => `
      <button type="button" class="mrd-navbtn${x.active ? ' active' : ''}" data-mrd-tab="${escHtml(x.id)}" tabindex="-1">
        <span>${escHtml(x.label)}</span>
        ${x.badge ? `<span class="mrd-navbadge">${escHtml(x.badge)}</span>` : ''}
      </button>`).join('');

    bar.innerHTML = `
      <div class="mrd-brand">
        <span class="mrd-mark" aria-hidden="true"></span>
        <span class="mrd-wordmark">${escHtml(tr('app.title', 'Khayt'))}</span>
        <span class="mrd-shellname">MERIDIAN</span>
      </div>
      <div class="mrd-navwrap">
        <button type="button" class="mrd-navscroll start" data-mrd-scroll="-1" tabindex="-1" aria-hidden="true">‹</button>
        <div class="mrd-nav" id="meridianNav">${links}</div>
        <button type="button" class="mrd-navscroll end" data-mrd-scroll="1" tabindex="-1" aria-hidden="true">›</button>
      </div>
      <div class="mrd-when">
        <span class="mrd-date" id="meridianDate"></span>
        <span class="mrd-clock" id="${CLOCK_ID}"></span>
      </div>`;

    syncClock();
    syncNavOverflow();
    scrollActiveIntoView();
  }

  /**
   * Show the scroll arrows only when the strip actually overflows, and only on
   * the side there is more to see.
   *
   * Dropping the sidebar buys the width the schedule needs and costs this: 15
   * tabs do not fit on a narrow window. Leaving them silently clipped is the
   * worst option — the strip opened scrolled to the active tab with Dashboard
   * off-screen and nothing indicating it could move.
   */
  function syncNavOverflow() {
    const nav = document.getElementById('meridianNav');
    const bar = document.getElementById(NAV_ID);
    if (!nav || !bar) return;
    const max = nav.scrollWidth - nav.clientWidth;
    const atStart = nav.scrollLeft <= 1;
    const atEnd = nav.scrollLeft >= max - 1;
    bar.querySelector('.mrd-navscroll.start')?.toggleAttribute('hidden', max <= 1 || atStart);
    bar.querySelector('.mrd-navscroll.end')?.toggleAttribute('hidden', max <= 1 || atEnd);
  }

  /** Keep the current screen's tab visible — it is the one you look for. */
  function scrollActiveIntoView() {
    const nav = document.getElementById('meridianNav');
    const active = nav?.querySelector('.mrd-navbtn.active');
    if (!nav || !active) return;
    const l = active.offsetLeft;
    const r = l + active.offsetWidth;
    if (l < nav.scrollLeft) nav.scrollLeft = Math.max(0, l - 8);
    else if (r > nav.scrollLeft + nav.clientWidth) nav.scrollLeft = r - nav.clientWidth + 8;
    syncNavOverflow();
  }

  // One delegated listener for the life of the module — forwarding a click to
  // the real button keeps every tab-switch side effect (render, badges,
  // location scope) in one place instead of reimplemented here.
  document.addEventListener('click', (e) => {
    if (!isOn()) return;

    const arrow = e.target.closest?.('[data-mrd-scroll]');
    if (arrow) {
      e.preventDefault();
      const nav = document.getElementById('meridianNav');
      if (nav) {
        nav.scrollBy({ left: Number(arrow.dataset.mrdScroll) * Math.max(160, nav.clientWidth * 0.7), behavior: 'smooth' });
        setTimeout(syncNavOverflow, 350);
      }
      return;
    }

    const btn = e.target.closest?.('[data-mrd-tab]');
    if (!btn) return;
    e.preventDefault();
    const id = btn.getAttribute('data-mrd-tab');
    const target = document.querySelector(`#appSidebar .tab-btn[data-tab="${CSS.escape(id)}"]`);
    if (target) target.click();
    else if (typeof switchTab === 'function') switchTab(id);
    syncTopbar();
  });

  // The strip can also be scrolled directly (trackpad, shift-wheel); keep the
  // arrows honest when that happens rather than only on rebuild.
  document.addEventListener('scroll', (e) => {
    if (!isOn()) return;
    if (e.target?.id === 'meridianNav') syncNavOverflow();
  }, true);

  window.addEventListener('resize', () => { if (isOn()) syncNavOverflow(); });

  /* ----------------------------------------------------------------- clock */

  function syncClock() {
    const clock = document.getElementById(CLOCK_ID);
    const date = document.getElementById('meridianDate');
    if (!clock && !date) return;
    const now = new Date();
    const two = (n) => String(n).padStart(2, '0');
    if (clock) clock.textContent = `${two(now.getHours())}:${two(now.getMinutes())}`;
    if (date) {
      try {
        date.textContent = now.toLocaleDateString(
          localeTag(),
          { weekday: 'short', day: 'numeric', month: 'short' },
        );
      } catch (_) { date.textContent = ''; }
    }
  }

  // The date reads "Mon, Jul 27" — weekday and month names, so it is
  // language-dependent in a way a bare HH:MM clock is not. Without this it
  // keeps the previous language until the next 30s tick.
  document.addEventListener('languagechange', () => { if (isOn()) syncClock(); });

  function startClock() {
    stopClock();
    // 30s is enough for a minute-resolution clock and keeps the now-line on the
    // schedule roughly honest without re-rendering the timeline every second.
    clockTimer = setInterval(() => {
      if (!isOn()) return stopClock();
      syncClock();
      global.KhaytMeridian?.tickNowLine?.();
    }, 30000);
  }

  function stopClock() {
    if (clockTimer) { clearInterval(clockTimer); clockTimer = null; }
  }

  /* ------------------------------------------------------------ apply/undo */

  /**
   * Keep the proxy in step with the real nav however the tab changed.
   *
   * Forwarding clicks is only half of it: a tab can also change from the ⌘K
   * palette, a single-key shortcut, a "View queue →" link, or any switchTab()
   * call in the app. Re-syncing only inside our own click handler left the top
   * bar highlighting Dashboard while the Settings screen was open. Watching the
   * real buttons' class attribute catches every route, including ones added
   * later, because `active` is what all of them end up toggling.
   */
  function watchTabChanges() {
    stopWatching();
    const sidebar = document.getElementById('appSidebar');
    if (!sidebar || typeof MutationObserver === 'undefined') return;
    navObserver = new MutationObserver(() => {
      if (!isOn()) return;
      syncTopbar();
    });
    navObserver.observe(sidebar, {
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'style'],
    });
  }

  function stopWatching() {
    if (navObserver) { navObserver.disconnect(); navObserver = null; }
  }

  function applyMeridianShell() {
    const sidebar = document.getElementById('appSidebar');
    if (sidebar) {
      // Hidden, not removed: it stays the source of truth the proxy reads, and
      // every existing tab handler keeps working untouched.
      sidebar.classList.remove('collapsed');
      sidebar.setAttribute('data-mrd-hidden', '1');
    }
    ensureTopbar();
    syncTopbar();
    watchTabChanges();
    startClock();
  }

  function teardownMeridianShell() {
    stopClock();
    stopWatching();
    removeTopbar();
    document.getElementById('appSidebar')?.removeAttribute('data-mrd-hidden');
  }

  global.KhaytMeridianShell = {
    applyMeridianShell,
    teardownMeridianShell,
    syncTopbar,
    syncClock,
  };
})(typeof window !== 'undefined' ? window : globalThis);
