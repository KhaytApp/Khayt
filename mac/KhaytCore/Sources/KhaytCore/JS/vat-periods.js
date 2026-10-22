'use strict';
/**
 * The shop's VAT RETURN PERIODS, which of them it has FILED, and where a
 * reversal lands once the period it undoes is filed.
 *
 * ── THE OWNER'S RULE (2026-10-22) ────────────────────────────────────────
 *
 * VAT is due on issued invoices (lib/pnl-report.js, VAT IS DUE WHEN THE
 * INVOICE IS ISSUED). When an invoiced job is cancelled, voided or credited,
 * its VAT used to vanish from the period it was BOOKED in, even when that
 * period's return had already been filed — so the figure on screen no longer
 * matched the figure the shop had sent ZATCA. Now:
 *
 *  - the period NOT filed: as before, the VAT simply drops out of it;
 *  - the period FILED: it stays exactly as it was filed, and the reversal —
 *    negative output VAT, negative taxable sales — lands in the FIRST OPEN
 *    period on or after the day of the cancel / void / credit (the period
 *    holding that day, or, if that one is filed too, the next one that is
 *    not). "We must adjust it next quarter or month depending on the
 *    business size."
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
 *     { period: '2026-Q3' | '2026-09',     // the return's period key
 *       filedAt: '2026-10-20T09:12:00.000Z', // when it was marked (ISO)
 *       reversedIds: ['INV-2026-0012', …] } // see THE SNAPSHOT
 *
 * A bare string (`'2026-Q3'`) is read as a mark with no date and no snapshot.
 * ONLY AN EXPLICIT MARK COUNTS: a period whose deadline has passed is not
 * filed until the shop says so.
 *
 * A period key is either shape whatever the frequency is today, so a shop
 * that moves from quarterly to monthly keeps its old quarters filed. "Is this
 * day in a filed return" is asked of every mark that covers the day.
 *
 * ── THE SNAPSHOT: WAS THE REVERSAL IN THE RETURN AS FILED? ────────────────
 *
 * A job cancelled in October whose invoice is dated in Q3 was OUT of the Q3
 * figure the shop saw — and filed — if the cancel came before the return
 * went in, and IN it if after. The cancel's date cannot always answer that:
 * the iPhone writes `status: 'cancelled'` and nothing else, books from before
 * `cancelledAt` carry no stamp at all, and a stamp that is a bare day cannot
 * order itself against a filing made the same afternoon. So `markFiled`
 * records the ids of the invoices dated in the period that were ALREADY
 * reversed when it was marked (`reversedIds`). A job on that list was out of
 * the return as filed and stays out (no adjustment); a reversed job NOT on it
 * was undone after filing, so the period keeps its VAT and the reversal moves
 * forward. Marking a period filed therefore never changes that period's
 * figures at the moment it is marked — what the shop just filed is what it
 * keeps seeing.
 *
 * A mark WITHOUT a snapshot (a bare string, or a record another build wrote)
 * falls back to dates: the reversal's local day against `filedAt`'s local day
 * (before it: out of the return), or, with no `filedAt`, against the period's
 * last day (a return cannot be filed before its period ends). A reversal with
 * no date at all is taken as before filing — what Khayt showed, and so what
 * the shop most likely filed — and is never moved.
 *
 * ── THE CANCEL'S DAY ──────────────────────────────────────────────────────
 *
 * `cancelledAt`: the LOCAL calendar day, `YYYY-MM-DD`, stamped by
 * lib/order-status.js when a job is cancelled (as `quoteAcceptedAt` is), and
 * removed when it is un-cancelled. Every writer — Mac, desktop, iPhone — must
 * write that one field in that one format. Read, in order: `cancelledAt`, the
 * last `statusHistory` entry to `cancelled` (an ISO instant, read as its
 * local day), `voidedAt`, `creditedAt` — the earliest that applies. A
 * reversal with none lands in the first open period after the filed one it
 * undoes, never inside it.
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
        reversedIds: Array.isArray(rec.reversedIds) ? rec.reversedIds.map(String) : null,
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
   * Was an event dated `stamp` already in effect when `mark`'s return was
   * filed? Only for a mark without a snapshot — see THE SNAPSHOT. No date:
   * before (it is never moved).
   */
  function beforeFiling(stamp, mark) {
    const day = localDay(stamp);
    if (!day) return true;
    const filedDay = localDay(mark && mark.filedAt);
    if (filedDay) return day < filedDay;
    return day <= mark.to;
  }

  /** Was this job's whole reversal already in the return `mark` filed? */
  function reversedBeforeFiling(o, mark) {
    if (Array.isArray(mark.reversedIds)) return mark.reversedIds.includes(String(o && o.id));
    return beforeFiling(reversalDayOf(o), mark);
  }

  /** Was this credit note already in the return `mark` filed? By its stamp. */
  function creditBeforeFiling(note, mark) {
    return beforeFiling(note && note.issuedAt, mark);
  }

  /**
   * Mark a return period filed. Returns NEW settings (the input untouched).
   *
   * `orders` is the book's job list, from which the snapshot is taken: the
   * ids of the invoices dated in the period that are already reversed. Re-
   * marking a period replaces its record (a fresh snapshot, a fresh date).
   * `now` is a Date or ISO string; it is required so the rule reads no clock.
   */
  function markFiled(settings, key, orders, now) {
    const s = settings || {};
    const bounds = periodBounds(key);
    if (!bounds) return { ...s };
    const P = pnl();
    const at = now instanceof Date ? now.toISOString() : String(now || '');
    const reversedIds = [];
    for (const o of Array.isArray(orders) ? orders : []) {
      if (!o || o.id == null || !isReversed(o)) continue;
      if (P && typeof P.wouldBeTaxPoint === 'function' && !P.wouldBeTaxPoint(o, s)) continue;
      const day = P ? P.taxPointDate(o) : String(o.date || '').slice(0, 10);
      if (day >= bounds.from && day <= bounds.to) reversedIds.push(String(o.id));
    }
    const kept = (Array.isArray(s.vatFiledPeriods) ? s.vatFiledPeriods : [])
      .filter((r) => (typeof r === 'string' ? r : r && r.period) !== key);
    const record = { period: key, filedAt: at, reversedIds };
    const list = kept.concat([record])
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
    isReversed, reversalDayOf, reversedBeforeFiling, creditBeforeFiling,
    markFiled, unmarkFiled, filingPeriods,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytVatPeriods = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
