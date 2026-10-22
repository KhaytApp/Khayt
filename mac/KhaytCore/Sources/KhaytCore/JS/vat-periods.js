'use strict';
/**
 * The shop's VAT RETURN PERIODS, which of them it has FILED, and where a
 * change lands once the period it touches is filed.
 *
 * ── THE OWNER'S RULE (2026-10-22) ────────────────────────────────────────
 *
 * VAT is due on issued invoices (lib/pnl-report.js, VAT IS DUE WHEN THE
 * INVOICE IS ISSUED). A cancelled, voided or credited invoice used to take
 * its VAT out of the period it was BOOKED in, an edited one to change it, and
 * a backdated one to add to it — even when that period's return had already
 * been filed, so the figure on screen stopped matching the one sent to ZATCA.
 * Now:
 *
 *  - a period NOT filed works as before: its figures follow the book;
 *  - a period FILED keeps exactly the figures it was filed with, and every
 *    later change to it — negative or positive, output VAT and taxable sales —
 *    lands in the FIRST OPEN period on or after the day of the change (and
 *    never before the day after the filed period). "We must adjust it next
 *    quarter or month depending on the business size."
 *
 * ── THE SETTINGS ──────────────────────────────────────────────────────────
 *
 * `settings.vatFilingFrequency`: `'quarterly'` (the default) or `'monthly'`.
 * ZATCA puts a business with annual taxable turnover over SAR 40M on monthly
 * returns and everyone else on quarterly. The shop says which; nothing here
 * guesses it from turnover.
 *
 * `settings.vatFiledPeriods`: the returns the shop has marked filed, one
 * record per period, written by `markFiled`:
 *
 *     { period: '2026-Q3' | '2026-09',       // the return's period key
 *       filedAt: '2026-10-20T09:12:00.000Z', // when it was marked (ISO)
 *       totals: { vat: 1234.5, sales: 8230 },// what the return held
 *       orders: { 'INV-2026-0012': [13.04, 86.96], … } } // the SNAPSHOT
 *
 * `orders` maps each job with tax in the period to `[vat, sales]`, rounded to
 * the halala, as the book showed it when the period was marked — a job with
 * none is left out (absent is zero). About 30 bytes a job: a shop with 300
 * invoices a quarter carries ~9 KB per quarter, ~110 KB over three years.
 *
 * ONLY AN EXPLICIT MARK COUNTS: a period whose deadline has passed is not
 * filed until the shop says so. Marking a period filed never changes its own
 * figures — it records them.
 *
 * A BARE STRING (`'2026-Q3'`), or any record without `orders`, is a mark with
 * no snapshot. It counts as filed for where OTHER adjustments land, and
 * corrects nothing itself: its period reads as the book says. That is the
 * conservative reading — with nothing recorded, nothing is moved.
 *
 * A period key is either shape whatever the frequency is today, so a shop
 * that moves from quarterly to monthly keeps its old quarters filed. A period
 * that overlaps one already marked cannot be marked as well.
 *
 * ── THE CHANGE'S DAY ──────────────────────────────────────────────────────
 *
 * `cancelledAt`: the LOCAL calendar day, `YYYY-MM-DD`, stamped by
 * lib/order-status.js when a job is cancelled (as `quoteAcceptedAt` is), and
 * removed when it is un-cancelled. Every writer — Mac, desktop, iPhone — must
 * write that one field in that one format. A job's change day is its cancel
 * or void (`cancelledAt`, else the last `statusHistory` entry to `cancelled`,
 * then `voidedAt`, `creditedAt` — the earliest), else its latest credit
 * note's `issuedAt`, else its sync stamp `updatedAt`, each read as its local
 * day. With none, the change lands on the first day after the filed period.
 *
 * Pure: no DOM, no clock (the caller passes `now`), book days compared as
 * `YYYY-MM-DD` strings with calendar arithmetic on the numbers, so no time
 * zone can move a day.
 */
