/**
 * Guided tour — a lightweight first-run walkthrough that steps through the main
 * tabs with a short explanation card for each. Deliberately tab-based (not
 * pixel-anchored tooltips) so it stays robust across the app's many themes and
 * RTL. Runs once after onboarding (settings.tourDone) and can be replayed from
 * Settings. Pure DOM + existing globals (switchTab, settings, saveAll, t).
 */
(function (global) {
  'use strict';

  // Each step: a tab to reveal + an i18n title/body. Tabs that don't exist in
  // the current mode are skipped at runtime.
  const STEPS = [
    { tab: 'dashboard-tab',  title: 'tour.dash_t',  body: 'tour.dash_b' },
    { tab: 'calculator-tab', title: 'tour.calc_t',  body: 'tour.calc_b' },
    { tab: 'queue-tab',      title: 'tour.queue_t', body: 'tour.queue_b' },
    { tab: 'inventory-tab',  title: 'tour.inv_t',   body: 'tour.inv_b' },
    { tab: 'clients-tab',    title: 'tour.clients_t', body: 'tour.clients_b' },
    { tab: 'analytics-tab',  title: 'tour.an_t',    body: 'tour.an_b' },
  ];

  const tr = (k) => (typeof t === 'function' ? t(k) : k);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  function finish() {
    const el = document.getElementById('khaytTourOverlay');
    if (el) el.remove();
    try { settings.tourDone = true; saveAll(); } catch (e) { /* ignore */ }
  }

  function startTour() {
    if (typeof document === 'undefined') return;
    document.getElementById('khaytTourOverlay')?.remove();
    // Only steps whose tab button exists (respects Simple/Pro mode).
    const steps = STEPS.filter((s) => document.querySelector(`[data-tab="${s.tab}"]`));
    if (!steps.length) { finish(); return; }
    let i = 0;

    const overlay = document.createElement('div');
    overlay.id = 'khaytTourOverlay';
    overlay.style.cssText = 'position:fixed;inset:0;z-index:9000;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;padding:20px;';
    const isAr = (typeof i18n !== 'undefined' && i18n.current === 'ar');
    overlay.dir = isAr ? 'rtl' : 'ltr';

    const render = () => {
      const s = steps[i];
      if (typeof switchTab === 'function') { try { switchTab(s.tab); } catch (e) { /* ignore */ } }
      const last = i === steps.length - 1;
      overlay.innerHTML = `
        <div role="dialog" aria-modal="true" aria-label="${esc(tr('tour.title'))}" style="background:var(--bg-card,#1a1d24);color:var(--text,#e8eaed);border:1px solid var(--border,#2a2e38);border-radius:16px;max-width:440px;width:100%;padding:22px 24px;box-shadow:0 12px 40px rgba(0,0,0,.4);">
          <div style="font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--text-muted,#9aa0aa);">${esc(tr('tour.title'))} · ${i + 1}/${steps.length}</div>
          <h2 style="font-size:19px;margin:6px 0 8px;">${esc(tr(s.title))}</h2>
          <p style="font-size:14px;line-height:1.55;color:var(--text-soft,#c8ccd2);margin:0 0 18px;">${esc(tr(s.body))}</p>
          <div style="display:flex;gap:8px;align-items:center;">
            <button type="button" id="tourSkip" class="btn ghost small" style="margin:0;">${esc(tr('tour.skip'))}</button>
            <span style="flex:1;"></span>
            ${i > 0 ? `<button type="button" id="tourBack" class="btn ghost small" style="margin:0;">${esc(tr('tour.back'))}</button>` : ''}
            <button type="button" id="tourNext" class="btn primary small" style="margin:0;">${esc(last ? tr('tour.done') : tr('tour.next'))}</button>
          </div>
        </div>`;
      overlay.querySelector('#tourSkip').onclick = finish;
      overlay.querySelector('#tourBack') && (overlay.querySelector('#tourBack').onclick = () => { i = Math.max(0, i - 1); render(); });
      overlay.querySelector('#tourNext').onclick = () => { if (last) finish(); else { i++; render(); } };
    };

    overlay.addEventListener('click', (e) => { if (e.target === overlay) finish(); });
    document.body.appendChild(overlay);
    render();
  }

  /** Auto-run once, after onboarding. */
  function maybeStartTour() {
    try { if (settings && settings.firstRunDone && !settings.tourDone) setTimeout(startTour, 700); } catch (e) { /* ignore */ }
  }

  const api = { startTour, maybeStartTour, STEPS };
  Object.assign(global, { startTour, maybeStartTour });
  global.KhaytTour = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
