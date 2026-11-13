/**
 * UI shell: toasts, modals, theme, tabs, global search, help.
 */
var _escHandlerStack = [];

(function (global) {

/* ── Overflow menus close themselves ──────────────────────────────────────
 * `.ovf` is a <details>, which gets Escape and outside-click for free but has
 * no reason to shut when something inside it is pressed. Without this the menu
 * stays open over the card the click just changed, and the next render draws
 * that card underneath it.
 *
 * Bound once, here, rather than in each module's own click handler: there are
 * six surfaces using this now and every one of them would otherwise carry the
 * same three lines, which is how the six different toolbar vocabularies
 * happened in the first place.
 *
 * Capture phase, so the menu is already shut by the time the action's own
 * handler re-renders the thing it belongs to.
 */
if (typeof document !== 'undefined') {
  document.addEventListener('click', (e) => {
    const hit = e.target && e.target.closest && e.target.closest('.ovf-menu button, .ovf-menu label');
    if (!hit) return;
    const menu = hit.closest('details.ovf');
    if (menu) menu.removeAttribute('open');
  }, true);
}

const FOCUSABLE_SEL = 'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

function attachFocusTrap(root) {
  const previousFocus = document.activeElement;
  function onKeyDown(e) {
    if (e.key !== 'Tab' || !root) return;
    const focusables = [...root.querySelectorAll(FOCUSABLE_SEL)]
      .filter((el) => !el.closest('[aria-hidden="true"]') && el.offsetParent !== null);
    if (!focusables.length) return;
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (e.shiftKey) {
      if (document.activeElement === first || !root.contains(document.activeElement)) {
        e.preventDefault();
        last.focus();
      }
    } else if (document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }
  root.addEventListener('keydown', onKeyDown);
  return () => {
    root.removeEventListener('keydown', onKeyDown);
    if (previousFocus && typeof previousFocus.focus === 'function') {
      try { previousFocus.focus(); } catch (_) { /* ignore */ }
    }
  };
}

function rankSearch(items, query, getHaystack, limit) {
  const rank = global.KhaytSearch?.rankByQuery;
  if (rank) return rank(items, query, getHaystack, limit);
  const q = String(query || '').toLowerCase().trim();
  return items.filter((item) => getHaystack(item).toLowerCase().includes(q)).slice(0, limit);
}
/* ============================================================
   Toasts (now with optional undo button)
   ============================================================ */
function toast(msg, kind = 'info', ms = 2800, opts = {}) {
  const c = $('#toastContainer');
  // Cap at 6 visible toasts — remove oldest if over limit
  const existing = c.querySelectorAll('.toast');
  if (existing.length >= 6) existing[0].remove();
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  if (opts.undo) {
    const btn = document.createElement('button');
    btn.className = 'undo-btn';
    btn.textContent = t('oe.undo');
    btn.addEventListener('click', () => {
      try { opts.undo(); } catch (e) { console.error(e); }
      el.remove();
    });
    el.appendChild(btn);
  }
  // A named action other than Undo — "Review" on a warning that opens the
  // place to deal with it.
  if (opts.action && typeof opts.action.run === 'function') {
    const btn = document.createElement('button');
    btn.className = 'undo-btn';
    btn.textContent = opts.action.label || '';
    btn.addEventListener('click', () => {
      try { opts.action.run(); } catch (e) { console.error(e); }
      el.remove();
    });
    el.appendChild(btn);
  }
  c.appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; el.style.transition = 'opacity .2s'; }, ms - 250);
  setTimeout(() => el.remove(), ms);
}

/* ============================================================
   Modals (confirm + form host)
   ============================================================ */
/** Append a stacked modal overlay (does not replace an open form modal). */
function appendStackedModal(innerHtml, { zIndex = 10050 } = {}) {
  const mount = $('#modalMount');
  const overlay = document.createElement('div');
  overlay.className = 'modal-backdrop confirm-modal-overlay';
  overlay.style.zIndex = String(zIndex);
  overlay.innerHTML = innerHtml;
  mount.appendChild(overlay);
  // Accessibility: trap Tab inside the dialog, move focus into it, and restore
  // focus to the previously-focused element when the overlay is removed. Callers
  // still just remove the overlay — a MutationObserver releases the trap for them.
  const dialog = overlay.querySelector('.modal') || overlay;
  const releaseFocus = attachFocusTrap(dialog);
  const firstFocusable = dialog.querySelector(FOCUSABLE_SEL) || dialog;
  try { firstFocusable.focus(); } catch (_) { /* ignore */ }
  const obs = new MutationObserver(() => {
    if (!overlay.isConnected) { releaseFocus(); obs.disconnect(); }
  });
  obs.observe(mount, { childList: true });
  return overlay;
}

function confirmModal(message, { okText, cancelText, danger = false } = {}) {
  return new Promise(resolve => {
    const mount = $('#modalMount');
    const overlay = document.createElement('div');
    overlay.className = 'modal-backdrop confirm-modal-overlay';
    overlay.style.zIndex = '10050';
    overlay.innerHTML = `
        <div class="modal" role="dialog" aria-modal="true" aria-labelledby="confirmModalTitle">
          <h3 id="confirmModalTitle">${escapeHtml(t('common.confirm'))}</h3>
          <!-- pre-line so a message can use a blank line to separate the question
               from what the user needs to know before answering it. Runs of
               spaces still collapse, so single-line messages render unchanged. -->
          <p style="white-space:pre-line;">${escapeHtml(message)}</p>
          <div class="btn-row">
            <button class="btn ghost" data-act="cancel">${escapeHtml(cancelText || t('common.cancel'))}</button>
            <button class="btn ${danger ? 'danger' : 'primary'}" data-act="ok">${escapeHtml(okText || t('common.confirm'))}</button>
          </div>
        </div>`;
    mount.appendChild(overlay);
    const dialog = overlay.querySelector('.modal');
    const releaseFocus = attachFocusTrap(dialog || overlay);
    const cleanup = (val) => {
      document.removeEventListener('keydown', escHandler);
      const idx = _escHandlerStack.indexOf(escHandler);
      if (idx !== -1) _escHandlerStack.splice(idx, 1);
      releaseFocus();
      overlay.remove();
      resolve(val);
    };
    const escHandler = (e) => {
      if (e.key !== 'Escape') return;
      if (_escHandlerStack[_escHandlerStack.length - 1] !== escHandler) return;
      cleanup(false);
    };
    _escHandlerStack.push(escHandler);
    document.addEventListener('keydown', escHandler);
    overlay.querySelector('[data-act="ok"]').addEventListener('click', () => cleanup(true));
    overlay.querySelector('[data-act="cancel"]').addEventListener('click', () => cleanup(false));
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) cleanup(false);
    });
  });
}

/* a11y: programmatically tie visible <label>s to their control. Many field groups
   render `<div><label>…</label><input id></div>` with no for=, so screen readers
   don't announce the field's purpose. For each orphan label, if its field-group
   holds exactly one labelable control, link them (minting an id if needed).
   Conservative — skips groups with 0 or >1 controls, labels that already wrap or
   point to a control, and already-labelled controls. Idempotent: once a label
   gains for=, it drops out of the selector, so re-running after every render is
   cheap and safe. */
