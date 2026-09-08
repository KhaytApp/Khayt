'use strict';

/**
 * What a finished job takes off the shelf.
 *
 * Completing an order draws its grams from the spools that printed it, its
 * glue and isopropyl from the consumables its print hours consumed, its
 * bought-in components from their rows, and one of every packaging item from
 * the box it ships in. Get this wrong in either direction and a shop is either
 * ordering filament it already has or running out of it mid-print.
 *
 * The rules lived in `renderer/inventory.js`, reading `inventory`,
 * `consumables`, `machines` and `settings` off the renderer's globals and
 * calling `toast()` and `renderInventory()` in the middle of the arithmetic.
 * That put them out of reach of the Mac app, which is why its board can show
 * where the work is piling up but cannot let you drop a card on "completed":
 * the move itself is shared (`lib/order-status.js`), but the shelf it empties
 * was not, and a completion that silently failed to deduct would be worse than
 * no drag at all.
 *
 * So the bodies moved here and take their context as an argument.
 *
 * ── WHAT IT TOUCHES ────────────────────────────────────────────────────────
 * The spools and consumable rows it is HANDED, in place, plus `order`'s two
 * already-deducted flags. Nothing else. It returns:
 *
 *   - `notices` — message codes, because this module does not know which
 *     language the shop reads.
 *   - `effects` — saving and redrawing, in the order the original did them.
 *
 * The notices keep their order relative to each other and the effects keep
 * theirs; the two streams are no longer interleaved, because the caller runs
 * them one after the other. Nothing observable depends on a toast appearing
 * between a save and a redraw.
 *
 * ── THE TWO FLAGS ARE THE WHOLE SAFETY MODEL ───────────────────────────────
 * `materialDeducted` and `packagingDeducted` are what stop a job that is
 * completed, re-opened and completed again from being charged twice. They are
 * set at the END, and `materialDeducted` is set even when nothing was actually
 * deducted — a job with no filament assigned has still had its chance.
 *
 * `packagingDeducted` is the exception and it is deliberate: a shop with no
 * packaging stock leaves the job unflagged, so the deduction happens the day
 * they stock some. That asymmetry is in the original and is preserved.
 *
 * PURE: no globals, and no clock — `ctx.today` is the local `YYYY-MM-DD` that
 * goes into each spool's usage history.
 */
