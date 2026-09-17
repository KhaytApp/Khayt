'use strict';

/**
 * What a supplier's prices may be compared against.
 *
 * A purchase in Khayt records an amount, a quantity and a **unit** the shop
 * picked from a list: spool, kg, g, L, piece, roll, box. The material type is
 * free text, so the same word — "PLA" — is attached to a spool bought for 75
 * and, a month later, a kilogram bought for 22.
 *
 * The supplier price history chart put both of those on one trend line,
 * badged the move between them as a price change, and then named a "best
 * price" supplier by sorting the mixed numbers. All three are meaningless. The
 * shop that sells by the gram always wins a comparison against the shop that
 * sells by the spool, and a shop that switches from grams to kilos is told its
 * PLA got a thousand times more expensive.
 *
 * Two prices are comparable when they measure the same thing. That is the
 * whole rule, and it has two halves:
 *
 *   1. Units fall into **families**. `g` and `kg` are both mass, so a price in
 *      one converts into the other exactly. A spool is not a mass — spools
 *      hold different amounts — so `spool` is its own family and converts to
 *      nothing. Same for a piece, a roll, a box and a litre.
 *
 *   2. Within a family, prices convert to the family's **base unit** before
 *      anything is compared, plotted or ranked.
 *
 * So the chart groups by material *and* family, not by material alone. A shop
 * that buys PLA both ways sees two cards, each honest, instead of one that is
 * wrong.
 *
 * Deliberately NOT here: a spool-to-kilogram conversion via an assumed spool
 * weight. A 1kg spool and a 250g sample spool are both "a spool", and guessing
 * which one a purchase meant would put a fabricated number in front of a
 * buying decision. Unconvertible is the correct answer, not a gap to fill.
 *
 * The caller supplies the label for untagged material, because that is a
 * translated string and this module holds no text.
 */