(function (global) {
  const FREQUENCIES = Object.freeze(['quarterly', 'monthly']);
  const DEFAULT_FREQUENCY = 'quarterly';
  const DAY = /^\d{4}-\d{2}-\d{2}$/;
  const pad = (n) => String(n).padStart(2, '0');

  function pnl() {
    if (typeof global !== 'undefined' && global.KhaytPnl) return global.KhaytPnl;
    if (typeof require === 'function') {
      try { return require('./pnl-report.js'); } catch (_) { return null; }
    }
    return null;
  }

  /** The shop's return frequency, `'quarterly'` unless it said monthly. */
  function frequencyOf(settings) {
    const f = settings && settings.vatFilingFrequency;
    return f === 'monthly' ? 'monthly' : DEFAULT_FREQUENCY;
  }

  /**
   * A stamp as the LOCAL day it fell on: a bare `YYYY-MM-DD` as written, an
   * ISO instant in this machine's zone (as pnl-report `taxPointDate` reads
   * `quoteAcceptedAt`). '' for nothing usable.
   */
  function localDay(stamp) {
    if (stamp == null || stamp === '' || typeof stamp === 'boolean') return '';
    const s = String(stamp);
    if (s.length > 10 && /^\d{4}-\d{2}-\d{2}T/.test(s)) {
      const d = new Date(s);
      if (!isNaN(d.getTime())) return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    }
    const day = s.slice(0, 10);
    return DAY.test(day) ? day : '';
  }

  /** The return period holding a book day: `2026-Q3`, or `2026-09` monthly. */
  function periodKeyOf(day, frequency) {
    const d = String(day || '').slice(0, 10);
    if (!DAY.test(d)) return '';
    const y = d.slice(0, 4), m = +d.slice(5, 7);
    if (m < 1 || m > 12) return '';
    return frequency === 'monthly' ? `${y}-${pad(m)}` : `${y}-Q${Math.ceil(m / 3)}`;
  }

  /** The whole days a key names, `{ from, to }`, or null for neither shape. */
  function periodBounds(key) {
    const m = /^(\d{4})-(?:Q([1-4])|(0[1-9]|1[0-2]))$/.exec(String(key || ''));
    if (!m) return null;
    const y = +m[1];
    const first = m[2] ? (+m[2] - 1) * 3 : +m[3] - 1;
    const count = m[2] ? 3 : 1;
    const last = new Date(Date.UTC(y, first + count, 0)).getUTCDate();
    return { from: `${y}-${pad(first + 1)}-01`, to: `${y}-${pad(first + count)}-${pad(last)}` };
  }

  /** The book day after `day`, by calendar arithmetic. */
  function dayAfter(day) {
    const d = new Date(Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10) + 1));
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
  }

  /** The period after `key`, in the same shape. */
  function nextPeriodKey(key) {
    const b = periodBounds(key);
    if (!b) return '';
    return periodKeyOf(dayAfter(b.to), /^\d{4}-Q/.test(key) ? 'quarterly' : 'monthly');
  }

  /**
   * The return periods that overlap `{from, to}`, oldest first, in the shop's
   * frequency. `to` defaults to `from`; at most `cap` (default 60) keys.
   */
  function periodsBetween(from, to, frequency, cap) {
    const a = String(from || '').slice(0, 10), b = String(to || from || '').slice(0, 10);
    if (!DAY.test(a) || !DAY.test(b) || a > b) return [];
    const out = [];
    const limit = cap > 0 ? cap : 60;
    let key = periodKeyOf(a, frequency);
    while (key && out.length < limit) {
      const bounds = periodBounds(key);
      if (!bounds || bounds.from > b) break;
      out.push(key);
      key = nextPeriodKey(key);
    }
    return out;
  }

  /** The shop's filed marks, normalised; unreadable entries are dropped. */
  function filedMarks(settings) {
    const list = settings && Array.isArray(settings.vatFiledPeriods) ? settings.vatFiledPeriods : [];
    const out = [];
    for (const raw of list) {
      const rec = typeof raw === 'string' ? { period: raw } : raw;
      if (!rec || typeof rec !== 'object') continue;
      const period = String(rec.period || '');
      const bounds = periodBounds(period);
      if (!bounds) continue;
      out.push({
        period, from: bounds.from, to: bounds.to,
        filedAt: typeof rec.filedAt === 'string' ? rec.filedAt : '',
        // The snapshot, or null for a mark that has none.
        orders: rec.orders && typeof rec.orders === 'object' && !Array.isArray(rec.orders) ? rec.orders : null,
        totals: rec.totals && typeof rec.totals === 'object' ? rec.totals : null,
      });
    }
    return out;
  }

  /** The mark for exactly this period key, or null. */
  function markFor(settings, key) {
    return filedMarks(settings).find((m) => m.period === key) || null;
  }

  /** Is this return period marked filed (exactly, or wholly inside a mark)? */
  function isFiled(settings, key) {
    const b = periodBounds(key);
    if (!b) return false;
    return filedMarks(settings).some((m) => m.period === key || (m.from <= b.from && m.to >= b.to));
  }

  /** The filed mark whose period holds this day, or null. */
  function coveringMark(settings, day, marks) {
    const d = String(day || '').slice(0, 10);
    if (!DAY.test(d)) return null;
    for (const m of marks || filedMarks(settings)) if (m.from <= d && d <= m.to) return m;
    return null;
  }

  /**
   * WHERE A REVERSAL LANDS: the first day on or after `day` that no filed
   * return covers — `day` itself when its period is open, else the first day
   * of the next open period. The answer is a book DAY, so a caller buckets it
   * by whatever grain it draws (a monthly P&L under a quarterly filer, say).
   */
  function landingDay(day, settings, marks) {
    let d = String(day || '').slice(0, 10);
    if (!DAY.test(d)) return '';
    const list = marks || filedMarks(settings);
    for (let i = 0; i <= list.length; i++) {
      const m = coveringMark(settings, d, list);
      if (!m) return d;
      d = dayAfter(m.to);
    }
    return d;
  }

  /** The return period (shop's frequency) a reversal of `day` lands in. */
  function landingPeriod(day, settings) {
    return periodKeyOf(landingDay(day, settings), frequencyOf(settings));
  }

  /** Is this job's invoice undone — cancelled, voided or credited in full? */
  function isReversed(o) {
    if (!o || typeof o !== 'object') return false;
    return o.status === 'cancelled' || !!o.voidedAt || !!o.creditedAt;
  }

  /**
   * The local day the job's invoice was undone, or '' when nothing says.
   * The EARLIEST of the stamps that apply (see THE CANCEL'S DAY).
   */
  function reversalDayOf(o) {
    if (!o || typeof o !== 'object') return '';
    const days = [];
    if (o.status === 'cancelled') {
      const own = localDay(o.cancelledAt);
      if (own) days.push(own);
      else if (Array.isArray(o.statusHistory)) {
        for (let i = o.statusHistory.length - 1; i >= 0; i--) {
          const h = o.statusHistory[i];
          if (h && h.status === 'cancelled') { const d = localDay(h.at); if (d) days.push(d); break; }
        }
      }
    }
    if (o.voidedAt) { const d = localDay(o.voidedAt); if (d) days.push(d); }
    if (o.creditedAt) { const d = localDay(o.creditedAt); if (d) days.push(d); }
    days.sort();
    return days[0] || '';
  }

  /**
   * Mark a return period filed. Returns NEW settings (the input untouched).
   *
   * `orders` is the book's job list and `ctx` `{ clients, currencies }` what
   * the P&L is asked with: the snapshot is the period's figures, job by job,
   * exactly as the book shows them now (lib/pnl-report.js `filedSnapshot`).
   * Re-marking a period takes a fresh snapshot. A period that OVERLAPS
   * another marked one (a month inside a filed quarter) is refused — the
   * settings come back unchanged. `now` is a Date or ISO string.
   */
  function markFiled(settings, key, orders, now, ctx) {
    const s = settings || {};
    const bounds = periodBounds(key);
    if (!bounds) return { ...s };
    const others = filedMarks(s).filter((m) => m.period !== key);
    if (others.some((m) => m.from <= bounds.to && m.to >= bounds.from)) return { ...s };
    const P = pnl();
    const without = unmarkFiled(s, key);
    const c = ctx || {};
    const snap = P && typeof P.filedSnapshot === 'function'
      ? P.filedSnapshot(orders, key, { settings: without, clients: c.clients, currencies: c.currencies })
      : { totals: { vat: 0, sales: 0 }, orders: {} };
    const at = now instanceof Date ? now.toISOString() : String(now || '');
    const record = { period: key, filedAt: at, totals: snap.totals, orders: snap.orders };
    const list = without.vatFiledPeriods.concat([record])
      .sort((a, b) => String(typeof a === 'string' ? a : a.period).localeCompare(String(typeof b === 'string' ? b : b.period)));
    return { ...s, vatFiledPeriods: list };
  }

  /** Take a period's filed mark off. Returns NEW settings. */
  function unmarkFiled(settings, key) {
    const s = settings || {};
    const list = (Array.isArray(s.vatFiledPeriods) ? s.vatFiledPeriods : [])
      .filter((r) => (typeof r === 'string' ? r : r && r.period) !== key);
    return { ...s, vatFiledPeriods: list };
  }

  /**
   * The return periods a screen offers to mark, newest first: those in
   * `{from, to}` (or the last `count`, default 8, up to `today`) that have
   * ENDED by `today` — a return is filed after its period closes, and
   * marking a running one would push its own reversals out of it. Each with
   * whether it is filed.
   */
  function filingPeriods(settings, opts) {
    const o = opts || {};
    const today = String(o.today || '').slice(0, 10);
    if (!DAY.test(today)) return [];
    const freq = frequencyOf(settings);
    let keys;
    if (o.from || o.to) {
      const from = String(o.from || '').slice(0, 10) || today;
      const to = String(o.to || '').slice(0, 10) || today;
      keys = periodsBetween(from, to < today ? to : today, freq);
    } else {
      keys = [];
      let key = periodKeyOf(today, freq);
      const count = o.count > 0 ? o.count : 8;
      // Walk back from the current one.
      for (let i = 0; i < count + 1 && key; i++) {
        keys.unshift(key);
        const b = periodBounds(key);
        const prev = new Date(Date.UTC(+b.from.slice(0, 4), +b.from.slice(5, 7) - 1, 0));
        key = periodKeyOf(`${prev.getUTCFullYear()}-${pad(prev.getUTCMonth() + 1)}-${pad(prev.getUTCDate())}`, freq);
      }
    }
    return keys
      .filter((k) => { const b = periodBounds(k); return b && b.to < today; })
      .reverse()
      .map((k) => ({ period: k, ...periodBounds(k), filed: isFiled(settings, k) }));
  }

  const api = {
    FREQUENCIES, DEFAULT_FREQUENCY,
    frequencyOf, localDay, periodKeyOf, periodBounds, nextPeriodKey, periodsBetween, dayAfter,
    filedMarks, markFor, isFiled, coveringMark, landingDay, landingPeriod,
    isReversed, reversalDayOf,
    markFiled, unmarkFiled, filingPeriods,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytVatPeriods = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