function wireFormLabels(root) {
  root = root || document;
  root.querySelectorAll('label:not([for])').forEach((label) => {
    if (label.querySelector('input, select, textarea')) return; // already wraps its control
    // The control is the label's next element sibling — covers both wrapped
    // groups (`<div><label/><input/></div>`) and flat rows (`<label/><input/>`).
    const ctrl = label.nextElementSibling;
    if (!ctrl || !/^(INPUT|SELECT|TEXTAREA)$/.test(ctrl.tagName) || ctrl.type === 'hidden') return;
    if (ctrl.getAttribute('aria-label') || ctrl.getAttribute('aria-labelledby')) return;
    if (!ctrl.id) ctrl.id = 'fa11y_' + (wireFormLabels._n = (wireFormLabels._n || 0) + 1);
    label.setAttribute('for', ctrl.id);
  });
  // Toolbar filter <select>s rarely have a visible <label>; their first option
  // ("All statuses", "All time", "All clients", …) names the filter dimension.
  // Use it as the accessible name so a screen reader announces the field's
  // purpose, not only its current value. Skips selects already labelled above.
  root.querySelectorAll('select:not([aria-label]):not([aria-labelledby])').forEach((sel) => {
    if (sel.id && root.querySelector(`label[for="${CSS.escape(sel.id)}"]`)) return;
    if (sel.closest('label')) return;
    const name = sel.options && sel.options[0] && sel.options[0].textContent.trim();
    if (name) sel.setAttribute('aria-label', name);
  });
}

// `onClose` fires whenever the modal goes away — the × , the footer button, the
// backdrop, Escape, or a save that succeeded. A modal that ASKS something needs
// it: without a single place that runs on the way out, "they closed it without
// answering" is a case the caller cannot see, and it is the common one.
function openFormModal({ title, bodyHtml, onMount, onSave, onClose, saveLabel, sizeLg = true, noSave = false }) {
  const mount = $('#modalMount');
  mount.innerHTML = `
    <div class="modal-backdrop">
      <div class="modal modal-form ${sizeLg ? 'modal-lg' : ''}" role="dialog" aria-modal="true" aria-labelledby="modalTitle">
        <div class="modal-header">
          <h3 id="modalTitle">${escapeHtml(title)}</h3>
          <button class="btn ghost small" data-act="cancel" aria-label="${escapeHtml(t('common.close') || 'Close')}" title="${escapeHtml(t('common.close') || 'Close')}">×</button>
        </div>
        <div class="modal-body">${bodyHtml}</div>
        <div class="modal-footer">
          ${noSave
            ? `<button class="btn ghost" data-act="cancel">${escapeHtml(t('common.close') || 'Close')}</button>`
            : `<button class="btn ghost" data-act="cancel">${escapeHtml(t('common.cancel'))}</button>
               <button class="btn primary" data-act="save">${escapeHtml(saveLabel || t('common.save'))}</button>`
          }
        </div>
      </div>
    </div>`;
  const modal = mount.querySelector('.modal');
  const releaseFocus = attachFocusTrap(modal);
  const close = () => {
    document.removeEventListener('keydown', escHandler);
    const idx = _escHandlerStack.indexOf(escHandler);
    if (idx !== -1) _escHandlerStack.splice(idx, 1);
    releaseFocus();
    mount.innerHTML = '';
    if (onClose) { try { onClose(); } catch (err) { console.error('Modal close handler:', err); } }
  };
  const escHandler = (e) => {
    if (e.key !== 'Escape') return;
    if (_escHandlerStack[_escHandlerStack.length - 1] !== escHandler) return;
    close();
  };
  _escHandlerStack.push(escHandler);
  document.addEventListener('keydown', escHandler);
  mount.querySelectorAll('[data-act="cancel"]').forEach(b => b.addEventListener('click', close));
  mount.querySelector('.modal-backdrop').addEventListener('click', (e) => {
    if (e.target.classList.contains('modal-backdrop')) close();
  });
  if (!noSave) {
    mount.querySelector('[data-act="save"]').addEventListener('click', async () => {
      try {
        const result = await onSave(modal);
        if (result !== false) close();
      } catch (err) {
        console.error('Modal save error:', err);
        toast(String(err.message || err), 'error');
      }
    });
  }
  if (onMount) onMount(modal);
  wireFormLabels(modal); // a11y: associate any orphan labels the modal rendered
  // Move focus into the first form field (skip header close button)
  const firstInput = modal.querySelector('.modal-body input, .modal-body select, .modal-body textarea, .modal-body button');
  if (firstInput) firstInput.focus();
}

/* ============================================================
   Theme
   ============================================================ */
// One-time listener: keeps the app in sync when the OS theme changes
// while the user has "System" selected — registered lazily on first use.
let _sysThemeMql = null;

function applyTheme(theme) {
  const root = document.documentElement;
  if (theme === 'system') {
    const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'dark' : 'light';
    if (!_sysThemeMql) {
      _sysThemeMql = window.matchMedia('(prefers-color-scheme: dark)');
      _sysThemeMql.addEventListener('change', e => {
        if (localStorage.getItem(K.THEME) === 'system') {
          document.documentElement.dataset.theme = e.matches ? 'dark' : 'light';
        }
      });
    }
  } else {
    root.dataset.theme = theme;
  }
  localStorage.setItem(K.THEME, theme);
}

/* ============================================================
   Business Mode
   ============================================================ */
function applyAnalyticsModeView() {
  // Enthusiast + simple both get the personal "simple reports" view; only
  // professional unlocks the full analytics dashboard.
  const simple = settings.mode !== 'professional';
  const simpleWrap = $('#analyticsSimpleWrap');
  const proWrap = $('#analyticsProWrap');
  if (simpleWrap) simpleWrap.style.display = simple ? 'block' : 'none';
  if (proWrap) proWrap.style.display = simple ? 'none' : 'block';
  if ($('#analytics-tab')?.classList.contains('active')) {
    if (simple) renderSimpleReports();
    else renderAnalytics();
  }
}

/** Business/commerce tabs hidden entirely in enthusiast (hobbyist) mode — used to
 *  bounce the active tab and to block keyboard/programmatic navigation to them. Keep
 *  in sync with the .biz-only / .pro-only nav buttons in index.html. */
const BIZ_TABS = ['logs-tab', 'clients-tab', 'gift-cards-tab', 'portfolio-tab', 'expenses-tab', 'catalog-tab', 'analytics-tab'];
/** Professional-only tabs — never reachable in Simple/Enthusiast (nav buttons are .pro-only). */
const PRO_TABS = ['expenses-tab'];