(function (global) {

  /**
   * Unit spellings that mean the same unit.
   *
   * The purchase form offers a fixed list, so in a book written by one machine
   * every unit is already canonical. Books merge across devices and across
   * versions of the app, and a unit typed by an importer or an older build is
   * still a unit, so the aliases are cheap insurance against a stray "Kg"
   * opening a second card for the same material.
   */
  const ALIASES = {
    g: 'g', gram: 'g', grams: 'g', gm: 'g', gs: 'g',
    kg: 'kg', kgs: 'kg', kilo: 'kg', kilos: 'kg', kilogram: 'kg', kilograms: 'kg',
    l: 'L', liter: 'L', liters: 'L', litre: 'L', litres: 'L',
    spool: 'spool', spools: 'spool',
    roll: 'roll', rolls: 'roll',
    piece: 'piece', pieces: 'piece', pcs: 'piece', pc: 'piece',
    box: 'box', boxes: 'box',
  };

  /**
   * How a unit converts within its family.
   *
   * `base` is the unit every price in the family is expressed in before it is
   * compared, and `per` is how many base units one of this unit is. A price is
   * currency *per unit*, so converting it divides rather than multiplies:
   * 0.02 per gram is 0.02 / 0.001 = 20 per kilogram.
   *
   * A unit absent from this table is its own family and converts to itself,
   * which is what makes an unrecognised unit safe: it is never mixed with
   * anything, including another unrecognised one spelled differently.
   */
  const CONVERSIONS = {
    g: { base: 'kg', per: 0.001 },
    kg: { base: 'kg', per: 1 },
  };

  /** The unit a purchase is assumed to be in when it records none. */
  const DEFAULT_UNIT = 'spool';

  /**
   * Fold a recorded unit onto its canonical spelling.
   *
   * An empty or missing unit becomes the default rather than a family of its
   * own, because a book written before the unit field existed holds purchases
   * that were all spools.
   */
  function normalizeUnit(unit) {
    const raw = String(unit == null ? '' : unit).trim();
    if (!raw) return DEFAULT_UNIT;
    const hit = ALIASES[raw.toLowerCase()];
    return hit || raw;
  }

  /** The unit that prices in this unit's family are compared in. */
  function baseUnit(unit) {
    const u = normalizeUnit(unit);
    return (CONVERSIONS[u] || {}).base || u;
  }

  /**
   * Convert a price per `unit` into a price per its family's base unit.
   *
   * Returns the price unchanged for any unit that is its own base, which is
   * every unit except `g`.
   */
  function toBasePrice(price, unit) {
    const u = normalizeUnit(unit);
    const conv = CONVERSIONS[u];
    const p = +price || 0;
    if (!conv || !conv.per) return p;
    return p / conv.per;
  }

  /**
   * What one of something cost.
   *
   * An explicitly recorded unit price wins; otherwise the amount is spread
   * over the quantity. This is the rule the chart used to reach into the
   * renderer's `computeUnitPrice` for; having it here is what lets a host
   * without a renderer, the Mac app, reach the same figure. `computeUnitPrice`
   * stays where it is as an exported helper, and `test/supplier-prices.test.js`
   * holds the two to each other so they cannot drift apart.
   */
  function unitPriceOf(purchase) {
    const p = purchase || {};
    if (p.unitPrice && +p.unitPrice > 0) return +p.unitPrice;
    const qty = +p.quantity || 1;
    return (+p.amount || 0) / qty;
  }

  /**
   * Every purchase across every supplier, grouped into comparable sets.
   *
   * One group per material *and* base unit, sorted by material then unit so
   * the same book always draws the same order. Each group carries:
   *
   *   - `entries`  — every purchase in it, price converted to `unit`, sorted
   *                  oldest first by date. Undated purchases keep their place
   *                  in `all` but are left out of `entries`, because a trend
   *                  line cannot place a point with no date on it.
   *   - `all`      — every purchase in the group including the undated ones,
   *                  which is what `count`, `best` and `worst` are drawn from.
   *   - `pctChange`— the move from the second-newest dated purchase to the
   *                  newest, now necessarily a like-for-like comparison.
   *
   * `opts.untagged` labels purchases with no material type.
   */
  function groups(suppliers, opts) {
    const options = opts || {};
    const untagged = options.untagged || 'Untagged';
    const bins = new Map();

    (suppliers || []).forEach(sup => {
      const supplier = (sup && sup.name) || '';
      ((sup && sup.purchases) || []).forEach(p => {
        const material = String((p && p.materialType) || '').trim() || untagged;
        const unit = normalizeUnit(p && p.unit);
        const base = baseUnit(unit);
        const key = JSON.stringify([material, base]);
        if (!bins.has(key)) bins.set(key, { material, unit: base, all: [] });
        bins.get(key).all.push({
          date: (p && p.date) || '',
          price: toBasePrice(unitPriceOf(p), unit),
          unit: base,
          recordedUnit: unit,
          supplier,
          total: +(p && p.amount) || 0,
        });
      });
    });

    const out = Array.from(bins.values());
    out.sort((a, b) => (a.material.localeCompare(b.material)) || (a.unit.localeCompare(b.unit)));

    return out.map(g => {
      const entries = g.all.filter(e => e.date).slice()
        .sort((a, b) => a.date.localeCompare(b.date));
      const byPrice = g.all.slice().sort((a, b) => a.price - b.price);
      const last = entries[entries.length - 1] || null;
      const prev = entries[entries.length - 2] || null;
      const pctChange = (prev && prev.price)
        ? ((last.price - prev.price) / prev.price) * 100
        : 0;
      return {
        material: g.material,
        unit: g.unit,
        entries,
        all: g.all,
        count: g.all.length,
        latest: last,
        previous: prev,
        pctChange,
        best: byPrice[0] || null,
        worst: byPrice[byPrice.length - 1] || null,
        /** True when the group holds more than one spelling of its base unit. */
        converted: g.all.some(e => e.recordedUnit !== e.unit),
      };
    });
  }

  const api = {
    DEFAULT_UNIT, ALIASES, CONVERSIONS,
    normalizeUnit, baseUnit, toBasePrice, unitPriceOf, groups,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSupplierPrices = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
