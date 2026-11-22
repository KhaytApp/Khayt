'use strict';
/**
 * The shop's own KPI email: when it is due, what it says, and how it looks.
 *
 * The desktop has sent it since the digest scheduler shipped
 * (renderer/integrations.js `checkAndSendDigest`, renderer/settings.js
 * `buildDigestEmailHtml`), with every rule inline. The Mac sends it too now —
 * the shop picks this local email, Khayt Cloud's weekly owner digest, both, or
 * neither — so the schedule, the figures and the page are here, and both apps
 * send the same email at the same hour for the same book.
 *
 * `settings.emailDigest` is the shape the desktop writes:
 *   { enabled, frequency: 'daily'|'weekly'|'monthly', hour (0–23),
 *     weekday (0=Sun…6=Sat), monthday (1–28), recipientEmail, lastSentDate }
 * `lastSentDate` is the PERIOD key last sent — `YYYY-MM-DD`, `YYYY-Www` or
 * `YYYY-MM` — which is what stops a second send in the same period, from
 * either app.
 *
 * Local time throughout: "send at 08:00" is the shop's eight o'clock. The
 * calendar is the Gregorian one `Date` keeps, which is the desktop's.
 */
(function (global) {

  const two = (n) => String(n).padStart(2, '0');

  /** The frequency as stored, or daily — the desktop's reading of anything else. */
  function frequencyOf(digest) {
    const f = (digest || {}).frequency;
    return f === 'weekly' || f === 'monthly' ? f : 'daily';
  }

  /** The desktop's week number: Jan 1's weekday shifts it, as it always has. */
  function weekNumber(now) {
    const jan1 = new Date(now.getFullYear(), 0, 1);
    return Math.ceil(((now - jan1) / 86400000 + jan1.getDay() + 1) / 7);
  }

  /** The key of the period `now` falls in, for this digest's frequency. */
  function periodKey(digest, now) {
    const f = frequencyOf(digest);
    if (f === 'weekly') return `${now.getFullYear()}-W${two(weekNumber(now))}`;
    if (f === 'monthly') return `${now.getFullYear()}-${two(now.getMonth() + 1)}`;
    return `${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())}`;
  }

  /** Who it goes to: the address typed for it, else the shop's own. */
  function recipient(digest, settings) {
    const d = digest || {};
    return String(d.recipientEmail || (settings || {}).email || '').trim();
  }

  /**
   * Is the digest due at `now`? `{ due, periodKey, reason }`, `reason` one of
   * `off`, `no_recipient`, `not_this_hour`, `not_this_day`, `already_sent`.
   * The host checks its own mail provider; this is the digest's own rules,
   * the desktop's, in its order.
   */
  function due(settings, now) {
    const s = settings || {};
    const d = s.emailDigest || {};
    const out = { due: false, periodKey: '', reason: '' };
    if (!d.enabled) return Object.assign(out, { reason: 'off' });
    if (!recipient(d, s)) return Object.assign(out, { reason: 'no_recipient' });
    const hour = d.hour == null ? 8 : Number(d.hour);
    if (now.getHours() !== hour) return Object.assign(out, { reason: 'not_this_hour' });
    const f = frequencyOf(d);
    if (f === 'weekly' && now.getDay() !== (d.weekday == null ? 1 : Number(d.weekday))) {
      return Object.assign(out, { reason: 'not_this_day' });
    }
    if (f === 'monthly') {
      // The configured day, clamped to the month's length.
      const lastDom = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
      const fireDom = Math.min(d.monthday == null ? 1 : Number(d.monthday), lastDom);
      if (now.getDate() !== fireDom) return Object.assign(out, { reason: 'not_this_day' });
    }
    out.periodKey = periodKey(d, now);
    if (d.lastSentDate === out.periodKey) return Object.assign(out, { reason: 'already_sent' });
    out.due = true;
    return out;
  }

  /**
   * The period the email covers: `{ label, from, to }`, ISO instants. Monday
   * to now for a week, the 1st to now for a month, midnight to now for a day.
   * `tag` (the host's locale tag) names the month in a monthly label.
   */
  function period(frequency, now, tag) {
    const to = new Date(now);
    if (frequency === 'weekly') {
      const dow = now.getDay();
      const from = new Date(now);
      from.setDate(now.getDate() + (dow === 0 ? -6 : 1 - dow));
      from.setHours(0, 0, 0, 0);
      return { label: `Week ${weekNumber(now)}, ${now.getFullYear()}`, from: from.toISOString(), to: to.toISOString() };
    }
    if (frequency === 'monthly') {
      let label;
      try { label = now.toLocaleDateString(tag, { month: 'long', year: 'numeric' }); }
      catch (e) { label = `${now.getFullYear()}-${two(now.getMonth() + 1)}`; }
      const from = new Date(now.getFullYear(), now.getMonth(), 1, 0, 0, 0, 0);
      return { label, from: from.toISOString(), to: to.toISOString() };
    }
    const from = new Date(now);
    from.setHours(0, 0, 0, 0);
    return { label: periodKey({ frequency: 'daily' }, now), from: from.toISOString(), to: to.toISOString() };
  }

  /**
   * The figures, from the book. `ctx`: `{ orders, inventory, waitingList,
   * settings, clients, now, locale, currencies }`. The money is the shared
   * order-money rules in the shop's base currency, as every report reads it.
   */
  function figures(ctx) {
    const c = ctx || {};
    const settings = c.settings || {};
    const orders = Array.isArray(c.orders) ? c.orders : [];
    const S = global.KhaytOrderStatus;
    const M = global.KhaytOrderMoney;
    const P = global.KhaytOrderPayment;
    if (!S || !M || !P) throw new Error('email-digest: order-status, order-money and order-payment must be loaded');
    const known = c.currencies || (global.KhaytCurrencies && global.KhaytCurrencies.CURRENCIES) || undefined;
    const mctx = { settings, clients: Array.isArray(c.clients) ? c.clients : [] };
    const frequency = frequencyOf(settings.emailDigest);
    const p = period(frequency, c.now, c.locale);

    const completed = orders.filter((o) => S.isFinished(o) &&
      o.completedAt && o.completedAt >= p.from && o.completedAt <= p.to);
    const revenue = completed.reduce((sum, o) => sum + M.orderNetRevenueBase(o, mctx, known), 0);
    const outstanding = orders
      .filter((o) => S.isFinished(o) && P.statusOf(o, { settings }) !== 'paid')
      .reduce((sum, o) => sum + M.orderOwedBase(o, mctx, known), 0);
    const reorderPt = settings.lowStockThreshold ?? 200;
    const lowStock = (Array.isArray(c.inventory) ? c.inventory : [])
      .filter((s) => s && (+s.weight || 0) < (s.reorderPoint ?? reorderPt))
      .slice(0, 5)
      .map((s) => ({ name: s.material || s.brand || 'Spool', weight: +s.weight || 0,
                     reorderAt: s.reorderPoint ?? reorderPt }));
    return {
      frequency, periodLabel: p.label,
      completed: completed.length, revenue, outstanding, lowStock,
      waiting: Array.isArray(c.waitingList) ? c.waitingList.length : 0,
    };
  }

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (ch) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    })[ch]);
  }

  const FREQ_WORD = { daily: 'Daily', weekly: 'Weekly', monthly: 'Monthly' };

  /** The subject line: "<shop> — Weekly Digest", or "— Test Digest" for a test. */
  function subject(shopName, frequency, test) {
    return `${shopName || 'Khayt'} — ${test ? 'Test' : (FREQ_WORD[frequency] || 'Daily')} Digest`;
  }

  /**
   * The email, the desktop's page exactly. `opts`: `{ shopName, currency,
   * today }` — `today` the `YYYY-MM-DD` it is sent on.
   */
  function html(f, opts) {
    const o = opts || {};
    const shopName = esc(o.shopName || 'Khayt');
    const currency = esc(o.currency || 'SAR');
    const lowStockSpools = f.lowStock || [];
    const freqLabel = FREQ_WORD[f.frequency] || 'Daily';
    return `<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>${shopName} Digest</title></head>
<body style="margin:0;padding:0;background:#f4f4f7;font-family:Arial,sans-serif;">
  <div style="max-width:600px;margin:32px auto;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.1);">
    <div style="background:#6c47ff;padding:24px 32px;">
      <h1 style="margin:0;color:#fff;font-size:22px;">${shopName}</h1>
      <p style="margin:4px 0 0;color:rgba(255,255,255,.8);font-size:13px;">${freqLabel} Digest · ${esc(f.periodLabel)}</p>
    </div>
    <div style="padding:28px 32px;">
      <table style="width:100%;border-collapse:collapse;font-size:14px;margin-bottom:24px;">
        <thead><tr style="border-bottom:2px solid #eee;">
          <th style="text-align:left;padding:8px 0;color:#888;">Metric</th>
          <th style="text-align:right;padding:8px 0;color:#888;">Value</th>
        </tr></thead>
        <tbody>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Completed orders this period</td>
            <td style="text-align:right;font-weight:600;">${f.completed}</td>
          </tr>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Revenue this period</td>
            <td style="text-align:right;font-weight:600;color:#22c55e;">${f.revenue.toFixed(2)} ${currency}</td>
          </tr>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Outstanding receivables</td>
            <td style="text-align:right;font-weight:600;color:${f.outstanding > 0 ? '#f59e0b' : '#888'};">${f.outstanding.toFixed(2)} ${currency}</td>
          </tr>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Low-stock spools</td>
            <td style="text-align:right;font-weight:600;color:${lowStockSpools.length > 0 ? '#ef4444' : '#888'};">${lowStockSpools.length}</td>
          </tr>
          <tr>
            <td style="padding:10px 0;">Waiting list items</td>
            <td style="text-align:right;font-weight:600;">${f.waiting}</td>
          </tr>
        </tbody>
      </table>
      ${lowStockSpools.length > 0 ? `
      <div style="background:#fff5f5;border-left:3px solid #ef4444;padding:12px 16px;border-radius:4px;margin-bottom:20px;">
        <div style="font-weight:600;font-size:13px;color:#ef4444;margin-bottom:8px;">Low Stock Alert</div>
        <ul style="margin:0;padding:0 0 0 16px;font-size:13px;color:#333;">
          ${lowStockSpools.map((s) => `<li style="margin-bottom:4px;">${esc(s.name)} — ${s.weight}g remaining (reorder at ${s.reorderAt}g)</li>`).join('')}
        </ul>
      </div>` : ''}
    </div>
    <div style="padding:16px 32px;background:#f8f8fb;text-align:center;font-size:11px;color:#aaa;border-top:1px solid #eee;">
      Sent by Khayt · ${esc(o.today)}
    </div>
  </div>
</body>
</html>`;
  }

  /**
   * The settings the digest records once a send went: the period key, so
   * neither app sends it again in this period.
   */
  function sent(settings, key) {
    const s = settings || {};
    return Object.assign({}, s.emailDigest || {}, { lastSentDate: String(key || '') });
  }

  // ── WHICH SUMMARY THE SHOP GETS ────────────────────────────────────────
  //
  // Two summaries exist: this one, sent from the shop's own computer through
  // its own mail provider on its own schedule, and Khayt Cloud's weekly owner
  // digest, sent by the cloud. The owner decided (Nov 2026) it is the shop's
  // CHOICE — this one, the cloud's, both, or neither. Each half keeps its own
  // switch where it already lives (`emailDigest.enabled` in the book, the
  // cloud's own setting there); these only name the four answers.
  const CHOICES = ['none', 'local', 'cloud', 'both'];
  function choiceOf(localOn, cloudOn) {
    return localOn && cloudOn ? 'both' : localOn ? 'local' : cloudOn ? 'cloud' : 'none';
  }
  function choiceParts(choice) {
    return { local: choice === 'local' || choice === 'both', cloud: choice === 'cloud' || choice === 'both' };
  }

  const api = {
    CHOICES, frequencyOf, weekNumber, periodKey, recipient, due, period, figures,
    subject, html, sent, choiceOf, choiceParts, escape: esc,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytEmailDigest = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
