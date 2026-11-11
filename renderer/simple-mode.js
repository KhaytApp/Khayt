'use strict';
/* ============================================================
   Simple mode — what the shop's mode shows, read from SIMPLE_MAP
   ============================================================
 *
 * lib/feature-tiers.js SIMPLE_MAP (S4) says, surface by surface, what Simple
 * shows: 'show', 'reduced' or 'pro'. This file is where the desktop asks it.
 *
 *   simpleShows(key)  — does the shop's current mode show this surface?
 *                       Professional shows everything. Simple hides the 'pro'
 *                       rows. Enthusiast (Bed Ready) is unchanged: its gating
 *                       stays the .pro-only / .biz-only classes.
 *
 * How a 'pro' surface is hidden in Simple:
 *   - an element that is the Pro part of a row carries data-simple-pro="<key>"
 *     (styles.css: body.mode-simple [data-simple-pro] is hidden). Unlike
 *     .pro-only it leaves enthusiast alone, so Bed Ready keeps what it had.
 *   - a tab or a Settings pane listed in TAB_KEYS / PANE_KEYS is gated: reaching
 *     it in Simple (search, a link, a shortcut, a menu, switching mode while on
 *     it) shows the "Part of Professional" panel with a switch, never an empty
 *     page. shell.js switchTab / openSettingsSection ask tabGate / paneGate.
 *   - an in-place view (schedule, kiosk, campaign) asks allow(key, label): in
 *     Simple it offers the switch instead of opening.
 *
 * 'reduced' rows whose reduced screen is not drawn yet keep today's behaviour;
 * see UNTIL_DESIGNED.
 */