function applyMode() {
  // Bed Ready (the standalone maker app) is always the commerce-free "enthusiast"
  // experience — coerce here, the single chokepoint every caller funnels through, so
  // stored/switcher changes can never surface business UI. Detect via isBedReadyFlavor()
  // (data-app) so every flavor check in this file uses one canonical marker, not two.
  if (isBedReadyFlavor()) {
    if (settings.mode !== 'enthusiast') settings.mode = 'enthusiast';
  } else if (settings.mode === 'enthusiast') {
    // Enthusiast is retired as a Khayt-selectable mode: its maker tools (3MF converter,
    // Colour Studio, print-file library) are now core features of Simple/Professional.
    // Migrate any existing Khayt enthusiast user to Simple (persists on next save). The
    // mode still exists internally — Bed Ready uses it above as its commerce-free pin.
    settings.mode = 'simple';
  }
  document.body.classList.toggle('mode-simple', settings.mode === 'simple');
  document.body.classList.toggle('mode-professional', settings.mode === 'professional');
  document.body.classList.toggle('mode-enthusiast', settings.mode === 'enthusiast');
  // The mode classes above are what hide the business nav buttons, so the grouped
  // themes have to re-decide which of their group HEADINGS still has anything under
  // it. Without this, switching mode leaves "Catalog" and "Money" standing over blank
  // space until the next tab switch happens to refresh them.
  KhaytWorkbenchShell?.syncGroupVisibility?.();
  KhaytCommandShell?.syncGroupVisibility?.();
  KhaytVividShell?.syncGroupVisibility?.();
  const btnSimple = $('#btnModeSimple');
  const btnPro    = $('#btnModePro');
  const btnEnth   = $('#btnModeEnthusiast');
  if (btnSimple) btnSimple.classList.toggle('active', settings.mode === 'simple');
  if (btnPro)    btnPro.classList.toggle('active',    settings.mode === 'professional');
  if (btnEnth)   btnEnth.classList.toggle('active',   settings.mode === 'enthusiast');
  // If the active tab is a business surface and we've entered enthusiast mode,
  // bounce to the dashboard so the user isn't stranded on a now-hidden tab.
  if (settings.mode === 'enthusiast' && BIZ_TABS.includes($('.tab-content.active')?.id)) {
    if (typeof switchTab === 'function') switchTab('dashboard-tab');
  }
  // A Professional tab or Settings pane on screen when the mode changes: in
  // Simple it becomes the "Part of Professional" panel, and back in
  // Professional the panel becomes the screen the shop asked for.
  const activeTab = $('.tab-content.active');
  if (activeTab && activeTab.id !== 'settings-tab' && typeof switchTab === 'function') {
    const gated = activeTab.classList.contains('sm-gated');
    const gateNow = !!window.KhaytSimpleMode?.tabGate?.(activeTab.id, settings.mode);
    if (gated !== gateNow) switchTab(activeTab.id);
  }
  if (activeTab?.id === 'settings-tab' && _settingsSectionAsked) {
    const showingGate = !!$('#settings-panel-gated.active');
    if (showingGate !== settingsPaneGated(_settingsSectionAsked)) openSettingsSection(_settingsSectionAsked);
  }
  renderModeBadge();
  renderModeTierCompare();
  applyAnalyticsModeView();
  if (typeof renderDashboard === 'function') renderDashboard();
  if (typeof renderOnlineSettings === 'function') renderOnlineSettings();
}

/** S4 card 1: a steel "Simple" pill beside the name in the sidebar head
 *  while the shop is in Simple. Nothing in Professional, nor in Bed Ready
 *  (enthusiast), whose sidebar has no modes to name. */
function renderModeBadge() {
  const head = $('.khayt-brand');
  if (!head) return;
  let pill = head.querySelector('.sm-mode-badge');
  if (settings.mode !== 'simple') { pill?.remove(); return; }
  if (!pill) {
    pill = document.createElement('span');
    pill.className = 'sm-mode-badge';
    pill.id = 'modeBadge';
    pill.setAttribute('data-i18n', 'set.mode_simple');
    head.appendChild(pill);
  }
  pill.textContent = t('set.mode_simple');
}

/** Render the Simple-vs-Professional tier comparison from the canonical registry
 *  (lib/feature-tiers.js), highlighting the active tier. Makes the boundary clear. */
function renderModeTierCompare() {
  const el = $('#modeTierCompare');
  if (!el || typeof KhaytTiers === 'undefined') return;
  const lang = (typeof i18n !== 'undefined' && i18n.current) || 'en';
  const cmp = KhaytTiers.tierComparison(lang);
  const mode = settings.mode || 'professional';
  const check = '<svg aria-hidden="true" viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px;"><path d="M20 6 9 17l-5-5"/></svg>';
  const col = (title, rows, active, accent) => `
    <div style="flex:1;min-width:170px;border:1px solid ${active ? accent : 'var(--border-soft)'};border-radius:10px;padding:12px 14px;${active ? 'box-shadow:0 0 0 1px ' + accent + ';' : 'opacity:.85;'}">
      <div style="font-weight:700;font-size:13px;margin-bottom:8px;display:flex;align-items:center;gap:6px;">${escapeHtml(title)}${active ? `<span style="font-size:10px;color:${accent};border:1px solid ${accent};border-radius:999px;padding:1px 7px;">${escapeHtml(t('set.mode_current') || 'current')}</span>` : ''}</div>
      ${rows.map((r) => `<div style="font-size:12px;color:var(--text-muted);padding:2px 0;display:flex;gap:6px;align-items:flex-start;"><span style="color:${accent};flex-shrink:0;">${check}</span>${escapeHtml(r.label)}</div>`).join('')}
    </div>`;
  // Enthusiast is retired as a Khayt mode, so the comparison is Simple vs Professional.
  // Simple's column folds in the former enthusiast (maker-core) features so it reads as a
  // complete list, not "everything in Enthusiast, plus". (Bed Ready hides this card.)
  el.innerHTML = `
    <div style="display:flex;gap:10px;flex-wrap:wrap;">
      ${col(t('set.mode_simple') || 'Simple', [...cmp.enthusiast, ...cmp.simple], mode === 'simple', 'var(--info,#5b9cf0)')}
      ${col((t('set.mode_pro') || 'Professional') + ' — ' + (t('set.mode_pro_adds') || 'everything in Simple, plus'), cmp.pro, mode === 'professional', 'var(--primary,#6366f1)')}
    </div>`;
}


/* ============================================================
   Khayt Studio shell
   ============================================================ */
function initAppShell() {
  const sidebar = $('#appSidebar');
  const collapseBtn = $('#btnSidebarCollapse');
  if (localStorage.getItem('hub_sidebar_collapsed') === '1') {
    sidebar?.classList.add('collapsed');
    collapseBtn?.setAttribute('aria-expanded', 'false');
  }
  collapseBtn?.addEventListener('click', () => {
    sidebar?.classList.toggle('collapsed');
    const collapsed = sidebar?.classList.contains('collapsed');
    localStorage.setItem('hub_sidebar_collapsed', collapsed ? '1' : '0');
    collapseBtn.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
    const chevron = collapseBtn.querySelector('[aria-hidden="true"]');
    if (chevron) { chevron.textContent = collapsed ? '›' : '‹'; chevron.classList.add('dir-glyph-inline'); }
  });

  const mirror = $('#topbarSearchMirror');
  const searchBtn = $('#btnGlobalSearch');
  const openSearch = () => searchBtn?.click();
  mirror?.addEventListener('click', openSearch);
  mirror?.addEventListener('focus', openSearch);

  if (typeof applyDesignSettings === 'function') applyDesignSettings();
  else if (typeof populateDesignSelects === 'function') populateDesignSelects();

  syncTopbarTitle($('.tab-content.active')?.id || 'dashboard-tab');

  window.KhaytBedReadyUI?.init?.();

  const nav = $('.khayt-nav[role="tablist"]');
  nav?.addEventListener('keydown', (e) => {
    const tabs = [...nav.querySelectorAll('.tab-btn[role="tab"]')]
      .filter((btn) => btn.offsetParent !== null && !btn.disabled);
    if (!tabs.length) return;
    const idx = tabs.findIndex((btn) => btn.getAttribute('aria-selected') === 'true');
    if (idx < 0) return;
    let next = idx;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
      e.preventDefault();
      next = (idx + 1) % tabs.length;
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
      e.preventDefault();
      next = (idx - 1 + tabs.length) % tabs.length;
    } else if (e.key === 'Home') {
      e.preventDefault();
      next = 0;
    } else if (e.key === 'End') {
      e.preventDefault();
      next = tabs.length - 1;
    } else {
      return;
    }
    tabs[next].focus();
    switchTab(tabs[next].dataset.tab);
  });

  $('.kanban')?.classList.add('khayt-kanban');
  $$('.kanban-col').forEach(col => {
    col.classList.add('khayt-kcol');
    col.querySelector('[id^="list-"]')?.classList.add('khayt-kcol-body');
    const head = col.querySelector('h3');
    if (head && !head.parentElement.classList.contains('khayt-kcol-head')) {
      const wrap = document.createElement('div');
      wrap.className = 'khayt-kcol-head';
      head.parentNode.insertBefore(wrap, head);
      wrap.appendChild(head);
      const meta = col.querySelector('.kanban-col-meta');
      if (meta) wrap.appendChild(meta);
    }
  });
}

