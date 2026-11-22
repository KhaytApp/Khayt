/**
 * Foreman shell — chrome for a shop you work down to zero.
 *
 * WHAT IS DIFFERENT
 *
 * Workbench, Command and Vivid are dashboards behind a sidebar. Meridian is a
 * schedule with no sidebar. Foreman is neither: its home is a DOCKET — a ranked
 * list of decisions beside a detail pane, emptied top-down (see screens.js).
 *
 * The shell exists to make that model true everywhere, not just on the home
 * screen. It adds two things no other shell has:
 *
 *   1. A PERSISTENT COUNT. A strip under the toolbar says how many things need
 *      a decision, on every screen. A dashboard you have navigated away from
 *      tells you nothing; a count that follows you is the whole point of
 *      working to zero. Click it to go back to the docket.
 *   2. KEYBOARD TRIAGE. J / K move down and up the docket, Enter opens the
 *      focused row. A list you empty is a list you should not have to point at.
 *
 * The sidebar is kept. Meridian removed it because a time axis needs the width;
 * a docket does not, and two shells removing the same thing would be one idea
 * used twice. What changes here is the model, not the furniture.
 */
(function (global) {
  const BAR_ID = 'foremanDocketBar';
  let keyHandler = null;

  function isOn() { return document.body.classList.contains('khayt-foreman'); }

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

  /* -------------------------------------------------- persistent docket bar */

  function ensureBar() {
    const top = document.querySelector('.khayt-top');
    if (!top || !top.parentElement) return null;
    let bar = document.getElementById(BAR_ID);
    if (!bar) {
      bar = document.createElement('button');
      bar.type = 'button';
      bar.id = BAR_ID;
      bar.className = 'fm-bar';
      // Sits directly under the toolbar so it is present on every screen, not
      // only the one that owns the list.
      top.parentElement.insertBefore(bar, top.nextSibling);
      bar.addEventListener('click', () => {
        if (typeof switchTab === 'function') switchTab('dashboard-tab');
      });
    }
    return bar;
  }

  function removeBar() {
    document.getElementById(BAR_ID)?.remove();
  }

  /**
   * Paint the count. Called by screens.js after it builds the docket, so the
   * bar and the list can never disagree about how many things are open — the
   * bar never counts anything itself.
   */
  function syncDocketCount(n) {
    if (!isOn()) return;
    const bar = ensureBar();
    if (!bar) return;
    const count = Number.isFinite(n) ? n : 0;
    bar.classList.toggle('zero', count === 0);
    bar.innerHTML = count === 0
      ? `<span class="fm-bar-dot"></span><span>${escHtml(tr('fm.clear_title', 'Nothing needs you'))}</span>`
      : `<span class="fm-bar-dot"></span>
         <span class="fm-bar-n">${count}</span>
         <span>${escHtml(tr('fm.bar_needs', 'need a decision'))}</span>
         <span class="fm-bar-go">${escHtml(tr('fm.bar_open', 'open docket'))} →</span>`;
  }

  /** Recount without a full dashboard render — used when another screen edits data. */
  function refreshCount() {
    if (!isOn()) return;
    try { syncDocketCount((global.KhaytForeman?.buildDocket?.() || []).length); }
    catch (_) { /* the bar is chrome; never let it break a render */ }
  }

  /* ------------------------------------------------------ keyboard triage */

  function installKeys() {
    removeKeys();
    keyHandler = (e) => {
      if (!isOn()) return;
      // Never steal a key from a field, a modal, or a shortcut chord.
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const el = document.activeElement;
      if (el && (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable)) return;
      if (document.querySelector('#modalMount .modal')) return;
      // Only while the docket is the visible screen.
      if (!document.getElementById('dashboard-tab')?.classList.contains('active')) return;

      const k = e.key.toLowerCase();
      if (k === 'j') { e.preventDefault(); global.KhaytForeman?.moveFocus?.(1); }
      else if (k === 'k') { e.preventDefault(); global.KhaytForeman?.moveFocus?.(-1); }
      else if (e.key === 'Enter') { e.preventDefault(); global.KhaytForeman?.openFocused?.(); }
    };
    document.addEventListener('keydown', keyHandler);
  }

  function removeKeys() {
    if (keyHandler) { document.removeEventListener('keydown', keyHandler); keyHandler = null; }
  }

  /* ------------------------------------------------------------ apply/undo */

  function applyForemanShell() {
    document.getElementById('appSidebar')?.classList.remove('collapsed');
    ensureBar();
    refreshCount();
    installKeys();
  }

  function teardownForemanShell() {
    removeKeys();
    removeBar();
  }

  global.KhaytForemanShell = {
    applyForemanShell,
    teardownForemanShell,
    syncDocketCount,
    refreshCount,
  };
})(typeof window !== 'undefined' ? window : globalThis);
