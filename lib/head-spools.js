(function (global) {
  'use strict';
  /*
   * ── ONE SPOOL, ONE HEAD ──────────────────────────────────────────────────
   *
   * A machine records what each of its heads holds as `headSpools`:
   * `{ "0": spoolId, "1": spoolId, … }`, keyed from zero (people are shown
   * head + 1). The Mac's phone route and the desktop's machine card each wrote
   * `headSpools[head] = spoolId` and nothing else, so moving a spool from
   * head 1 to head 2 left it in BOTH (Baby U1, Nov 27 2026: one Polymaker
   * spool linked to two heads at once). A spool is one physical thing and is
   * in at most one head of one printer.
   *
   * `link` puts a spool in a head and takes it out of every OTHER head, on
   * this machine and on every other machine. Pure: it returns new machine
   * records (only those it changed are new objects) and says what moved, and
   * the caller writes them through its own write chain and stamps them.
   *
   * A head whose printer now reports nothing there KEEPS its link: a U1 clears
   * a head's tag data when the filament is unloaded, and one empty read can
   * also be a reader that missed the tag. `shown` says how to show it ("not in
   * the printer now"); the link goes only when that spool is linked elsewhere,
   * or the shop unlinks it.
   */

  /** A head as the book keys it: "0", "1"…; null when it is not a head number. */
  function headKey(head) {
    const n = typeof head === 'string' && /^\d+$/.test(head) ? Number(head) : head;
    return Number.isInteger(n) && n >= 0 && n < 64 ? String(n) : null;
  }

  function linksOf(machine) {
    const h = machine && machine.headSpools;
    return h && typeof h === 'object' && !Array.isArray(h) ? h : {};
  }

  /**
   * Put `spoolId` in `head` of `machineId`, and out of every other head.
   * → { machines, moved: [{ machineId, head }], changed: [machineId…] }
   * `moved` names the heads the spool was taken out of. Unknown machine,
   * bad head or empty spool id: the machines come back unchanged, with
   * `error` saying which.
   */
  function link(machines, machineId, head, spoolId) {
    const list = Array.isArray(machines) ? machines : [];
    const key = headKey(head);
    const id = spoolId == null ? '' : String(spoolId);
    const mid = machineId == null ? '' : String(machineId);
    if (key === null) return { machines: list, moved: [], changed: [], error: 'bad-head' };
    if (!id) return { machines: list, moved: [], changed: [], error: 'no-spool' };
    if (!list.some((m) => m && String(m.id) === mid)) return { machines: list, moved: [], changed: [], error: 'no-machine' };
    const moved = []; const changed = [];
    const out = list.map((m) => {
      if (!m || typeof m !== 'object') return m;
      const mine = String(m.id) === mid;
      const links = linksOf(m);
      const next = {};
      let touched = false;
      for (const [k, v] of Object.entries(links)) {
        if (String(v) === id && !(mine && k === key)) { moved.push({ machineId: String(m.id), head: k }); touched = true; continue; }
        next[k] = v;
      }
      if (mine) {
        if (links[key] !== id) touched = true;
        next[key] = id;
      }
      if (!touched) return m;
      changed.push(String(m.id));
      return Object.assign({}, m, { headSpools: next });
    });
    return { machines: out, moved, changed };
  }

  /** Take whatever is in `head` of `machineId` out of it. Same shape as `link`. */
  function unlink(machines, machineId, head) {
    const list = Array.isArray(machines) ? machines : [];
    const key = headKey(head);
    const mid = machineId == null ? '' : String(machineId);
    if (key === null) return { machines: list, moved: [], changed: [], error: 'bad-head' };
    const moved = []; const changed = [];
    const out = list.map((m) => {
      if (!m || typeof m !== 'object' || String(m.id) !== mid || !(key in linksOf(m))) return m;
      const next = Object.assign({}, linksOf(m));
      delete next[key];
      moved.push({ machineId: mid, head: key });
      changed.push(mid);
      return Object.assign({}, m, { headSpools: next });
    });
    return { machines: out, moved, changed };
  }

  /**
   * How a head's link is shown, from the book and the printer's latest word:
   * 'linked' (in the printer), 'not-in-printer' (linked, but the printer
   * reports the head empty now: kept, and said), or 'none'.
   * `reportsEmpty` is true only when the printer ANSWERED and said the head
   * is empty; an unanswered printer is not an empty head.
   */
  function shown(linkedSpoolId, reportsEmpty) {
    if (linkedSpoolId == null || String(linkedSpoolId) === '') return 'none';
    return reportsEmpty === true ? 'not-in-printer' : 'linked';
  }

  const api = { headKey, link, unlink, shown };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytHeadSpools = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