function syncTopbarTitle(tabId) {
  const activeBtn = $(`.tab-btn[data-tab="${tabId}"]`);
  const titleKey = activeBtn?.querySelector('[data-i18n]')?.getAttribute('data-i18n');
  const topTitle = $('#topbarPageTitle');
  if (topTitle && titleKey) topTitle.textContent = t(titleKey);
  const sub = $('#topbarPageSubtitle');
  if (!sub) return;
  if (tabId === 'dashboard-tab') {
    const d = new Date();
    sub.textContent = d.toLocaleDateString(localeTag(), {
      weekday: 'long', day: 'numeric', month: 'long', year: 'numeric'
    });
  } else {
    sub.textContent = '';
  }
  // Bed Ready reframes the subtitle as an ISO title-block field row (no-op elsewhere).
  if (typeof window.brSyncTitleBlock === 'function') window.brSyncTitleBlock(tabId);
}


/* ============================================================
   Tabs
   ============================================================ */
/** Settings panes that are business-only (hidden/redirected in enthusiast mode). */
const BIZ_SETTINGS_SECTIONS = ['invoices', 'store', 'connections'];

/** The 11 sections before the 14 panes (Nov 2026), and the pane each one's
 *  cards mostly moved to, so a deep link, a button or a script that still
 *  names an old section lands somewhere sensible. Only used when no panel by
 *  that id exists: Bed Ready keeps the old sections and opens them as-is. */
const SETTINGS_SECTION_ALIASES = {
  biz: 'shop', prefs: 'general', stock: 'production', invoice: 'invoices',
  payments: 'invoices', online: 'cloud', ops: 'pricing', automation: 'notify',
  access: 'team', data: 'advanced',
};

function resolveSettingsSection(section) {
  if (!section || document.getElementById('settings-panel-' + section)) return section;
  return SETTINGS_SECTION_ALIASES[section] || section;
}

/** A nav button's own words (its translated label, without the icon or the
 *  PRO tag beside it). */
function navLabel(btn, fallback) {
  const key = btn?.querySelector('[data-i18n]')?.getAttribute('data-i18n');
  return key ? t(key) : ((btn?.textContent || '').trim() || fallback);
}

/** The pane last asked for, so a mode switch can re-open it (see applyMode). */
let _settingsSectionAsked = null;

/** Is this settings pane hidden by the shop's mode? Its nav button says so:
 *  `.pro-only` is hidden in Simple (and enthusiast), `.biz-only` in enthusiast.
 *  The same classes are what hide the button, so the two cannot disagree. */
function settingsSectionGated(section) {
  const nav = document.querySelector(`.settings-nav-item[data-settings-section="${section}"]`);
  if (!nav) return false;
  const mode = settings.mode || 'professional';
  if (nav.classList.contains('pro-only') && mode !== 'professional') return true;
  if (nav.classList.contains('biz-only') && mode === 'enthusiast') return true;
  return false;
}

/** Does Simple show this pane as "Part of Professional"? SIMPLE_MAP decides
 *  (KhaytSimpleMode.paneGate); a pane whose nav button is .pro-only is gated
 *  too, so a pane the map does not name is never left empty. */
function settingsPaneGated(section) {
  if (settings.mode !== 'simple') return false;
  return !!window.KhaytSimpleMode?.paneGate?.(section, settings.mode) || settingsSectionGated(section);
}

/** The "Part of Professional" pane, made on first use. */
function settingsGatePanel() {
  let panel = document.getElementById('settings-panel-gated');
  if (!panel) {
    panel = document.createElement('div');
    panel.className = 'settings-panel sm-gate';
    panel.id = 'settings-panel-gated';
    $('.settings-panels')?.appendChild(panel);
  }
  return panel;
}

function openSettingsSection(section) {
  section = resolveSettingsSection(section);
  _settingsSectionAsked = section;
  const firstPane = () => resolveSettingsSection(document.getElementById('settings-panel-general') ? 'general' : 'prefs');
  // Enthusiast (hobbyist) mode has no commerce — bounce business panes, and
  // the Professional ones it hides, to the first pane (General; Preferences in
  // Bed Ready).
  if (settings.mode === 'enthusiast' && (BIZ_SETTINGS_SECTIONS.includes(section) || ['invoice', 'payments', 'online'].includes(section) || settingsSectionGated(section))) {
    section = firstPane();
  }
  // A Professional pane reached in Simple (a link, search, a button elsewhere,
  // or switching to Simple while on it) says so, with a switch — never an
  // empty page.
  const gated = settingsPaneGated(section);
  switchTab('settings-tab');
  $$('.settings-nav-item').forEach(el => {
    el.classList.remove('active');
    el.removeAttribute('aria-current');
  });
  $$('.settings-panel').forEach(el => el.classList.remove('active'));
  if (gated) {
    const feature = navLabel($(`.settings-nav-item[data-settings-section="${section}"]`), section);
    const panel = settingsGatePanel();
    if (window.KhaytSimpleMode) window.KhaytSimpleMode.renderGated(panel, feature, window.KhaytSimpleMode.paneGate(section, settings.mode));
    else { openSettingsSection(firstPane()); return; }
    panel.classList.add('active');
    panel.scrollTop = 0;
    return;
  }
  const navItem = $(`.settings-nav-item[data-settings-section="${section}"]`);
  navItem?.classList.add('active');
  navItem?.setAttribute('aria-current', 'page');
  navItem?.scrollIntoView({ inline: 'nearest', block: 'nearest' });
  const panel = $(`#settings-panel-${section}`);
  if (panel) {
    panel.classList.add('active');
    panel.scrollTop = 0;
  }
  // The intake form and LAN cards it fills sit in Online Store and Connections now.
  if (['online', 'store', 'connections'].includes(section) && typeof renderOnlineSettings === 'function') renderOnlineSettings();
}

