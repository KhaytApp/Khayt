'use strict';
(function (global) {
/**
 * What the shop's materials cost, and whether that has moved.
 *
 * A shop quoting off last year's filament price is quoting at a loss, and
 * nothing in either app answers the question. The other app has a supplier
 * price history — which needs a suppliers list, and purchase records inside it,
 * that no shop's book here actually has. The SPOOLS do have it: every one
 * carries what it cost and what it weighed, and that is a price per kilo.
 *
 * ── PER KILO, NOT PER SPOOL ───────────────────────────────────────────────
 *
 * "75 a roll" says nothing: a roll is 500 g or 1 kg or 3 kg depending on who
 * sold it, and the whole point of the figure is to compare two of them. The
 * cost model already prices a part off `cost / weight * 1000`, so this is the
 * same arithmetic asked about the shelf instead of about a part.
 *
 * ── AND THE WEIGHT IS THE FULL SPOOL, NOT WHAT IS LEFT ────────────────────
 *
 * `weight` on a spool is what REMAINS — it goes down as the shop prints — so
 * dividing the purchase cost by it makes a half-used roll look twice as
 * expensive as the identical new one beside it. `spoolWeight` is what was
 * bought. That distinction is the whole correctness of this module.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function day(v) { return String(v == null ? '' : v).slice(0, 10); }

/**
 * What one rate unit of an item cost — a kilo of it, a litre of it, one sheet
 * of it — or null when it cannot be known.
 *
 * `inventory-units` owns this and already documents the trap: the quantity must
 * be what the item HELD WHEN IT ARRIVED, never what is left, or the figure a
 * shop compares suppliers on climbs as the item empties and is worst on exactly
 * the item about to be reordered.
 *
 * A per-KILO figure for everything would be nonsense on half the shelf: the
 * sample shop's acrylic came out at 42,000 "per kg" because a sheet is not
 * weighed. Each item is priced in its own rate unit and carries which.
 */
function rateOf(item) {
  const units = (typeof module !== 'undefined' && module.exports)
    ? require('./inventory-units.js')
    : global.KhaytInventoryUnits;
  const unit = units.unitOf(item);
  // `spoolWeight` is the filament shelf's word for "what it held when it
  // arrived"; `originalQty` is the general one. Neither is `weight`, which is
  // what is LEFT.
  const original = num(item && item.originalQty) || num(item && item.spoolWeight);
  return units.costPerRateUnit(item && item.cost, original, unit);
}

/** What a spool is made of, normalised so "PLA+ 2.0" and "PLA+" are one thing. */
function familyOf(spool) {
  const raw = String((spool && (spool.material || spool.materialType)) || '').trim();
  if (!raw) return '';
  // The grade, not the vendor's version number: a shop comparing PLA+ prices
  // does not mean to compare "PLA+ 2.0" against "PLA+ 2.1" as two materials.
  return raw.replace(/\s+v?\d+(\.\d+)*\s*$/i, '').trim() || raw;
}

/**
 * @param {object} input
 *   inventory  the shelf
 *   minimum    spools of one material before a CHANGE is claimed (default 2)
 * @param {object} deps
 *   dateOf     (spool) => when it was bought; defaults to `openedAt` then
 *              `updatedAt`, which is the best a store without a purchase date
 *              can do and is stated rather than hidden.
 * @returns {{rows: Array, totals: object}} dearest first
 */
function materialCost(input, deps) {
  const i = input || {};
  const d = deps || {};
  const dateOf = typeof d.dateOf === 'function'
    ? d.dateOf
    : (s) => day((s && s.openedAt) || (s && s.updatedAt) || '');
  const minimum = i.minimum == null ? 2 : Math.max(1, num(i.minimum));

  const byFamily = new Map();
  for (const spool of (Array.isArray(i.inventory) ? i.inventory : [])) {
    const family = familyOf(spool);
    const priced = rateOf(spool);
    // A COST OF NOUGHT IS NOT A PRICE. `inventory-units` allows one and is
    // right to — a sample roll a supplier sent for free really did cost
    // nothing — but a shop asking what PLA costs it does not mean to average
    // the free one in, and a zero would drag the figure it quotes against.
    if (!family || priced == null || !(priced.value > 0)) continue;
    if (!byFamily.has(family)) {
      byFamily.set(family, { material: family, spools: [], perUnit: 0, rate: priced.rate,
                             spoolCount: 0, earliest: null, latest: null, changePct: null });
    }
    byFamily.get(family).spools.push({ rate: priced.value, at: dateOf(spool) });
  }

  const rows = [];
  for (const row of byFamily.values()) {
    const dated = row.spools.filter((s) => s.at).sort((a, b) => a.at.localeCompare(b.at));
    row.spoolCount = row.spools.length;
    // The CURRENT rate is the most recently bought, not an average over years —
    // what a shop quotes against is what it is paying now.
    row.perUnit = dated.length ? dated[dated.length - 1].rate
                              : row.spools[row.spools.length - 1].rate;
    row.earliest = dated.length ? dated[0].at : null;
    row.latest = dated.length ? dated[dated.length - 1].at : null;
    // FIRST AGAINST LAST, not the last two. A shop buying irregularly has two
    // rolls a month apart from different sellers, and the gap between those is
    // noise rather than a trend.
    if (dated.length >= minimum && dated[0].rate > 0) {
      row.changePct = ((dated[dated.length - 1].rate - dated[0].rate) / dated[0].rate) * 100;
    }
    delete row.spools;
    rows.push(row);
  }

  // Dearest first WITHIN a rate unit is not comparable across them — a sheet
  // and a kilo are different things — so the sort is by material name inside
  // each unit, with the units themselves grouped.
  rows.sort((a, b) => a.rate.localeCompare(b.rate)
                      || b.perUnit - a.perUnit
                      || a.material.localeCompare(b.material));

  const moved = rows.filter((r) => r.changePct != null);
  return {
    rows,
    totals: {
      materials: rows.length,
      /// The one that has risen most, and only where there is enough history
      /// for "risen" to mean anything.
      steepest: moved.filter((r) => r.changePct > 0)
        .sort((a, b) => b.changePct - a.changePct)[0] || null,
      dearest: rows[0] || null,
      /// Nothing has enough history to compare — a thing to say, not an empty
      /// column of dashes.
      anyChangeKnown: moved.length > 0,
    },
  };
}

const api = { materialCost, rateOf, familyOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMaterialCost = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