(function () {
  const Tiers = () => (typeof KhaytTiers !== 'undefined' ? KhaytTiers
    : (typeof require === 'function' ? require('../lib/feature-tiers.js') : null));

  /** 'reduced' rows whose reduced screen is not designed yet, and what Simple
   *  does with them meanwhile.
   *  TODO(S4, Mac page 09): Expenses becomes a short list in Simple (add an
   *  expense, this month's total) once the Mac draws it; until then it stays
   *  hidden in Simple, as before S4. Money (`money`, the Analytics tab) keeps
   *  today's Simple reports view (shell.js applyAnalyticsModeView) until the
   *  one-page Money summary is drawn — it is not listed here because it is
   *  already shown in Simple. */
  const UNTIL_DESIGNED = { expenses: 'pro' };

  /** Tabs gated by a SIMPLE_MAP row. */
  const TAB_KEYS = { 'expenses-tab': 'expenses' };
  /** Settings panes gated by a SIMPLE_MAP row (pane id → row). */
  const PANE_KEYS = { team: 'team', ai: 'ai' };

  /** What Simple does with one surface today: SIMPLE_MAP, with UNTIL_DESIGNED applied. */
  function decision(key) {
    if (Object.prototype.hasOwnProperty.call(UNTIL_DESIGNED, key)) return UNTIL_DESIGNED[key];
    const T = Tiers();
    return T ? T.simpleDecision(key) : undefined;
  }

  /** Does `mode` show the surface `key`? Professional → yes. Simple → unless
   *  the row is 'pro'. Enthusiast → as Simple here; its own commerce gating is
   *  done elsewhere. An unknown key is shown. */
  function shows(key, mode) {
    const m = mode || 'professional';
    if (m === 'professional') return true;
    return decision(key) !== 'pro';
  }

  const currentMode = () => {
    try { return (typeof settings !== 'undefined' && settings && settings.mode) || 'professional'; } catch (_) { return 'professional'; }
  };

  /** Does the shop's current mode show this surface? */
  function simpleShows(key) { return shows(key, currentMode()); }

  /** The row a tab is gated by in `mode`, or null. Only Simple gates here. */
  function tabGate(tabId, mode) {
    const key = TAB_KEYS[tabId];
    return key && mode === 'simple' && !shows(key, mode) ? key : null;
  }

  /** The row a Settings pane is gated by in `mode`, or null. */
  function paneGate(section, mode) {
    const key = PANE_KEYS[section];
    return key && mode === 'simple' && !shows(key, mode) ? key : null;
  }

  /* ── The "Part of Professional" panel ─────────────────────────────── */

  const esc = (s) => (typeof escapeHtml === 'function' ? escapeHtml(s) : String(s == null ? '' : s));
  const tr = (k, v) => (typeof t === 'function' ? t(k, v) : k);

  /** The Simple screen that stands in for a Professional one, per row: the
   *  line the panel adds and the screen its "Open …" button goes to. Empty
   *  until a reduced screen exists — the Money page and the short Expenses
   *  list (S4 cards 4–5) add theirs here when they are built:
   *    e.g. expenses: { line: 'sm.eq_expenses', name: 'tab.expenses', tab: 'expenses-tab' } */
  const EQUIVALENTS = {};

  /** Figma 7Iqw0GcrLLRW7CLDEhTa1P "S4 · Simple mode (desktop)", card 2: a
   *  round mark, "{Screen} is part of Professional", "This shop is set to
   *  Simple." plus the Simple equivalent when there is one, and the buttons
   *  "Open {equivalent}" (only then) and "Switch to Professional". */
  function gatedHtml(feature, key) {
    const eq = key ? EQUIVALENTS[key] : null;
    return `<div class="sm-gate-card" role="region" aria-labelledby="smGateTitle">
      <div class="sm-gate-mark" aria-hidden="true"></div>
      <h2 class="sm-gate-title" id="smGateTitle">${esc(tr('sm.gated_title', { feature: feature || '' }))}</h2>
      <p class="sm-gate-body">${esc(tr('sm.gated_body'))}${eq ? ' ' + esc(tr(eq.line)) : ''}</p>
      <div class="sm-gate-actions">
        ${eq ? `<button type="button" class="btn" data-act="sm-open-simple">${esc(tr('sm.gated_open', { screen: tr(eq.name) }))}</button>` : ''}
        <button type="button" class="btn primary" data-act="sm-switch-pro">${esc(tr('sm.gated_switch'))}</button>
      </div>
    </div>`;
  }

  /** Fill `host` with the panel for the row `key`; its buttons switch to
   *  Professional, or open the Simple equivalent. */
  function renderGated(host, feature, key) {
    if (!host) return;
    host.innerHTML = gatedHtml(feature, key);
    host.querySelector('[data-act="sm-switch-pro"]')?.addEventListener('click', () => switchToProfessional());
    const eq = key ? EQUIVALENTS[key] : null;
    host.querySelector('[data-act="sm-open-simple"]')?.addEventListener('click', () => {
      if (eq?.tab && typeof switchTab === 'function') switchTab(eq.tab);
      else if (eq?.pane && typeof openSettingsSection === 'function') openSettingsSection(eq.pane);
    });
  }

  /** The mode switch the Settings › General cards do, from anywhere. applyMode
   *  re-opens a gated tab or pane that is on screen, so the shop lands on what
   *  it asked for. */
  function switchToProfessional() {
    if (typeof settings === 'undefined') return;
    settings.mode = 'professional';
    if (typeof saveAll === 'function') saveAll();
    if (typeof applyMode === 'function') applyMode();
    if (typeof toast === 'function') toast(tr('set.mode_changed'), 'success');
  }

  /** For a view that opens in place (no tab or pane of its own): true when
   *  the mode shows it; otherwise offers the switch and returns false. */
  function allow(key, feature) {
    if (simpleShows(key)) return true;
    if (typeof confirmModal !== 'function') return false;
    confirmModal(`${tr('sm.gated_title', { feature: feature || '' })}\n\n${tr('sm.gated_body')}`,
      { okText: tr('sm.gated_switch'), cancelText: tr('common.cancel') })
      .then((yes) => { if (yes) switchToProfessional(); });
    return false;
  }

  const api = { UNTIL_DESIGNED, EQUIVALENTS, TAB_KEYS, PANE_KEYS, decision, shows, simpleShows, tabGate, paneGate, gatedHtml, renderGated, switchToProfessional, allow };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytSimpleMode = api;
})();