function switchTab(tabId) {
  // Enthusiast (hobbyist) mode hides all business tabs — redirect if one is reached
  // via deep-link / global search / keyboard so the user never lands on a hidden tab.
  if (settings.mode === 'enthusiast' && BIZ_TABS.includes(tabId)) tabId = 'dashboard-tab';
  // A Professional tab reached in Simple (search, a link, a shortcut, a menu)
  // opens as the "Part of Professional" panel with a switch (SIMPLE_MAP, via
  // KhaytSimpleMode). Where that is not loaded, and in enthusiast, it bounces
  // to the dashboard as before.
  const tabGate = window.KhaytSimpleMode?.tabGate?.(tabId, settings.mode) || null;
  const isPro = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.isProMode(settings.mode) : (settings.mode || 'professional') === 'professional';
  if (!tabGate && !isPro && PRO_TABS.includes(tabId)) tabId = 'dashboard-tab';
  // A real change of view opens the new view at its top: the views share one
  // scroller (#mainContent), so without this the Calculator, Logs or Expenses
  // opened wherever the previous view had been scrolled to. Re-showing the
  // same tab (a re-render) keeps the place.
  const prevTab = document.querySelector('.tab-content.active')?.id;
  if (prevTab !== tabId) {
    const scroller = document.getElementById('mainContent');
    if (scroller) scroller.scrollTop = 0;
  }
  $$('.tab-content.sm-gated').forEach((el) => { if (el.id !== tabId || !tabGate) el.classList.remove('sm-gated'); });
  if (tabGate) {
    const host = document.getElementById(tabId);
    if (host) {
      let gate = host.querySelector(':scope > .sm-gate');
      if (!gate) {
        gate = document.createElement('div');
        gate.className = 'sm-gate';
        host.prepend(gate);
      }
      window.KhaytSimpleMode.renderGated(gate, navLabel($(`.tab-btn[data-tab="${tabId}"]`), tabId), tabGate);
      host.classList.add('sm-gated');
    }
  }
  $$('.tab-content').forEach(el => {
    const on = el.id === tabId;
    el.classList.toggle('active', on);
    el.setAttribute('aria-hidden', on ? 'false' : 'true');
  });
  $$('.tab-btn').forEach(btn => {
    const on = btn.dataset.tab === tabId;
    btn.classList.toggle('active', on);
    btn.setAttribute('aria-selected', on ? 'true' : 'false');
    btn.setAttribute('tabindex', on ? '0' : '-1');
  });

  $$('.tab-btn.khayt-navitem').forEach(btn => {
    btn.classList.toggle('on', btn.dataset.tab === tabId);
    btn.setAttribute('aria-current', btn.dataset.tab === tabId ? 'page' : 'false');
  });

  syncTopbarTitle(tabId);
  if (typeof KhaytWorkbenchShell?.syncWorkbenchPageHead === 'function') {
    KhaytWorkbenchShell.syncWorkbenchPageHead(tabId);
  }
  if (typeof KhaytCommandShell?.syncCommandPageHead === 'function') {
    KhaytCommandShell.syncCommandPageHead(tabId);
  }
  if (typeof KhaytVividShell?.syncVividPageHead === 'function') {
    KhaytVividShell.syncVividPageHead(tabId);
  }
  // The panel stands in for the screen: do not draw what it hides.
  if (tabGate) return;

  if (tabId === 'dashboard-tab')  renderDashboard();
  if (tabId === 'expenses-tab')   { renderExpenses(); populateExpOrderDatalist(); }
  if (tabId === 'catalog-tab')    renderCatalog();
  if (tabId === 'printfiles-tab') {
    renderPrintFiles();
    /* Move any thumbnails still living in the store into their records' vault
     * folders — a slice at a time, on proof, never deleting the copy it has
     * until the copy it wrote reads back. See migrateThumbsToDisk().
     *
     * Here rather than at boot because it is only worth doing where the pictures
     * are actually used, and because a shop that never opens this tab should not
     * pay for it on every launch. */
    try { window.KhaytPrintFiles?.migrateThumbsToDisk?.(); } catch (_) {}
  }
  if (tabId === 'colorstudio-tab') renderColorStudio();
  if (tabId === 'converter-tab')  renderConverter();
  if (tabId === 'hueforge-tab' && typeof renderHueForge === 'function') renderHueForge();
  if (tabId === 'clients-tab')    renderClients();
  if (tabId === 'calculator-tab')  window.KhaytBedReadyUI?.initStudioCalculatorLayout?.();
  if (tabId === 'queue-tab')      { renderMachineQueues(); renderKanban(); }
  if (tabId === 'analytics-tab')  applyAnalyticsModeView();
  if (tabId === 'gift-cards-tab') renderGiftCards();
  if (tabId === 'logs-tab')       renderLogs();
  if (tabId === 'portfolio-tab')  renderPortfolio();
  if (tabId === 'waste-tab')      renderWasteLog();
  if (tabId === 'inventory-tab')  { renderInventory(); renderPurchaseOrders(); renderConsumables(); renderSuppliers(); }
  if (tabId === 'settings-tab') {
    // Activate the first sidebar nav item if none is active
    const activePanel = $('.settings-panel.active');
    if (!activePanel) {
      const firstNav = $('.settings-nav-item[data-settings-section]');
      if (firstNav) {
        const section = firstNav.dataset.settingsSection;
        firstNav.classList.add('active');
        firstNav.setAttribute('aria-current', 'page');
        $(`#settings-panel-${section}`)?.classList.add('active');
      }
    }
  }
  wireFormLabels(); // a11y: link any labels the just-rendered tab surfaced
}
/* ============================================================
   Global ⌘K / Ctrl+K search
   ============================================================ */
let globalSearchOpen = false;
let gsFocusedIndex = -1;

function openGlobalSearch() {
  const overlay = $('#globalSearchOverlay');
  const input   = $('#globalSearchInput');
  if (!overlay) return;
  globalSearchOpen = true;
  gsFocusedIndex = -1;
  overlay.style.display = 'flex';
  input.value = '';
  input.focus();
  renderGlobalResults('');
}

function closeGlobalSearch() {
  const overlay = $('#globalSearchOverlay');
  if (!overlay) return;
  globalSearchOpen = false;
  gsFocusedIndex = -1;
  overlay.style.display = 'none';
}

function updateGsFocus(results) {
  results.forEach((row, i) => row.classList.toggle('focused', i === gsFocusedIndex));
  if (gsFocusedIndex >= 0 && results[gsFocusedIndex]) {
    results[gsFocusedIndex].scrollIntoView({ block: 'nearest' });
  }
}

function handleGlobalSearchKeydown(e) {
  if (!globalSearchOpen) return false;
  const results = [...($('#globalSearchResults')?.querySelectorAll('.gs-result') || [])];
  if (e.key === 'ArrowDown') {
    e.preventDefault();
    gsFocusedIndex = results.length ? (gsFocusedIndex + 1) % results.length : -1;
    updateGsFocus(results);
    return true;
  }
  if (e.key === 'ArrowUp') {
    e.preventDefault();
    gsFocusedIndex = results.length
      ? (gsFocusedIndex <= 0 ? results.length - 1 : gsFocusedIndex - 1)
      : -1;
    updateGsFocus(results);
    return true;
  }
  if (e.key === 'Enter' && gsFocusedIndex >= 0 && results[gsFocusedIndex]) {
    e.preventDefault();
    results[gsFocusedIndex].click();
    return true;
  }
  return false;
}

