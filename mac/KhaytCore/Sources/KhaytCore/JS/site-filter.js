'use strict';
/**
 * Which jobs, machines and spools a screen shows when the shop narrows it to
 * one of its sites (KhaytSiteFilter).
 *
 * A shop with two branches looks at one of them at a time: the board, the
 * jobs, the machines and the stock of the branch it is standing in. The rule
 * for what belongs to a branch is the desktop's, lifted out of
 * renderer/ops-locations.js (`orderMatchesActiveLocation`,
 * `machineMatchesActiveLocation`) and renderer/inventory.js
 * (`spoolMatchesLocation`, `filterInventoryByLocation`,
 * `perLocationLowStockCounts`) so the Mac narrows by the same answer:
 *
 *   - No site chosen → everything.
 *   - Something with no site → shown at every site. A job nobody has put on a
 *     machine yet, a spool from before the shop had branches: hiding those
 *     under every filter would lose them.
 *   - Otherwise → only its own site's.
 *
 * Where a JOB is, is lib/location-pl.js `orderLocationId` — its own site, else
 * its machine's — the rule the per-location P&L and the stock deduction use,
 * so the board and the money agree about which branch a job belongs to.
 *
 * ── ONE THING THE DESKTOP GOT WRONG ───────────────────────────────────────
 *
 * A SITE THAT NO LONGER EXISTS HID THINGS FROM EVERY SITE. The renderer
 * compared ids as they stood, so a job, machine or spool still naming a
 * deleted location (left by a delete before #1764 cleared pointers, or by a
 * sync from a computer that still had it) matched no site at all: invisible
 * under every filter, visible only with "All sites". Given the shop's
 * `locations`, an id that names none of them is now what it is — no site —
 * and is shown everywhere, the way location-pl.js already counts it as
 * unassigned. Without `locations` the ids are trusted as they stand, which is
 * exactly the old behaviour and what the desktop's own tests call.
 *
 * Pure; no DOM, no I/O. Shared by the desktop and, bundled, the Mac.
 */
(function (global) {
  const LP = () => (typeof require === 'function' ? require('./location-pl.js') : global.KhaytLocationPl);
  const str = (v) => (v == null ? '' : String(v));
  const arr = (v) => (Array.isArray(v) ? v : []);

  /** The shop's location ids, or null when the caller did not say. */
  function knownIds(locations) {
    if (!Array.isArray(locations)) return null;
    return new Set(locations.filter((l) => l && l.id).map((l) => str(l.id)));
  }

  /** `id` as a site, or null when it names none (or there is no id). */
  function siteOf(id, known) {
    const s = str(id);
    if (!s) return null;
    return !known || known.has(s) ? s : null;
  }

  /**
   * The site a filter is really narrowed to: the chosen id when the shop still
   * has that location, else none — a filter naming a deleted site shows all,
   * as the desktop's restore does with a stale session value.
   */
  function activeSite(active, locations) {
    const known = knownIds(locations);
    return siteOf(active, known);
  }

  function orderMatches(order, active, ctx) {
    const c = ctx || {};
    const known = knownIds(c.locations);
    const site = siteOf(active, known);
    if (!site) return true;
    const loc = LP().orderLocationId(order, arr(c.machines), known);
    if (!loc) return true;
    return loc === site;
  }

  function machineMatches(machine, active, locations) {
    const known = knownIds(locations);
    const site = siteOf(active, known);
    if (!site) return true;
    const loc = siteOf(machine && machine.locationId, known);
    if (!loc) return true;
    return loc === site;
  }

  function spoolMatches(item, active, locations) {
    const known = knownIds(locations);
    const site = siteOf(active, known);
    if (!site) return true;
    const loc = siteOf(item && item.locationId, known);
    if (!loc) return true;
    return loc === site;
  }

  function filterInventory(items, active, locations) {
    if (!Array.isArray(items)) return [];
    if (!siteOf(active, knownIds(locations))) return items.slice();
    return items.filter((it) => spoolMatches(it, active, locations));
  }

  /**
   * Low stock per site: `{ [locationId]: n, _unassigned: n }`. A spool naming
   * a deleted site is counted as unassigned when `locations` is given.
   */
  function perLocationLowStockCounts(items, isLow, locations) {
    const known = knownIds(locations);
    const out = {};
    for (const it of arr(items)) {
      if (!isLow(it)) continue;
      const key = siteOf(it && it.locationId, known) || '_unassigned';
      out[key] = (out[key] || 0) + 1;
    }
    return out;
  }

  /**
   * Everything one filter shows, as ids — what a host that filters
   * synchronously (the Mac's views) asks once per change of book or filter.
   *
   * @param {{orders?:object[], machines?:object[], inventory?:object[], locations?:object[]}} book
   * @param {string|null} active the chosen location id, or none
   * @returns {{active: string|null, name: string, orderIds: string[], machineIds: string[],
   *            spoolIds: string[], total: {orders:number, machines:number, spools:number}}}
   */
  function scope(book, active) {
    const b = book || {};
    const locations = arr(b.locations);
    const site = activeSite(active, locations);
    const orders = arr(b.orders).filter((o) => o && o.id);
    const machines = arr(b.machines).filter((m) => m && m.id);
    const spools = arr(b.inventory).filter((s) => s && s.id);
    const ctx = { machines, locations };
    const loc = site ? locations.find((l) => str(l.id) === site) : null;
    return {
      active: site,
      name: loc ? str(loc.name) : '',
      orderIds: orders.filter((o) => orderMatches(o, site, ctx)).map((o) => str(o.id)),
      machineIds: machines.filter((m) => machineMatches(m, site, locations)).map((m) => str(m.id)),
      spoolIds: spools.filter((s) => spoolMatches(s, site, locations)).map((s) => str(s.id)),
      total: { orders: orders.length, machines: machines.length, spools: spools.length },
    };
  }

  const api = {
    activeSite, orderMatches, machineMatches, spoolMatches,
    filterInventory, perLocationLowStockCounts, scope,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.KhaytSiteFilter = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
