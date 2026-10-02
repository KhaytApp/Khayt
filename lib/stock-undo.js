/**
 * Undoing a status move puts back the stock the move changed.
 *
 * A status move can now write the shelf: reopening a finished job gives its
 * filament and consumables back (`lib/order-status.js`, `ctx.returnMaterial`).
 * The Undo the desktop and Bed Ready offer restored the ORDER alone, so undoing
 * a reopen would keep the returned grams AND the restored "material taken" flag:
 * a print's worth of filament the shop does not have. So every undoable move
 * takes this snapshot first, and its Undo puts back exactly the spools and
 * consumables the move changed.
 *
 *   const stock = KhaytStockUndo.capture({ inventory, consumables });
 *   ...apply the move and run its effects...
 *   stock.seal();                 // what the move changed, decided now
 *   undo: () => { stock.restore(); ...restore the order... }
 *
 * A record edited AGAIN after the move (a spool topped up while the toast was
 * showing) is left as it is: putting back the before-move copy would undo that
 * edit too. `restore` reports how many it skipped so the caller can say so.
 *
 * Pure: arrays in, arrays mutated in place, nothing else.
 */
(function (global) {
  const key = (r) => (r && r.id != null ? String(r.id) : null);
  // Sync metadata is not the record's content. Saving after the move stamps a
  // new rev/updatedAt (lib/sync.js stampChanges), which must not read as "edited
  // again", and the restore keeps the CURRENT rev so the undo travels to other
  // devices as a newer edit rather than an older copy they would ignore.
  const META = ['rev', 'updatedAt'];
  const json = (r) => {
    if (!r || typeof r !== 'object') return JSON.stringify(r);
    const c = { ...r };
    for (const k of META) delete c[k];
    return JSON.stringify(c);
  };

  function snapshot(list) {
    const m = new Map();
    for (const r of Array.isArray(list) ? list : []) { const k = key(r); if (k !== null) m.set(k, { cmp: json(r), full: JSON.stringify(r) }); }
    return m;
  }

  /**
   * @param {{ inventory?: Array, consumables?: Array }} lists the live arrays
   */
  function capture(lists) {
    const l = lists || {};
    const tracked = [l.inventory, l.consumables].filter(Array.isArray);
    const before = tracked.map(snapshot);
    let changed = null;   // per list: Map id -> { before, after }

    function seal() {
      changed = tracked.map((list, i) => {
        const out = new Map();
        for (const r of list) {
          const k = key(r);
          if (k === null || !before[i].has(k)) continue;
          const now = json(r);
          if (now !== before[i].get(k).cmp) out.set(k, { before: before[i].get(k).full, after: now });
        }
        return out;
      });
      return changed.reduce((n, m) => n + m.size, 0);
    }

    /** Put back what the move changed. @returns {{ restored: number, skipped: number }} */
    function restore() {
      if (!changed) seal();
      let restored = 0, skipped = 0;
      tracked.forEach((list, i) => {
        for (const [k, v] of changed[i]) {
          const at = list.findIndex((r) => key(r) === k);
          if (at < 0 || json(list[at]) !== v.after) { skipped++; continue; }
          const back = JSON.parse(v.before);
          for (const m of META) { if (m in list[at]) back[m] = list[at][m]; else delete back[m]; }
          list[at] = back;
          restored++;
        }
      });
      return { restored, skipped };
    }

    return { seal, restore };
  }

  const api = { capture };
  global.KhaytStockUndo = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