function renderGlobalResults(term) {
  const el = $('#globalSearchResults');
  if (!el) return;
  gsFocusedIndex = -1;
  if (!term.trim()) {
    el.innerHTML = `<div class="gs-hint">${escapeHtml(t('search.hint'))}</div>`;
    return;
  }
  const sections = [];
  // Respect mode gating: enthusiast sees no commerce entities; simple sees business but not Pro-only ones.
  const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
  const pro = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.isProMode(settings.mode) : (settings.mode || 'professional') === 'professional';

  const orderHaystack = (o) => {
    const client = o.clientId ? clients.find((x) => x.id === o.clientId) : null;
    return [
      o.id, o.project, o.material, o.notes, o.trackingNumber,
      ...(o.tags || []),
      client?.nameEn, client?.nameAr,
    ].filter(Boolean).join(' ');
  };

  const matchOrders = biz ? rankSearch(printLog, term, orderHaystack, 6) : [];
  if (matchOrders.length) {
    sections.push(`<div class="gs-group-label">${escapeHtml(t('search.orders'))}</div>`);
    sections.push(matchOrders.map(o => `
      <div class="gs-result" data-gs-action="order" data-gs-id="${escapeHtml(o.id)}">
        <span class="gs-icon">📋</span>
        <span class="gs-title">${escapeHtml(o.project || jobRef(o))}</span>
        <span class="gs-meta">${escapeHtml(jobRef(o))} · ${fmtOrderPrice(o.price, o)} · <span class="badge ${escapeHtml(o.status)}">${escapeHtml(t('queue.' + o.status))}</span></span>
      </div>`).join(''));
  }

  const matchClients = biz ? rankSearch(
    clients,
    term,
    (c) => [c.id, c.nameEn, c.nameAr, c.phone, c.email].filter(Boolean).join(' '),
    4,
  ) : [];
  if (matchClients.length) {
    sections.push(`<div class="gs-group-label">${escapeHtml(t('search.clients'))}</div>`);
    sections.push(matchClients.map(c => `
      <div class="gs-result" data-gs-action="client" data-gs-id="${escapeHtml(c.id)}">
        <span class="gs-icon">👤</span>
        <span class="gs-title">${escapeHtml(localName(c))}</span>
        <span class="gs-meta">${escapeHtml(c.phone || c.email || '')}</span>
      </div>`).join(''));
  }

  const matchProducts = biz ? rankSearch(
    products,
    term,
    (p) => [p.nameEn, p.nameAr, p.description].filter(Boolean).join(' '),
    4,
  ) : [];
  if (matchProducts.length) {
    sections.push(`<div class="gs-group-label">${escapeHtml(t('search.products'))}</div>`);
    sections.push(matchProducts.map(p => `
      <div class="gs-result" data-gs-action="product" data-gs-id="${escapeHtml(p.id)}">
        <span class="gs-icon">📦</span>
        <span class="gs-title">${escapeHtml(localName(p))}</span>
        <span class="gs-meta">${fmtPrice(p.price != null ? p.price : (p.basePrice || 0))}</span>
      </div>`).join(''));
  }

  const matchInv = rankSearch(
    inventory,
    term,
    (i) => [i.material, i.brand, i.colour, i.id].filter(Boolean).join(' '),
    4,
  );

  const matchMachines = rankSearch(
    machines,
    term,
    (m) => [m.name, m.model, m.location, ...(m.compatMaterials || [])].filter(Boolean).join(' '),
    3,
  );
  if (matchMachines.length) {
    sections.push(`<div class="gs-group-label">${escapeHtml(t('search.machines'))}</div>`);
    sections.push(matchMachines.map((m) => `
      <div class="gs-result" data-gs-action="machine" data-gs-id="${escapeHtml(m.id)}">
        <span class="gs-icon">🖨️</span>
        <span class="gs-title">${escapeHtml(m.name)}</span>
        <span class="gs-meta">${escapeHtml(m.model || t('mach.unassigned'))}</span>
      </div>`).join(''));
  }

  const matchSuppliers = pro ? rankSearch(
    suppliers,
    term,
    (s) => [s.name, s.phone, s.email, s.website].filter(Boolean).join(' '),
    3,
  ) : [];
  if (matchSuppliers.length) {
    sections.push(`<div class="gs-group-label">${escapeHtml(t('search.suppliers'))}</div>`);
    sections.push(matchSuppliers.map((s) => `
      <div class="gs-result" data-gs-action="supplier" data-gs-id="${escapeHtml(s.id)}">
        <span class="gs-icon">🏭</span>
        <span class="gs-title">${escapeHtml(s.name)}</span>
        <span class="gs-meta">${escapeHtml(s.phone || s.email || '')}</span>
      </div>`).join(''));
  }

  const matchExpenses = pro ? rankSearch(
    expenses,
    term,
    (e) => [e.note, e.category, e.vendor, e.orderId].filter(Boolean).join(' '),
    3,
  ) : [];
  if (matchExpenses.length) {
    sections.push(`<div class="gs-group-label">${escapeHtml(t('search.expenses'))}</div>`);
    sections.push(matchExpenses.map((e) => `
      <div class="gs-result" data-gs-action="expense" data-gs-id="${escapeHtml(e.id)}">
        <span class="gs-icon">◧</span>
        <span class="gs-title">${escapeHtml(e.note || (typeof expCatLabel === 'function' ? expCatLabel(e.category) : e.category) || 'Expense')}</span>
        <span class="gs-meta">${escapeHtml(e.date || '')} · ${fmtPrice(e.amount)}</span>
      </div>`).join(''));
  }
  if (matchInv.length) {
    sections.push(`<div class="gs-group-label">${escapeHtml(t('search.inventory'))}</div>`);
    sections.push(matchInv.map(i => `
      <div class="gs-result" data-gs-action="inventory" data-gs-id="${escapeHtml(i.id)}">
        <span class="gs-icon">🧵</span>
        <span class="gs-title">${escapeHtml(i.material)}</span>
        <span class="gs-meta">${Math.round(i.weight)}g · ${fmtPrice(i.cost)}</span>
      </div>`).join(''));
  }

  el.innerHTML = sections.length ? sections.join('') : `<div class="gs-hint">${escapeHtml(t('search.no_results'))}</div>`;

  el.querySelectorAll('.gs-result').forEach(row => {
    row.addEventListener('click', () => {
      const action = row.dataset.gsAction;
      const id     = row.dataset.gsId;
      closeGlobalSearch();
      if (action === 'order')     { switchTab('logs-tab');       setTimeout(() => { logSearchTerm = id; renderLogs(); }, 50); }
      if (action === 'client')    { switchTab('clients-tab');    setTimeout(() => { clientSearchTerm = id; renderClients(); }, 50); }
      if (action === 'product') {
        switchTab('catalog-tab');
        catalogSearchTerm = '';
        const catInput = $('#catalogSearch');
        if (catInput) catInput.value = '';
        setTimeout(() => {
          renderCatalog();
          const card = document.querySelector(`.product-card[data-id="${CSS.escape(id)}"]`);
          if (card) {
            card.scrollIntoView({ behavior: 'smooth', block: 'center' });
            card.classList.add('highlight-flash');
            setTimeout(() => card.classList.remove('highlight-flash'), 1500);
          }
        }, 80);
      }
      if (action === 'inventory') {
        switchTab('inventory-tab');
        if (id) setTimeout(() => {
          const row = document.querySelector(`[data-inv-id="${CSS.escape(id)}"]`);
          if (row) { row.scrollIntoView({ behavior: 'smooth', block: 'center' }); row.classList.add('highlight-flash'); setTimeout(() => row.classList.remove('highlight-flash'), 1500); }
        }, 80);
      }
      if (action === 'machine') {
        openSettingsSection('printers');
        setTimeout(() => {
          renderMachines();
          const row = document.querySelector(`[data-machine-id="${CSS.escape(id)}"]`);
          if (row) {
            row.scrollIntoView({ behavior: 'smooth', block: 'center' });
            row.classList.add('highlight-flash');
            setTimeout(() => row.classList.remove('highlight-flash'), 1500);
          }
        }, 80);
      }
      if (action === 'supplier') {
        switchTab('inventory-tab');
        setTimeout(() => {
          renderSuppliers();
          const row = document.querySelector(`[data-supplier-id="${CSS.escape(id)}"]`);
          if (row) {
            row.scrollIntoView({ behavior: 'smooth', block: 'center' });
            row.classList.add('highlight-flash');
            setTimeout(() => row.classList.remove('highlight-flash'), 1500);
          }
        }, 80);
      }
      if (action === 'expense') {
        switchTab('expenses-tab');
        setTimeout(() => {
          renderExpenses();
          const row = document.querySelector(`[data-expense-id="${CSS.escape(id)}"]`);
          if (row) {
            row.scrollIntoView({ behavior: 'smooth', block: 'center' });
            row.classList.add('highlight-flash');
            setTimeout(() => row.classList.remove('highlight-flash'), 1500);
          }
        }, 80);
      }
    });
  });
}

/* ============================================================
   In-app help system (Feature 9)
   ============================================================ */
function isBedReadyFlavor() {
  try { return document.documentElement.dataset.app === 'bedready'; } catch (_) { return false; }
}

