/**
 * The job page (S1 · desktop M4): one place to see a job, with the next step
 * pinned. Figma 7Iqw0GcrLLRW7CLDEhTa1P: page 74:387, money on a quote 95:422.
 *
 * This is the READ side. What the next step is, its pill, its stage track and
 * why a step is refused all come from the shared rule `lib/order-next-step.js`
 * (KhaytOrderNextStep.nextSteps), the same one the Mac and the iPhone word;
 * the margin from `lib/order-edit.js marginOf`. This file only draws them.
 *
 * Moves along the queue go through the desktop's own `updateStatus` (which
 * runs the status gate and asks for actuals when it must). A step that needs
 * a question the page does not ask yet — hold, a failed check, shipping —
 * opens the existing job editor, which stays until the page covers all it does.
 *
 * Opened from a job's ⋯ menu ("Open page"); Back returns to where you were.
 */
(function (global) {
  'use strict';

  const NS = () => global.KhaytOrderNextStep;
  const ED = () => global.KhaytOrderEdit;
  let openId = null;

  const byId = (id) => (typeof printLog !== 'undefined' ? printLog.find((o) => o.id === id) : null);
  const clientName = (o) => {
    const c = o && o.clientId && typeof clients !== 'undefined' ? clients.find((x) => x.id === o.clientId) : null;
    return c && typeof localName === 'function' ? localName(c) : '';
  };
  const day = (iso) => {
    if (!iso) return '';
    const ms = Date.parse(String(iso).length === 10 ? iso + 'T00:00:00' : iso);
    return Number.isFinite(ms) ? new Date(ms).toLocaleDateString(localeTag(), { day: 'numeric', month: 'short' }) : '';
  };
  const money = (o, n) => (typeof fmtMoneyIn === 'function' && o.currency ? fmtMoneyIn(n, o.currency) : fmtMoney(n));
  const OWN_WORDS = { paid: 'jp.stage_paid', cancelled: 'jp.stage_cancelled', split: 'jp.stage_split' };
  const stageWord = (stage) => t(OWN_WORDS[stage] || ('queue.' + stage));

  function partsHtml(o) {
    const parts = Array.isArray(o.parts) ? o.parts : [];
    if (!parts.length) return `<p class="jp-empty">${escapeHtml(t('jp.no_parts'))}</p>`;
    return parts.map((p) => {
      const qty = Math.max(1, +p.qty || 1);
      const what = [`×${qty}`, [p.material, p.color].filter(Boolean).join(' ')].filter(Boolean).join(' · ');
      const g = +p.printWeight || +p.weight || 0;
      const h = +p.printTime || 0;
      const size = [g ? `${Math.round(g)} g` : '', h ? `${Math.floor(h)}h ${Math.round((h % 1) * 60)}m` : ''].filter(Boolean).join(' · ');
      return `<div class="jp-part"><div><div class="jp-part-name">${escapeHtml(p.name || '—')}</div>
        <div class="jp-sub">${escapeHtml(what)}</div></div><div class="jp-num">${escapeHtml(size)}</div></div>`;
    }).join('');
  }

  function moneyHtml(o, steps) {
    const quote = steps.stage === 'quote';
    const paid = +o.paidAmount || 0;
    const parts = Array.isArray(o.parts) ? o.parts : [];
    // A part's `baseCost` is its whole line (quantity included, as
    // lib/order-edit.js costedOf sums it) and is in the SHOP's currency, so a
    // job taken in another one shows it divided by the rate it was taken at,
    // as its price is. It was multiplied by the quantity again and shown in
    // the job's currency unconverted (pre-release review, Nov 16).
    const fx = +o.fxRate > 0 && +o.fxRate !== 1 ? +o.fxRate : 1;
    const cost = (parts.reduce((s, p) => s + Math.max(0, +p.baseCost || 0), 0)
      + Math.max(0, +o.componentsCost || 0) + Math.max(0, +o.overheadCost || 0)) / fx;
    const margin = ED() && ED().marginOf ? ED().marginOf(o) : null;
    const row = (label, value, cls) => `<div class="jp-row ${cls || ''}"><span>${escapeHtml(label)}</span><span class="jp-num">${escapeHtml(value)}</span></div>`;
    return row(t('jp.price'), money(o, +o.price || 0))
      + row(t('jp.paid'), quote ? '—' : money(o, paid), 'is-muted')
      + row(t('jp.owing'), quote ? '—' : money(o, steps.owed || 0), 'is-strong' + (!quote && steps.late && steps.owed > 0 ? ' is-late' : ''))
      + (quote ? `<p class="jp-note">${escapeHtml(t('jp.quote_money_note'))}</p>` : '')
      + row(t('jp.cost'), cost > 0 ? money(o, cost) : '—', 'is-muted')
      + row(t('jp.margin'), margin === null ? t('jp.margin_typed') : `${margin} %`, 'is-muted');
  }

  const PR = () => global.KhaytPaymentReminder;

  /** The last recorded change of price: { at, from, to }, or null. */
  function lastRepricing(o) {
    const h = Array.isArray(o.editHistory) ? o.editHistory : [];
    for (let i = h.length - 1; i >= 0; i--) {
      const p = h[i] && h[i].fields && h[i].fields.price;
      if (p && p.from !== undefined && p.to !== undefined) return { at: h[i].at, from: +p.from, to: +p.to };
    }
    return null;
  }

  /**
   * The job's milestones, and, when a re-price left them no longer adding up,
   * what to do about it (Turki, Nov 17; Figma 96:1067). A proforma already
   * SENT stays exactly as sent: it shows what it is now short, and "Send
   * updated proforma" issues a new one for that (lib/payment-reminder.js
   * differenceProforma). One not sent yet shows old → new, and "Update the
   * unsent milestones" moves it, only when pressed (refreshedMilestones, which
   * never touches a sent one). Empty when the job has no milestones.
   */
  function milestonesHtml(o) {
    const rows = Array.isArray(o.milestoneInvoices) ? o.milestoneInvoices.filter((m) => m && m.id) : [];
    const R = PR();
    if (!rows.length || !R || typeof R.milestoneGap !== 'function') return '';
    const g = R.milestoneGap(o);
    const off = new Map(g.rows.map((r) => [r.id, r]));
    const rp = g.stale ? lastRepricing(o) : null;
    const banner = g.stale ? `<div class="jp-banner is-warn" role="status">
        <strong>${escapeHtml(t('jp.ms.banner'))}</strong>
        <span>${escapeHtml(rp ? t('jp.ms.repriced', { date: day(rp.at), from: money(o, rp.from), to: money(o, rp.to) })
          : t('jp.ms.price_now', { price: money(o, g.price) }))} ${escapeHtml(t('jp.ms.sent_stays'))}</span>
      </div>` : '';
    const lines = rows.map((m) => {
      const r = off.get(String(m.id));
      const pct = +m.percentage > 0 ? ` · ${+m.percentage}%` : '';
      const state = m.kind === 'difference' ? t('jp.ms.difference')
        : m.issuedAt ? t('jp.ms.sent', { date: day(m.issuedAt) }) : t('jp.ms.unsent');
      const value = r && !r.issued ? `${money(o, r.amount)} → ${money(o, r.expected)}` : money(o, +m.amount || 0);
      let sub = '';
      if (r && r.issued && r.diff > 0) sub = t('jp.ms.short', { share: money(o, r.expected), amount: money(o, r.diff) });
      else if (r && r.issued && r.diff < 0) sub = t('jp.ms.over', { amount: money(o, -r.diff) });
      else if (r && !r.issued) sub = t('jp.ms.can_follow');
      return `<div class="jp-row"><span>${escapeHtml(String(m.label || '') + pct)} · ${escapeHtml(state)}</span>
          <span class="jp-num">${escapeHtml(value)}</span></div>${sub ? `<p class="jp-note">${escapeHtml(sub)}</p>` : ''}`;
    }).join('');
    const sum = rows.reduce((a, m) => a + (+m.amount || 0), 0);
    const total = g.stale ? `<div class="jp-row is-strong is-warn"><span>${escapeHtml(t('jp.ms.adds_up'))}</span>
        <span class="jp-num">${escapeHtml(t('jp.ms.of', { sum: money(o, sum), price: money(o, g.price) }))}</span></div>` : '';
    const sendBtns = g.rows.filter((r) => r.issued && r.diff > 0).map((r) =>
      `<button type="button" class="btn primary" data-jp="ms-diff" data-ms="${escapeHtml(r.id)}">${escapeHtml(t('jp.ms.send_diff', { amount: money(o, r.diff) }))}</button>`).join('');
    const unsent = g.rows.filter((r) => !r.issued).length;
    const refreshBtn = Math.abs(g.unissuedDiff) >= 0.01
      ? `<button type="button" class="btn" data-jp="ms-refresh">${escapeHtml(t(unsent > 1 ? 'jp.ms.update_many' : 'jp.ms.update_one'))}</button>` : '';
    return `<section class="card jp-card jp-milestones"><h3 class="jp-card-head">${escapeHtml(t('jp.milestones'))} · ${rows.length}</h3>
        ${banner}${lines}${total}${refreshBtn || sendBtns ? `<div class="jp-actions">${refreshBtn}${sendBtns}</div>` : ''}</section>`;
  }

  function activityHtml(o) {
    const items = (Array.isArray(o.statusHistory) ? o.statusHistory : [])
      .map((h) => ({ at: h.at, text: t('jp.moved', { stage: stageWord(h.status) }) }));
    if (o.paidAt && +o.paidAmount > 0) items.push({ at: o.paidAt, text: t('jp.paid_event', { amount: money(o, +o.paidAmount) }) });
    if (o.quoteSharedAt) items.push({ at: o.quoteSharedAt, text: t('jp.quote_shared') });
    items.sort((a, b) => String(b.at).localeCompare(String(a.at)));
    if (!items.length) return `<p class="jp-empty">${escapeHtml(t('jp.no_activity'))}</p>`;
    return items.slice(0, 20).map((i) => `<div class="jp-event"><div>${escapeHtml(i.text)}</div><div class="jp-sub">${escapeHtml(day(i.at))}</div></div>`).join('');
  }

  const stepBtn = (s, primary) => {
    const blocked = s.blocked ? ` disabled aria-describedby="jpBlocked"` : '';
    return `<button type="button" class="btn ${primary ? 'primary' : ''}" data-jp-step="${escapeHtml(s.code)}"${blocked}>${escapeHtml(t('jp.step.' + s.code))}</button>`;
  };

  function pageHtml(o) {
    const steps = NS().nextSteps(o, { settings, orders: printLog, today: localDateStr(), canWrite: true });
    const ref = typeof jobRef === 'function' ? jobRef(o) : o.id;
    const sub = [clientName(o), o.dueDate ? t('jp.due', { date: day(o.dueDate) }) : '', o.material || ''].filter(Boolean).join(' · ');
    const blocked = [steps.primary, ...(steps.secondary || [])].find((s) => s && s.blocked);
    const track = (steps.track || []).map((tk) => `<li class="jp-track-step is-${escapeHtml(tk.state)}"><span class="jp-dot"></span>
        <span class="jp-track-name">${escapeHtml(stageWord(tk.stage))}</span><span class="jp-sub">${escapeHtml(day(tk.at))}</span></li>`).join('');
    return `<div class="jp-top">
        <button type="button" class="btn ghost small" data-jp="back">‹ ${escapeHtml(t('jp.back'))}</button>
      </div>
      <header class="jp-head">
        <div class="jp-head-text">
          <div class="jp-eyebrow">${escapeHtml(t('jp.eyebrow', { ref }))}</div>
          <h2 class="jp-title">${escapeHtml(o.project || ref)}
            <span class="badge ${escapeHtml(steps.pill.stage === 'paid' ? 'pay-paid' : steps.pill.stage)}">${escapeHtml(stageWord(steps.pill.stage))}</span>
            ${steps.late ? `<span class="badge overdue">${escapeHtml(t('jp.late'))}</span>` : ''}</h2>
          <div class="jp-sub">${escapeHtml(sub)}</div>
        </div>
        <div class="jp-steps" role="group" aria-label="${escapeHtml(t('jp.next_steps'))}">
          ${(steps.secondary || []).map((s) => stepBtn(s, false)).join('')}
          <button type="button" class="btn" data-jp="edit">${escapeHtml(t('jp.edit'))}</button>
          ${steps.primary ? stepBtn(steps.primary, true) : ''}
        </div>
      </header>
      ${blocked ? `<p class="jp-blocked" id="jpBlocked">${escapeHtml(t('jp.blocked.' + blocked.blocked.code))}</p>` : ''}
      ${track ? `<ol class="card jp-track">${track}</ol>` : ''}
      <div class="jp-grid">
        <section class="card jp-card"><h3 class="jp-card-head">${escapeHtml(t('jp.parts'))} · ${(o.parts || []).length}</h3>${partsHtml(o)}</section>
        <section class="card jp-card"><h3 class="jp-card-head">${escapeHtml(t('jp.money'))}</h3>${moneyHtml(o, steps)}</section>
      </div>
      ${milestonesHtml(o)}
      <section class="card jp-card"><h3 class="jp-card-head">${escapeHtml(t('jp.activity'))}</h3>${activityHtml(o)}</section>
      ${global.KhaytJobPageCards ? global.KhaytJobPageCards.html(o) : ''}`;
  }

  function host() {
    let el = document.getElementById('jobPage');
    if (!el) {
      el = document.createElement('section');
      el.id = 'jobPage';
      el.className = 'job-page';
      el.setAttribute('aria-label', t('jp.aria'));
      el.hidden = true;
      (document.getElementById('mainContent') || document.body).appendChild(el);
    }
    return el;
  }

  function render() {
    const o = byId(openId);
    const el = host();
    if (!o || !NS()) { closeJobPage(); return; }
    el.innerHTML = pageHtml(o);
    // Photos, files, comments, updates, connected apps (renderer/job-page-cards.js).
    if (global.KhaytJobPageCards) global.KhaytJobPageCards.after(el, o);
  }

  function openJobPage(id) {
    if (!byId(id) || !NS()) return;
    openId = id;
    // The ⋯ menu it was opened from closes, as a click on one of its items does elsewhere.
    document.querySelectorAll('.row-actions-menu.open').forEach((m) => {
      m.classList.remove('open');
      m.previousElementSibling?.setAttribute('aria-expanded', 'false');
    });
    const el = host();
    render();
    el.hidden = false;
    el.scrollTop = 0;
    el.querySelector('[data-jp="back"]')?.focus();
  }

  function closeJobPage() {
    openId = null;
    const el = document.getElementById('jobPage');
    if (el) { el.hidden = true; el.innerHTML = ''; }
  }

  function runStep(code) {
    const o = byId(openId);
    if (!o) return;
    const steps = NS().nextSteps(o, { settings, orders: printLog, today: localDateStr(), canWrite: true });
    const s = [steps.primary, ...(steps.secondary || [])].find((x) => x && x.code === code);
    if (!s || s.blocked) return;
    if (code === 'record_payment') { openPaymentModal(o.id); return; }
    if (code === 'send_quote') { openQuoteApprovalLinkModal(o.id); return; }
    if (code === 'hand_over') { markDelivered(o.id); render(); return; }
    // The steps that ask a question open the desktop's own dialog for it, the
    // one the board and the queue use (renderer/order-flows.js): on hold asks
    // why, a failed check what failed, shipping the carrier and tracking. Each
    // saves through saveAll, which redraws this page. They opened the old job
    // editor (S1, Nov 18).
    const dialog = { hold: global.holdOrder, fail_check: global.qcFailOrder, ship: global.openShipModal }[code];
    if (typeof dialog === 'function') { dialog(o.id); return; }
    // Anything else that asks a question the page does not ask yet: the job editor.
    if (!s.to || s.asks === 'hold' || s.asks === 'qc_fail') { openOrderEditor(o.id); return; }
    updateStatus(o.id, s.to);
    render();
  }

  document.addEventListener('click', (e) => {
    const open = e.target.closest('[data-act="job-page"]');
    if (open) { openJobPage(open.dataset.id); return; }
    if (!openId) return;
    const b = e.target.closest('#jobPage [data-jp], #jobPage [data-jp-step]');
    if (!b) return;
    if (b.dataset.jp === 'back') { closeJobPage(); return; }
    if (b.dataset.jp === 'edit') { (typeof openJobSheet === 'function' ? openJobSheet : openOrderEditor)(openId); return; }
    if (b.dataset.jp === 'ms-refresh') { refreshMilestones(); return; }
    if (b.dataset.jp === 'ms-diff') { sendDifference(b.dataset.ms); return; }
    if (b.dataset.jpStep) runStep(b.dataset.jpStep);
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && openId && !document.querySelector('.modal-backdrop, .modal-overlay')) closeJobPage();
  });

  /** The unsent milestones at their share of the price now; a sent one is never touched. */
  function refreshMilestones() {
    const o = byId(openId);
    if (!o || !PR()) return;
    o.milestoneInvoices = PR().refreshedMilestones(o);
    saveAll();
    render();
  }

  /** A new proforma for what a sent milestone is now short, issued at once. */
  async function sendDifference(milestoneId) {
    const o = byId(openId);
    if (!o || !PR()) return;
    const m = (o.milestoneInvoices || []).find((x) => x && String(x.id) === String(milestoneId));
    const row = PR().differenceProforma(o, milestoneId, { id: uid('MS'), label: t('jp.ms.diff_label', { label: (m && m.label) || '' }) });
    if (!row) return;
    o.milestoneInvoices.push(row);
    saveAll();
    if (typeof generateMilestoneInvoice === 'function') await generateMilestoneInvoice(o.id, row);
    render();
  }

  /** Redraw after the job changes elsewhere (a payment, the editor). */
  function refreshJobPage() { if (openId) render(); }

  // Every change to the book is saved through `saveAll`, so the page redraws
  // after each save while it is open: a payment or the editor's Save shows here.
  if (typeof global.saveAll === 'function' && !global.saveAll.__jobPage) {
    const save = global.saveAll;
    const wrapped = function (...args) {
      const out = save.apply(this, args);
      try { refreshJobPage(); } catch (_) { /* the page is a view; a redraw never blocks a save */ }
      return out;
    };
    wrapped.__jobPage = true;
    global.saveAll = wrapped;
  }

  Object.assign(global, { openJobPage, closeJobPage, refreshJobPage });
})(typeof window !== 'undefined' ? window : globalThis);