(function (global) {

  /** A spool remembers its last two hundred draws and no more. */
  const USAGE_CAP = 200;

  /** Below this many grams a spool is low, when nothing more specific is set. */
  const DEFAULT_LOW_STOCK = 200;

  const ctxOf = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});
  const arrayOf = (v) => (Array.isArray(v) ? v : []);

  /**
   * Is this spool low?
   *
   * Its own reorder point first, then the shop's threshold, then 200g. One
   * definition so the banner, the row badge, the reorder list and the
   * deduction never disagree about the same spool.
   */
  function isLowStock(item, settings) {
    if (!item) return false;
    const s = ctxOf(settings);
    /* The threshold is in the item's OWN unit.
     *
     * 200 is a sensible last spool of filament and absurd for sheet goods,
     * where two left is the moment to order. `KhaytInventoryUnits` knows which,
     * and — this is the part that must not change — it answers 200 for grams
     * and honours the shop's own `lowStockThreshold` there, so no item in any
     * existing book moves. Every item that exists is in grams.
     *
     * Asked through the global rather than required, like every other
     * cross-module reach in this file. Without it loaded the old line stands,
     * which is correct for the only unit that existed when it was written. */
    const U = (typeof global !== 'undefined') && global.KhaytInventoryUnits;
    const threshold = U
      ? U.lowThreshold(item, s)
      : (item.reorderPoint ?? s.lowStockThreshold ?? DEFAULT_LOW_STOCK);
    return (+item.weight || 0) <= threshold;
  }

  /**
   * Candidate spools in the order a multi-site shop should empty them: this
   * branch first, then the unassigned shared ones, then another branch.
   * Stable within each tier, so the shop's own ordering survives.
   */
  function spoolsByLocationPreference(candidates, locId) {
    const list = arrayOf(candidates).slice();
    if (!locId) return list;
    const tier = (s) => {
      if (s && s.locationId === locId) return 0;
      if (!s || !s.locationId) return 1;
      return 2;
    };
    return list
      .map((s, i) => ({ s, i, tier: tier(s) }))
      .sort((a, b) => (a.tier - b.tier) || (a.i - b.i))
      .map((x) => x.s);
  }

  /**
   * Grams a part consumes: print plus support, times quantity.
   *
   * MUST match what the deduction actually draws, because reservation,
   * over-commit and the forecast all quote this number — and a shop that is
   * told it has enough and then runs out mid-print stops trusting the figure.
   */
  function partGramsConsumed(p) {
    return ((+p.printWeight || 0) + (+p.supportWeight || 0)) * (+p.qty || 1);
  }

  /** Which branch a job belongs to: its own, else its machine's. */
  function orderLocationId(order, machines) {
    if (!order) return null;
    if (order.locationId) return order.locationId;
    const list = arrayOf(machines);
    const mid = order.machineId;
    const m = mid
      ? list.find(x => x.id === mid)
      : list.find(x => x.name && order.machine && x.name === order.machine);
    return (m && m.locationId) || null;
  }

  /** Draw `grams` from a spool, recording what it was for. */
  function drawFrom(spool, grams, order, today) {
    spool.weight = Math.max(0, (+spool.weight || 0) - grams);
    if (!spool.usageHistory) spool.usageHistory = [];
    spool.usageHistory.unshift({
      orderId: order.id, project: order.project || '', weightUsed: grams, date: today,
    });
    if (spool.usageHistory.length > USAGE_CAP) spool.usageHistory.length = USAGE_CAP;
  }

  /**
   * What a job owes the shelf, part by part, at the ESTIMATE.
   *
   * Each entry is the spool a part was assigned and the grams that part is
   * expected to take out of it. Split out of `deductForOrder` so a failed print
   * can be settled the same way — off the same spools, in the same proportions
   * — for whatever it actually got through.
   *
   * The shortfall rule is NOT here: covering what a chosen spool cannot supply
   * from its siblings happens at draw time, because it depends on what is left
   * on the shelf at that moment.
   */
  function claimsFor(order, inventory) {
    const shelf = arrayOf(inventory);
    const out = [];
    for (const part of ((order && order.parts) || [])) {
      // A multicolour part is several filaments in one part: each colour's
      // grams come out of its own spool, times the part's quantity.
      if (part.colours && part.colours.length) {
        const perQty = Math.max(1, +part.qty || 1);
        for (const col of part.colours) {
          const primary = col.filamentId && shelf.find(i => i.id === col.filamentId);
          if (!primary) continue;
          const grams = Math.max(0, (+col.grams || 0) * perQty);
          if (grams <= 0) continue;
          out.push({ spool: primary, grams });
        }
        continue;
      }
      if (!part.filamentId || !part.printWeight) continue;
      const primary = shelf.find(i => i.id === part.filamentId);
      if (!primary) continue;
      // Grams the spool-switch flow already took off other spools are not owed
      // again — otherwise switching spools mid-print charges the job twice.
      const extra = (part.additionalSpools || []).reduce((s, a) => s + (+a.weight || 0), 0);
      const remaining = Math.max(0, partGramsConsumed(part) - extra);
      if (remaining <= 0) continue;
      out.push({ spool: primary, grams: remaining });
    }
    return out;
  }

  /** What the claims come to at the estimate. */
  function claimedGrams(claims) {
    return arrayOf(claims).reduce((s, x) => s + (+((x && x.grams)) || 0), 0);
  }

  /**
   * How much of the estimate to deduct, given a measured total.
   *
   * 1 when nothing was measured — the estimate is what Khayt has always
   * deducted and stays the answer. 1 too when the estimate is zero, because
   * there is nothing to scale and scaling by infinity is not a number a shelf
   * can be charged.
   *
   * A measurement LARGER than the estimate scales up rather than being capped:
   * a print that used more than it was quoted really did take that filament
   * off the shelf, and a shelf that refuses to believe it is a shelf that
   * drifts.
   */
  function scaleFor(claims, actualGrams) {
    const actual = +actualGrams;
    if (!Number.isFinite(actual) || actual <= 0) return 1;
    const claimed = claimedGrams(claims);
    if (claimed <= 0) return 1;
    return actual / claimed;
  }

  /**
   * Take `grams` off the shelf for a job that did NOT finish.
   *
   * The same spools, in the same proportions, as a completion would have
   * used — a failed print consumed the filament it was part way through, off
   * the spools it was printing from. Nothing is marked `materialDeducted`,
   * because the job is not done: the reprint will deduct its own.
   *
   * `ctx`: `{ settings, inventory, machines, today }`.
   * Returns `{ deducted, spools, drawn, nowLow }` — the grams actually taken,
   * the spool ids they came off, WHAT CAME OFF EACH, and any spool now low.
   *
   * `drawn` is what makes a deduction reversible. A failure can spill across
   * several spools when the assigned one runs out, and a row that remembers
   * only "which spools" cannot put the right grams back on each.
   */
  function deductActual(order, grams, ctx) {
    const c = ctxOf(ctx);
    const settings = ctxOf(c.settings);
    const inventory = arrayOf(c.inventory);
    const wanted = Math.max(0, +grams || 0);
    const empty = { deducted: 0, spools: [], drawn: [], nowLow: [] };
    if (wanted <= 0) return empty;

    const claims = claimsFor(order, inventory);
    if (!claims.length) return empty;

    /* GRAMS THE SPOOL SWITCH ALREADY TOOK ARE NOT OWED AGAIN.
     *
     * Switching spools mid-print deducts there and then — the filament left
     * that roll when it was loaded — and records the amount on the part.
     * `claimsFor` already subtracts it from what the job still owes, and the
     * weight a shop types for a failed print is the WHOLE print: everything
     * that went through the nozzle, including what came off the spool it
     * switched away from.
     *
     * So the switch's grams come off the figure before it is drawn. Without
     * this a job that switched 50 g and then failed at 120 g would take 120
     * more off the shelf, charging 170 for 120 used.
     */
    const alreadyTaken = ((order && order.parts) || []).reduce(
      (s, part) => s + ((part.additionalSpools || []).reduce((n, a) => n + (+a.weight || 0), 0)), 0);
    const owed = Math.max(0, wanted - alreadyTaken);
    if (owed <= 0) return empty;
    const scale = scaleFor(claims, owed);

    let deducted = 0;
    const spools = [];
    const drawn = [];
    const nowLow = [];
    const orderLoc = orderLocationId(order, c.machines);

    for (const claim of claims) {
      let remaining = claim.grams * scale;
      if (remaining <= 0) continue;
      const others = inventory.filter(s =>
        s.id !== claim.spool.id && s.material === claim.spool.material && (+s.weight || 0) > 0);
      const fallback = orderLoc ? spoolsByLocationPreference(others, orderLoc) : others;
      for (const sp of [claim.spool, ...fallback]) {
        if (remaining <= 0) break;
        const avail = +sp.weight || 0;
        if (avail <= 0) continue;
        const take = Math.min(avail, remaining);
        drawFrom(sp, take, order, c.today);
        remaining -= take;
        deducted += take;
        if (!spools.includes(sp.id)) spools.push(sp.id);
        const already = drawn.find(d => d.spoolId === sp.id);
        if (already) already.grams += take;
        else drawn.push({ spoolId: sp.id, grams: take });
        if (isLowStock(sp, settings) && !nowLow.some(x => x.id === sp.id)) nowLow.push(sp);
      }
    }
    return { deducted, spools, drawn, nowLow };
  }

  /**
   * Put back exactly what a deduction took.
   *
   * `drawn` is what `deductActual` recorded: which spool, and how much off it.
   * A row that remembers only which spools cannot restore correctly when the
   * assigned one ran out and the rest spilled onto its siblings.
   *
   * Returns the grams put back. A spool that has since been deleted is skipped
   * rather than recreated — the filament is gone with it.
   */
  function restoreDrawn(drawn, ctx) {
    const inventory = arrayOf(ctxOf(ctx).inventory);
    let restored = 0;
    for (const d of arrayOf(drawn)) {
      const grams = Math.max(0, +((d && d.grams)) || 0);
      if (grams <= 0) continue;
      const spool = inventory.find(s => s && s.id === d.spoolId);
      if (!spool) continue;
      spool.weight = (+spool.weight || 0) + grams;
      restored += grams;
    }
    return restored;
  }

  /**
   * Take a job's materials off the shelf.
   *
   * `ctx`: `{ settings, inventory, consumables, machines, today, actualGrams }`.
   * `actualGrams` is what the PRINTER says the job used, when anything
   * measured it; absent, the estimate is deducted exactly as before.
   * `opts.skipRender` suppresses only the inventory redraw, as it did before.
   *
   * The shortfall rule matters and is easy to lose: a part draws from the spool
   * it was assigned FIRST, honouring the shop's pick, and covers whatever that
   * spool cannot supply from other spools of the same material. A chosen spool
   * that is already empty is not an error — it is a spool that ran out, and the
   * job still consumed the filament.
   */
  function deductForOrder(order, ctx, opts) {
    const c = ctxOf(ctx);
    const settings = ctxOf(c.settings);
    const inventory = arrayOf(c.inventory);
    const consumables = arrayOf(c.consumables);
    const today = c.today;
    const skipRender = !!ctxOf(opts).skipRender;
    const notices = [];
    const effects = [];

    if (!settings.autoDeduct) return { notices, effects };
    if (order.materialDeducted) return { notices, effects };

    let deductedAny = false;
    let totalDeducted = 0;
    const spoolsTouched = new Set();
    const nowLow = [];
    const orderLoc = orderLocationId(order, c.machines);

    /** Empty `remaining` grams out of `primary`, then out of its siblings. */
    const drawDown = (primary, remaining) => {
      const others = inventory.filter(s =>
        s.id !== primary.id && s.material === primary.material && (+s.weight || 0) > 0);
      const fallback = orderLoc ? spoolsByLocationPreference(others, orderLoc) : others;
      for (const sp of [primary, ...fallback]) {
        if (remaining <= 0) break;
        const avail = +sp.weight || 0;
        if (avail <= 0) continue;
        const take = Math.min(avail, remaining);
        drawFrom(sp, take, order, today);
        remaining -= take;
        deductedAny = true;
        totalDeducted += take;
        spoolsTouched.add(sp.id);
        if (isLowStock(sp, settings) && !nowLow.some(x => x.id === sp.id)) nowLow.push(sp);
      }
    };

    /* WHAT THE JOB OWES, AND WHAT IT ACTUALLY USED.
     *
     * The claims are the estimate: each part's grams, off the spool it was
     * assigned. `scale` is how much of that estimate the print actually got
     * through — 1 when nothing measured it, which is every job Khayt has ever
     * deducted for, so this changes nothing on its own.
     *
     * A print that stopped at 40% used about 40% of its filament, and the
     * printer is the only thing that knows. Scaling the claims rather than
     * deducting one lump keeps the split intact: each part still draws from
     * its own spool, in its own proportion.
     */
    const claims = claimsFor(order, inventory);
    const scale = scaleFor(claims, c.actualGrams);
    for (const claim of claims) {
      const grams = claim.grams * scale;
      if (grams <= 0) continue;
      drawDown(claim.spool, grams);
    }

    if (deductedAny) {
      // ONE summary, not one toast per spool. Per-spool toasts could blow the
      // toast cap and silently drop the low-stock warning, which is the only
      // part of this a shop actually needs to act on.
      const params = {
        weight: Math.round(totalDeducted), spools: spoolsTouched.size, low: nowLow.length,
      };
      notices.push({ code: nowLow.length > 0 ? 'filament_deducted_low' : 'filament_deducted', params });
      effects.push({ type: 'save' });
      if (!skipRender) effects.push({ type: 'render_inventory' });
    }

    // Consumables that are spent by the hour — glue, isopropyl, sandpaper.
    const printHrs = +order.printTime || 0;
    if (printHrs > 0) {
      consumables.forEach(item => {
        if (item.usagePerHour && item.usagePerHour > 0) {
          item.stock = Math.max(0, (item.stock || 0) - item.usagePerHour * printHrs);
          if (item.stock <= (item.minStock || 0)) {
            notices.push({ code: 'consumable_low', params: { name: item.name } });
          }
        }
      });
      effects.push({ type: 'save' });
      effects.push({ type: 'render_consumables' });
    }

    // Bought-in components of a BOM assembly. Low stock warns and never blocks:
    // the parts are already printed and the job is already finished.
    const comps = arrayOf(order.components);
    if (comps.length) {
      const assemblyQty = Math.max(1, +order.assemblyQty || 1);
      let touched = false;
      comps.forEach(comp => {
        if (!comp || !comp.consumableId) return;
        const item = consumables.find(x => x.id === comp.consumableId);
        if (!item) return;
        const draw = Math.max(0, (+comp.qtyPerUnit || 0) * assemblyQty);
        if (draw <= 0) return;
        item.stock = Math.max(0, (item.stock || 0) - draw);
        touched = true;
        if (item.stock <= (item.minStock || 0)) {
          notices.push({ code: 'consumable_low', params: { name: item.name } });
        }
      });
      if (touched) {
        effects.push({ type: 'save' });
        effects.push({ type: 'render_consumables' });
      }
    }

    // Set even when nothing was deducted: the job has had its chance, and a
    // re-completion must not get a second one.
    order.materialDeducted = true;
    return { notices, effects };
  }

  /**
   * One of every packaging item, for the box the job ships in.
   *
   * A shop with no packaging stocked is left UNFLAGGED on purpose, so the
   * deduction happens the day they stock some. Every other path here flags the
   * order and never looks again.
   */
  function deductPackaging(order, ctx) {
    const c = ctxOf(ctx);
    const consumables = arrayOf(c.consumables);
    const notices = [];
    const effects = [];

    if (order.packagingDeducted) return { notices, effects };
    const packaging = consumables.filter(x => x.isPackaging && x.stock > 0);
    if (packaging.length === 0) return { notices, effects };

    packaging.forEach(item => {
      item.stock = Math.max(0, (item.stock || 0) - 1);
      if (item.stock <= (item.minStock || 0)) {
        notices.push({ code: 'packaging_low', params: { name: item.name } });
      }
    });
    effects.push({ type: 'save' });
    effects.push({ type: 'render_consumables' });
    notices.push({ code: 'packaging_deducted', params: {} });
    order.packagingDeducted = true;
    return { notices, effects };
  }

  const api = {
    USAGE_CAP, DEFAULT_LOW_STOCK,
    isLowStock, spoolsByLocationPreference, partGramsConsumed, orderLocationId,
    deductForOrder, deductPackaging,
    claimsFor, claimedGrams, scaleFor, deductActual, restoreDrawn,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderDeduction = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