// Bed Ready's own help + FAQ (maker-focused). English-first for the public beta.
function openBedReadyHelp(initial) {
  const SECTIONS = [
    { id: 'start', label: 'Getting started', html: `
      <div class="help-section">
        <h4>What is Bed Ready?</h4>
        <p>Bed Ready is a desktop workbench for solo 3D-printing makers. It helps you keep your print files organised, preview them in 3D, retarget a model to a different printer, cost a print, and track filament — all offline on your own computer. It does <b>not</b> slice or print by itself; it works alongside your existing slicer (OrcaSlicer, PrusaSlicer, Bambu Studio, Snapmaker Orca, and more).</p>
        <h4>The typical workflow</h4>
        <ul>
          <li><b>Add a print file</b> (a <code>.3mf</code> or <code>.stl</code>) to your library.</li>
          <li><b>Preview</b> it in 3D — check the plates and colours.</li>
          <li><b>Convert / retarget</b> it to the printer you actually own, if it was made for a different one.</li>
          <li><b>Open it in your slicer</b> to slice and print. Bed Ready can launch your slicer for you.</li>
        </ul>
        <h4>The full maker toolset</h4>
        <p>Bed Ready shows the complete maker toolset — library, 3D preview, converter, inventory, costing, and a print queue — all in one place. Use what you need; ignore the rest.</p>
      </div>` },
    { id: 'convert', label: '3MF Converter', html: `
      <div class="help-section">
        <h4>Retarget a model to your printer</h4>
        <p>Open a <code>.3mf</code> from your library and choose <b>Convert</b>. Pick your printer as the target and Bed Ready rewrites the file’s printer + print settings to match, keeps the geometry and colours, and saves a new <code>.3mf</code>.</p>
        <h4>Target (almost) any printer</h4>
        <p>The target list includes a built-in set <i>plus every printer in your installed OrcaSlicer / Snapmaker Orca profile library</i> (~1,000+ models, grouped by vendor). Picking one builds a file using that printer’s own machine profile and a matching print-quality preset, so it opens cleanly.</p>
        <h4>Colours &amp; slots</h4>
        <p>If a model uses more colours than your printer has slots, you can map colours to slots — or use <b>Full Spectrum</b> (see the next tab) on a Snapmaker U1.</p>
        <p class="help-warn">⚠ Always open the converted file in your slicer and check it before printing. Conversion rewrites settings automatically and can’t account for every printer quirk — you are responsible for verifying the result.</p>
      </div>` },
    { id: 'spectrum', label: 'Full Spectrum', html: `
      <div class="help-section">
        <h4>Reproduce extra colours by mixing</h4>
        <p>When a file has more colours than a Snapmaker U1’s four slots, <b>Full Spectrum</b> keeps four filaments physical and reproduces the rest as dithered mixes of those four. The converter shows which four to load and the recipe for each extra colour (e.g. “65% White + 35% Red”).</p>
        <h4>How good is a mix?</h4>
        <p>Each mix shows a <b>ΔE</b> — the perceptual colour difference from the original (lower is closer). A pure colour a mix can’t fake stays a physical filament; only the “mixable” colours are virtualised.</p>
        <p class="help-muted">The pigment-mixing model approximates Snapmaker Orca’s own Full-Spectrum matching, so a mix should print close to what Bed Ready previews. Test prints are still the final word.</p>
      </div>` },
    { id: 'slicers', label: 'Slicers &amp; printers', html: `
      <div class="help-section">
        <h4>Connect your slicer</h4>
        <p>Open <b>Settings → Slicer integration</b> and click <b>Detect installed slicers</b>. Bed Ready finds slicers you already have (OrcaSlicer, Snapmaker Orca, PrusaSlicer, Bambu Studio, Cura, and others) and lets you set a default. Bed Ready never bundles a slicer.</p>
        <h4>Where the printer &amp; filament lists come from</h4>
        <p>The converter reads the printer, print, and filament <i>profiles that already ship with your installed OrcaSlicer / Snapmaker Orca</i>. Nothing is downloaded — if a printer or filament isn’t there, install/update that slicer and it appears.</p>
        <h4>On a Snapmaker U1</h4>
        <p>You can pick the exact filament loaded in each slot from your Orca library, and choose the print-quality preset. Those choices are written into the converted file.</p>
      </div>` },
    { id: 'files', label: 'Files, preview &amp; colours', html: `
      <div class="help-section">
        <h4>3D preview</h4>
        <p>Every <code>.3mf</code>/<code>.stl</code> gets an interactive 3D preview — drag to orbit, scroll to zoom. Multi-plate files show a plate picker, and you can recolour swatches live to see how a colour change looks.</p>
        <h4>Print-file library</h4>
        <p>Keep your models with notes, tags, the slicer profile you use, and any converted versions, so you always find the right file fast.</p>
        <h4>Inventory &amp; costing</h4>
        <p>Track filament spools and get a per-print cost estimate. The converter can even hint the nearest colour you have in stock for each slot.</p>
      </div>` },
    { id: 'data', label: 'Your data &amp; privacy', html: `
      <div class="help-section">
        <h4>Local-first</h4>
        <p>Your data lives on <b>your</b> computer. Bed Ready works fully offline and does not send your models or data anywhere by default. There is no analytics/telemetry tracking built in.</p>
        <h4>Backups</h4>
        <p>Use <b>Settings → Backup</b> to export a full backup file, and set restore points before big changes. Keep your backups somewhere safe.</p>
        <h4>Optional cloud</h4>
        <p>Cloud sync is opt-in and end-to-end encrypted — only you hold the key. You never need an account to use Bed Ready.</p>
      </div>` },
    { id: 'legal', label: 'Disclaimers &amp; credits', html: `
      <div class="help-section">
        <h4>Safety &amp; no warranty</h4>
        <p>Bed Ready is provided <b>“as is”, without warranty of any kind</b>. 3D printing involves high temperatures and moving parts. <b>Always review any file — especially a converted one — in your own slicer before printing</b>, and supervise your printer. You are solely responsible for what you print and for any damage to your printer, materials, or surroundings. Bed Ready is not affiliated with, or endorsed by, Snapmaker, Bambu Lab, Prusa Research, Creality, UltiMaker, or any other maker mentioned; product names are trademarks of their respective owners.</p>
        <h4>Credits &amp; open source</h4>
        <ul>
          <li>Built on <b>Electron</b> and <b>Node.js</b>.</li>
          <li>The colour-mixing (“Full Spectrum”) model is ported from Bed Ready’s own web app and <b>approximates Snapmaker Orca’s pigment mixer</b> (<code>filament_mixer_model.h</code>, MIT, © Justin Hayes), itself an approximation of the <b>Mixbox</b> pigment model.</li>
          <li>Colour distance uses the <b>CIEDE2000</b> standard.</li>
          <li>The converter <b>reads</b> printer/filament/print profiles from your installed <b>OrcaSlicer</b> / <b>Snapmaker Orca</b> (GPL/AGPL projects). Bed Ready does not bundle or redistribute those profiles.</li>
          <li>The 3D preview is a custom WebGL renderer — no third-party 3D engine.</li>
        </ul>
        <p class="help-muted">Bed Ready’s source is available under FSL-1.1-Apache-2.0. Full third-party notices ship in <code>CREDITS.md</code>. Questions, feedback or takedown requests: use the Feedback button or visit <b>bedready.io</b>.</p>
      </div>` },
  ];
  const nav = SECTIONS.map((s, i) => `<button class="help-tab-btn${i === 0 ? ' active' : ''}" data-htab="${s.id}">${s.label}</button>`).join('');
  const body = SECTIONS.map((s, i) => `<div class="help-tab-content${i === 0 ? ' active' : ''}" id="htab-${s.id}">${s.html}</div>`).join('');
  openFormModal({
    title: 'Bed Ready — Help & FAQ',
    noSave: true,
    sizeLg: true,
    bodyHtml: `<div class="help-tab-nav">${nav}</div><div id="helpTabContents">${body}</div>`,
    onMount(modal) {
      modal.querySelector('.help-tab-nav').addEventListener('click', (e) => {
        const btn = e.target.closest('.help-tab-btn');
        if (!btn) return;
        modal.querySelectorAll('.help-tab-btn').forEach(b => b.classList.remove('active'));
        modal.querySelectorAll('.help-tab-content').forEach(c => c.classList.remove('active'));
        btn.classList.add('active');
        const tc = modal.querySelector('#htab-' + btn.dataset.htab);
        if (tc) tc.classList.add('active');
      });
      if (initial) { const b = modal.querySelector(`.help-tab-btn[data-htab="${initial}"]`); if (b) b.click(); }
    }
  });
}

