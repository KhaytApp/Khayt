'use strict';
/**
 * The job intake waiting list: enquiries that are not jobs yet.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * The rules lived inside `renderer/waiting-list.js`, so only the desktop could
 * read the list. The Mac's LAN intake form (`LanServer.swift`, through
 * `lib/lan-intake.js`) wrote customers' requests into `waitingList` and no Mac
 * screen ever showed one. Both apps run these now, on the same records.
 *
 * ── THE RECORD ────────────────────────────────────────────────────────────
 *
 * `waitingList[]` holds the open enquiries; `waitingListHistory[]` the ones
 * turned into work (`status: 'converted'`, `convertedAt`). An entry is
 * `{ id, project, clientId?, clientName?, phone?, email?, notes, priority,
 * status ('active' | 'reminded' | 'declined'), reminderDate, estimatedValue |
 * estValue, addedAt | submittedAt, reminderSentAt?, source? }` — the intake
 * form writes `estValue` and `clientName`, the editor `estimatedValue` and
 * `clientId`, and both are read.
 *
 * PURE: no clock (`now` is passed), no randomness (ids are passed), and every
 * function returns new arrays rather than changing the ones it is handed.
 */
(function (global) {
  const PRIORITIES = ['urgent', 'high', 'normal', 'low'];
  const STATUSES = ['active', 'reminded', 'declined'];
  const RANK = { urgent: 0, high: 1, normal: 2, low: 3 };

  const arrayOf = (v) => (Array.isArray(v) ? v.filter((x) => x && typeof x === 'object') : []);
  const text = (v) => String(v == null ? '' : v);

  /** Still wanting an answer: active, or reminded and not yet answered. */
  function isOpen(item) {
    return !!item && (item.status === 'active' || item.status === 'reminded');
  }

  /** Its estimated value, whichever of the two spellings carries it. */
  function estimate(item) {
    return +((item && (item.estValue || item.estimatedValue)) || 0) || 0;
  }

  /** A reminder date that has come (`today` is `YYYY-MM-DD`), on a live item. */
  function reminderDue(item, today) {
    return !!(item && item.reminderDate && item.reminderDate <= today && item.status !== 'declined');
  }

  /** What the list shows: declined left out, the most urgent first. */
  function visible(list) {
    return arrayOf(list)
      .filter((w) => w.status !== 'declined')
      .map((w, i) => ({ w, i }))
      .sort((a, b) => ((RANK[a.w.priority] ?? 2) - (RANK[b.w.priority] ?? 2)) || (a.i - b.i))
      .map((x) => x.w);
  }

  /** The number on the badge. */
  function openCount(list) {
    return arrayOf(list).filter(isOpen).length;
  }

  /** The funnel: everything ever added, where it went, and what is still in play. */
  function funnel(list, history) {
    const open = arrayOf(list);
    const done = arrayOf(history);
    const all = open.concat(done);
    const total = all.length;
    const active = open.filter(isOpen).length;
    const converted = done.filter((w) => w.status === 'converted').length;
    const declined = all.filter((w) => w.status === 'declined').length;
    const pipeline = open.filter(isOpen).reduce((s, w) => s + estimate(w), 0);
    return {
      total, active, converted, declined,
      convertedPct: total > 0 ? Math.round((converted / total) * 1000) / 10 : 0,
      pipeline: Math.round(pipeline * 100) / 100,
    };
  }

  /**
   * Add an enquiry, or save changes to one. `fields` holds the editor's
   * `{ project, clientId, priority, notes, estimatedValue, reminderDate,
   * status }`; a project is required. Returns `{ ok, list, item }`, or
   * `{ ok: false, error: 'project_required' }`.
   *
   * An edit keeps everything the editor does not show — the phone, the email
   * and the consent the intake form recorded. When the entry carries the
   * intake form's `estValue`, that is set too: it is read FIRST, so writing
   * only `estimatedValue` left the funnel's pipeline on the old figure.
   */
  function saveItem(list, fields, opts) {
    const o = opts || {};
    const f = fields || {};
    const project = text(f.project).trim();
    if (!project) return { ok: false, error: 'project_required' };
    const rows = arrayOf(list).slice();
    const at = o.id ? rows.findIndex((w) => w.id === o.id) : -1;
    if (o.id && at === -1) return { ok: false, error: 'gone' };
    const value = Math.max(0, +f.estimatedValue || 0);
    const shown = {
      project,
      clientId: text(f.clientId),
      priority: PRIORITIES.includes(f.priority) ? f.priority : 'normal',
      notes: text(f.notes).trim(),
      estimatedValue: value,
      reminderDate: text(f.reminderDate),
      status: STATUSES.includes(f.status) ? f.status : 'active',
    };
    let item;
    if (at >= 0) {
      item = Object.assign({}, rows[at], shown);
      if (Object.prototype.hasOwnProperty.call(rows[at], 'estValue')) item.estValue = value;
      rows[at] = item;
    } else {
      item = Object.assign({ id: o.newId, addedAt: o.now }, shown);
      rows.unshift(item);
    }
    return { ok: true, list: rows, item };
  }

  /**
   * Turn an enquiry into work: it leaves the list and goes into the history
   * as `converted`, stamped. Returns `{ list, history, item }` — `item` as it
   * was, for the job sheet to open on — or null when it is not in the list.
   */
  function promote(list, history, id, now) {
    const rows = arrayOf(list);
    const item = rows.find((w) => w.id === id);
    if (!item) return null;
    return {
      list: rows.filter((w) => w.id !== id),
      history: arrayOf(history).concat([Object.assign({}, item, { status: 'converted', convertedAt: now })]),
      item,
    };
  }

  /** The customer was reminded: `reminded`, and when. */
  function markReminded(list, id, now) {
    return arrayOf(list).map((w) => (w.id === id
      ? Object.assign({}, w, { status: 'reminded', reminderSentAt: now }) : w));
  }

  /** The enquiry was turned down. It stays, so the funnel can count it. */
  function decline(list, id) {
    return arrayOf(list).map((w) => (w.id === id ? Object.assign({}, w, { status: 'declined' }) : w));
  }

  /**
   * The customer an enquiry is for: the one it names, else one whose name
   * (either language, any case) or phone matches what the intake form took
   * down, else a new lightweight record — `created`, for the caller to add.
   * `{ clientId: null, created: null }` when it names nobody at all.
   */
  function resolveClient(item, clients, newId) {
    const book = arrayOf(clients);
    if (!item) return { clientId: null, created: null };
    if (item.clientId && book.find((c) => c.id === item.clientId)) return { clientId: item.clientId, created: null };
    const name = text(item.clientName).trim();
    if (!name) return { clientId: null, created: null };
    const lower = name.toLowerCase();
    let found = book.find((c) => text(c.nameEn).trim().toLowerCase() === lower
      || text(c.nameAr).trim().toLowerCase() === lower);
    if (!found && item.phone) {
      const phone = text(item.phone).trim();
      found = book.find((c) => text(c.phone).trim() === phone);
    }
    if (found) return { clientId: found.id, created: null };
    const created = { id: newId, nameEn: name, nameAr: '', phone: item.phone || '', email: item.email || '' };
    return { clientId: newId, created };
  }

  /**
   * What the enquiry said, as the note the new job's line opens with — the
   * desktop's calculator prefill, line for line (and as long).
   */
  function promotionNote(item) {
    if (!item) return '';
    const lines = [];
    if (item.notes && item.notes !== item.project) lines.push(text(item.notes));
    if (item.phone) lines.push(`Phone: ${item.phone}`);
    if (item.email) lines.push(`Email: ${item.email}`);
    if (item.material) lines.push(`Material: ${item.material}`);
    if (item.budget) lines.push(`Budget: ${item.budget}`);
    if (item.referenceLink) lines.push(`Link: ${item.referenceLink}`);
    return lines.join('\n').slice(0, 800);
  }

  const api = {
    PRIORITIES, STATUSES, isOpen, estimate, reminderDue, visible, openCount, funnel,
    saveItem, promote, markReminded, decline, resolveClient, promotionNote,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytIntakeQueue = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