function openHelpModal() {
  if (isBedReadyFlavor()) return openBedReadyHelp();
  const tabs = ['start', 'calc', 'queue', 'invoice', 'backup'];
  const tabNavHtml = tabs.map((tab, i) => `<button class="help-tab-btn${i === 0 ? ' active' : ''}" data-htab="${tab}">${escapeHtml(t('help.tab.' + tab))}</button>`).join('');
  const tabContentHtml = tabs.map((tab, i) => `
    <div class="help-tab-content${i === 0 ? ' active' : ''}" id="htab-${tab}">
      <div class="help-section">
        <h4>${escapeHtml(t('help.' + tab + '.h1'))}</h4>
        <p>${escapeHtml(t('help.' + tab + '.p1'))}</p>
        ${t('help.' + tab + '.h2') !== 'help.' + tab + '.h2' ? `<h4>${escapeHtml(t('help.' + tab + '.h2'))}</h4>` : ''}
        ${['li1','li2','li3'].some(k => t('help.' + tab + '.' + k) !== 'help.' + tab + '.' + k)
          ? `<ul>${['li1','li2','li3'].filter(k => t('help.' + tab + '.' + k) !== 'help.' + tab + '.' + k).map(k => `<li>${escapeHtml(t('help.' + tab + '.' + k))}</li>`).join('')}</ul>` : ''}
      </div>
    </div>`).join('');

  openFormModal({
    title: t('help.title'),
    noSave: true,
    sizeLg: true,
    bodyHtml: `
      <div class="help-tab-nav">${tabNavHtml}</div>
      <div id="helpTabContents">${tabContentHtml}</div>`,
    onMount(modal) {
      modal.querySelector('.help-tab-nav').addEventListener('click', (e) => {
        const btn = e.target.closest('.help-tab-btn');
        if (!btn) return;
        modal.querySelectorAll('.help-tab-btn').forEach(b => b.classList.remove('active'));
        modal.querySelectorAll('.help-tab-content').forEach(c => c.classList.remove('active'));
        btn.classList.add('active');
        const tc = modal.querySelector('#htab-' + btn.dataset.htab);
        if (tc) tc.classList.add('active');
      });
    }
  });
}

/* ============================================================
   Feedback / Bug report modal
   ============================================================ */
// Bed Ready routes feedback to its own site (bedready.io), not Khayt's support
// inbox. Change here if a dedicated feedback path is added (e.g. /feedback).
const BEDREADY_SITE_URL = 'https://bedready.io';

function openFeedbackModal() {
  // Bed Ready (the standalone maker app) sends people to the bedready.io website
  // instead of showing Khayt's email-a-report form.
  if (isBedReadyFlavor()) {
    if (window.hubAPI?.openExternal) window.hubAPI.openExternal(BEDREADY_SITE_URL);
    else window.open(BEDREADY_SITE_URL);
    return;
  }
  openFormModal({
    title: t('feedback.title'),
    saveLabel: t('feedback.send'),
    noSave: false,
    bodyHtml: `
      <label for="fbType" style="margin-top:0;">${escapeHtml(t('feedback.type'))}</label>
      <select id="fbType">
        <option value="feedback">${escapeHtml(t('feedback.type_feedback'))}</option>
        <option value="suggestion">${escapeHtml(t('feedback.type_suggestion'))}</option>
        <option value="bug">${escapeHtml(t('feedback.type_bug'))}</option>
      </select>
      <label for="fbMessage" style="margin-top:14px;">${escapeHtml(t('feedback.message'))}</label>
      <textarea id="fbMessage" rows="5" style="resize:vertical;" placeholder="${escapeHtml(t('feedback.message_ph'))}"></textarea>
      <label for="fbEmail" style="margin-top:14px;">${escapeHtml(t('feedback.email'))} <span style="color:var(--text-muted);font-size:11.5px;">(${escapeHtml(t('common.optional'))})</span></label>
      <input type="email" id="fbEmail" placeholder="you@example.com">
      <p style="font-size:11.5px;color:var(--text-muted);margin:10px 0 0;">${escapeHtml(t('feedback.hint'))}</p>
      <div style="margin-top:12px;">
        <button id="btnFbGithub" class="btn ghost small" type="button">🐛 ${escapeHtml(t('feedback.github_btn'))}</button>
      </div>`,
    onMount(modal) {
      modal.querySelector('#btnFbGithub').addEventListener('click', () => {
        const url = 'https://github.com/khaytapp/Khayt/issues/new';
        if (window.hubAPI?.openExternal) window.hubAPI.openExternal(url);
        else window.open(url);
      });
    },
    async onSave(modal) {
      const type    = modal.querySelector('#fbType').value;
      const message = (modal.querySelector('#fbMessage').value || '').trim();
      const email   = (modal.querySelector('#fbEmail').value  || '').trim();
      if (!message) { toast(t('feedback.err_empty'), 'error'); return false; }
      const appTag = isBedReadyFlavor() ? 'Bed Ready' : 'Khayt';
      const subject = encodeURIComponent(`[${appTag}] ${t('feedback.type_' + type)}`);
      const body = encodeURIComponent(
        `Type: ${t('feedback.type_' + type)}\n\n${message}${email ? `\n\nFrom: ${email}` : ''}`
      );
      const mailto = `mailto:support@khaytapp.com?subject=${subject}&body=${body}`;
      try {
        if (window.hubAPI?.openExternal) {
          const res = await window.hubAPI.openExternal(mailto);
          if (!res?.ok) {
            toast(t('feedback.err_no_mail') || 'Could not open your email app.', 'error');
            return false;
          }
        } else {
          window.open(mailto);
        }
      } catch (err) {
        toast(t('feedback.err_no_mail') || 'Could not open your email app.', 'error');
        return false;
      }
      toast(t('feedback.sent'), 'success');
      return true;
    }
  });
}

  global._escHandlerStack = _escHandlerStack;
  window._toast = toast;
  window._t = t;

  const api = {

    wireFormLabels,
    toast,
    appendStackedModal,
    confirmModal,
    openFormModal,
    applyTheme,
    applyAnalyticsModeView,
    applyMode,
    initAppShell,
    syncTopbarTitle,
    switchTab,
    openSettingsSection,
    resolveSettingsSection,
    SETTINGS_SECTION_ALIASES,
    openGlobalSearch,
    // Read accessor. `globalSearchOpen` is a `let` INSIDE this file's IIFE, so it is not a
    // global — app-boot.js's keydown handler referenced it directly and threw a
    // ReferenceError on every keystroke, which also meant Cmd/Ctrl+K never opened search.
    // A live accessor rather than exporting the value, which would snapshot it.
    isGlobalSearchOpen: () => globalSearchOpen,
    closeGlobalSearch,
    renderGlobalResults,
    handleGlobalSearchKeydown,
    openHelpModal,
    openBedReadyHelp,
    openFeedbackModal,
  };

  Object.assign(global, api);
  global.KhaytShell = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
