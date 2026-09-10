'use strict';
/**
 * A machine, as the shop records it — and what picking a printer model fills in.
 *
 * The Electron editor mutates a draft through thirty separate event handlers,
 * so there is no single record to copy the way `newExpense` or `newSpool` were
 * copied. What IS a rule, and what is lifted here, is the part where a decision
 * gets made:
 *
 * * the colour a new machine gets, which is the palette by position;
 * * what picking a printer model fills in — `applySpecs`, lifted from the
 *   editor's `fillSpecs` and carrying its two hard-won rules verbatim;
 * * the nozzle block, whose threshold falls back to the material's expected
 *   life rather than to a number nobody chose.
 *
 * DOWNTIME BLOCKS are here now, and what a shop types is refused in ONE place:
 * a window missing an end, running backwards, or holding something that is not
 * a date is dropped rather than repaired. Three things read them — the band,
 * the scheduler and the delivery promise — so an unreadable one is not
 * cosmetic; it takes hours off a machine's capacity in all three.
 *
 * The printer's API and the webcam were on the not-offered list too, and the
 * Mac app offers both.
 * The reason given was that they "belong with the polling that app does not do
 * yet" — and it polls, watches, alerts, draws a band off live readings and
 * records what a finished print used. The condition kept from that sentence is
 * the one worth keeping: a screen that writes connection settings it cannot
 * test is worse than one that does not offer them. So the Mac's sheet asks the
 * real printer before the shop leaves it, and asks the real printer where its
 * camera is rather than making the shop know.
 *
 * PURE: no DOM, no clock. `KhaytNozzleWear` is consulted through the global it
 * assigns itself to, present in both apps.
 */
(function (global) {

  /** The machine palette, in order. A new machine takes the next one along. */
  const COLORS = ['#5b9cf0', '#2bb673', '#f5a623', '#ef4d5e', '#a78bfa', '#fb923c', '#34d399', '#f472b6'];

  const wear = () => (typeof global.KhaytNozzleWear !== 'undefined') ? global.KhaytNozzleWear : null;
  const num = (v, fallback) => { const n = parseFloat(v); return Number.isFinite(n) ? n : fallback; };
  const trim = (v) => String(v == null ? '' : v).trim();

  /**
   * A new machine: an id, a name, and the next colour along.
   *
   * `ctx`: `{ id, count }` — how many machines the shop already has, which is
   * what decides the colour. Two machines added in a row are two colours.
   */
  function newMachine(input, ctx) {
    const i = input || {};
    const c = ctx || {};
    const name = trim(i.name);
    if (!name) return { refused: 'name' };
    return {
      machine: {
        id: c.id,
        name,
        color: i.color || COLORS[(+c.count || 0) % COLORS.length],
      },
    };
  }

  /**
   * What picking a printer model fills in. MUTATES the machine.
   *
   * `entry` is `KhaytPrinterCatalog.toMachineSpecs(...)`.
   *
   * THE NOZZLE MATERIAL IS THE POINT OF THE CATALOG KNOWING IT. A Bambu X1C
   * ships hardened steel and a Prusa MK4S ships brass — a ten-fold difference
   * in expected life — and without it both land on the brass default, so the
   * whole printer-facts sweep changes nothing a shop can see.
   *
   * FILL AN EMPTY THRESHOLD. NEVER REWRITE ONE THAT IS SET. This used to
   * overwrite any value that MATCHED A SUGGESTION, on the theory that such a
   * value must be untouched. It is not a safe theory: a shop that deliberately
   * typed 5,000 has typed the same number brass suggests, and the old table's
   * brass default of 2,000 is still sitting in stores from before that figure
   * changed. The app cannot tell a default from a decision, so it was guessing
   * — about a maintenance setting, silently.
   */
  function applySpecs(machine, entry, name, ctx) {
    const m = machine;
    const s = entry || {};
    const c = ctx || {};
    m.printerModel = s.printerModel || name;
    m.printerModelName = name;
    if (s.vendor) m.vendor = s.vendor;
    if (s.bed) m.bed = s.bed;
    if (s.maxColors) m.maxColors = s.maxColors;
    if (s.powerDraw != null) m.powerDraw = s.powerDraw;
    // The model's name, only into an empty name field.
    if (!trim(m.name)) m.name = name;
    if (s.nozzleDiameter) m.nozzleDiameter = s.nozzleDiameter;
    if (s.extruderType) m.extruderType = s.extruderType;
    if (s.nozzle && s.nozzle.material) {
      m.nozzle = Object.assign({ installedAt: '', gramsAtInstall: 0 }, m.nozzle,
                               { material: s.nozzle.material });
      if (!(num(m.nozzle.gramsThreshold, 0) > 0)) {
        const W = wear();
        if (W) m.nozzle.gramsThreshold = W.defaultThresholdFor(s.nozzle.material, c.settings);
      }
    }
    // Carried so a machine card can offer the vendor's support page, and so the
    // checked specs are on the machine rather than only in a table.
    if (s.support) m.support = s.support;
    for (const f of ['maxHotendC', 'maxBedC', 'chamber', 'maxChamberC', 'filamentMm', 'feed', 'toolheads']) {
      if (s[f] != null) m[f] = s[f];
    }
    return m;
  }

  /**
   * What the catalog knows about a model, as one line a shop can read — and,
   * just as usefully, what it does not know.
   *
   * `labels`: `{ chamber }`, because the word is the app's, not the rule's.
   */
  function specsLine(entry, labels) {
    const s = entry || {};
    const L = labels || {};
    const bits = [];
    if (s.bed) bits.push(`${s.bed.x}×${s.bed.y}×${s.bed.z} mm`);
    if (s.nozzleDiameter) bits.push(`${s.nozzleDiameter} mm`);
    if (s.maxColors > 1) bits.push(`${s.maxColors}×`);
    if (s.powerDraw != null) bits.push(`~${s.powerDraw} W`);
    if (s.nozzle && s.nozzle.material) bits.push(s.nozzle.material);
    if (s.maxHotendC) bits.push(`${s.maxHotendC}°C`);
    if (s.chamber === 'active') bits.push(`${s.maxChamberC || '?'}°C ${L.chamber || 'chamber'}`);
    if (s.filamentMm && s.filamentMm !== 1.75) bits.push(`${s.filamentMm} mm`);
    return bits.join(' · ');
  }

  /**
   * Correct a machine. MUTATES it. Only the fields `input` carries.
   *
   * The nozzle is a block rather than four fields: a shop changing a nozzle
   * changes what it is made of, when it went in and what it had printed by
   * then, and half of that written down is a wear figure that lies.
   */
  function applyEdit(machine, input, ctx) {
    const m = machine;
    const i = input || {};
    const c = ctx || {};
    const has = (key) => Object.prototype.hasOwnProperty.call(i, key) && i[key] !== undefined;

    if (has('name')) {
      const name = trim(i.name);
      if (!name) return { refused: 'name' };
      m.name = name;
    }
    if (has('color')) m.color = i.color || COLORS[0];
    /* What kind of machine this is — filament, resin, UV flatbed, laser, CNC.
     *
     * `KhaytMachineKinds` owns the vocabulary and is asked rather than trusted:
     * a word it does not know would otherwise be written into the book and read
     * back as FDM for ever, which is a silent way to lose a shop's answer. An
     * unrecognised kind is refused into `fdm` HERE, where the value is written,
     * rather than at every screen that reads it.
     *
     * Absent leaves the machine alone: a caller editing only a nozzle must not
     * blank the kind, and every machine written before this field existed is a
     * filament printer by the module's own rule. */
    if (has('kind')) {
      const K = (typeof globalThis !== 'undefined') && globalThis.KhaytMachineKinds;
      m.kind = K ? K.kindOf({ kind: i.kind }) : (trim(i.kind) || 'fdm');
    }
    if (has('vendor')) m.vendor = trim(i.vendor) || undefined;
    if (has('nozzleDiameter')) m.nozzleDiameter = num(i.nozzleDiameter, 0) || null;
    if (has('extruderType')) m.extruderType = trim(i.extruderType) || null;
    if (has('powerDraw')) m.powerDraw = num(i.powerDraw, 0) || null;
    if (has('maxColors')) m.maxColors = Math.max(1, Math.round(num(i.maxColors, 1)));
    if (has('targetHoursPerDay')) m.targetHoursPerDay = Math.max(0, num(i.targetHoursPerDay, 0)) || null;
    if (has('locationId')) m.locationId = trim(i.locationId) || '';
    /* ── WHEN THIS MACHINE IS OUT OF ACTION ──────────────────────────────
     *
     * `downtimeBlocks` is `[{ from, to, reason }]`, and it is no longer a note
     * to itself: the band draws the window, the scheduler counts it against a
     * machine's load, and the delivery promise a storefront quotes stops
     * offering those hours. Three things read it, so what gets written matters
     * more than it did when a badge was the only consumer.
     *
     * ── LOCAL WALL-CLOCK, THE SHAPE KHAYT'S OWN MODAL WRITES ─────────────
     *
     * `YYYY-MM-DDTHH:mm`, no zone — what a `datetime-local` input produces.
     * "Thursday 2pm" is what a shop means by a maintenance window, and both
     * apps have to write one shape or a window set on the Mac and read in
     * Khayt would be a different four hours. The trap is real and is the
     * lesser one: a naive time read in another timezone moves. A shop that
     * services its printers from two continents has a better problem.
     *
     * A row missing an end, or running backwards, is DROPPED rather than
     * repaired — a maintenance window nobody can read is not one to guess at,
     * and it would otherwise silently take hours off a machine's capacity.
     */
    if (has('downtimeBlocks')) {
      const rows = Array.isArray(i.downtimeBlocks) ? i.downtimeBlocks : [];
      const clean = [];
      for (const b of rows) {
        if (!b) continue;
        const from = trim(b.from);
        const to = trim(b.to);
        if (!from || !to) continue;
        const a = new Date(from).getTime();
        const z = new Date(to).getTime();
        if (!Number.isFinite(a) || !Number.isFinite(z) || z <= a) continue;
        clean.push({ from, to, reason: trim(b.reason || b.note).slice(0, 120) });
      }
      // Oldest first, so a list a shop scrolls reads like a calendar.
      clean.sort((x, y) => new Date(x.from) - new Date(y.from));
      // A cap, because this rides in every sync and every backup of the record
      // it sits on. Fifty windows is years of servicing.
      m.downtimeBlocks = clean.slice(0, 50);
    }
    if (has('compatMaterials') && Array.isArray(i.compatMaterials)) {
      m.compatMaterials = i.compatMaterials.slice();
    }
    if (has('bed')) {
      const bed = i.bed || {};
      const x = num(bed.x, 0), y = num(bed.y, 0), z = num(bed.z, 0);
      m.bed = (x > 0 && y > 0 && z > 0) ? { x, y, z } : undefined;
    }
    /* How Khayt reaches this machine.
     *
     * ── A CREDENTIAL IS ONLY WRITTEN WHEN ONE IS SENT ──────────────────────
     *
     * `apiKey` and `accessCode` are registered secret paths
     * (`lib/store-secret-paths.js`), so what is on the record is the SEALED
     * string. A screen must never be handed the plaintext just to hand it
     * back, so a caller that is not changing the key sends nothing at all —
     * `undefined` — and what is stored is carried through untouched.
     *
     * That distinction is the whole safety of this block. Reading `a.apiKey`
     * with a `|| ''` fallback would blank a working credential every time
     * somebody corrected a typo in the host, and would do it silently.
     *
     * An empty STRING is different from absent, and means the shop cleared it.
     */
    if (has('printerApi')) {
      const a = i.printerApi || {};
      const was = m.printerApi || {};
      const port = Math.round(num(a.port, 0));
      const next = {
        type: trim(a.type),
        host: trim(a.host),
        port: port > 0 ? port : undefined,
        // Carried rather than edited: it is Bambu's, and no screen here sets it.
        printerSlug: was.printerSlug || '',
        apiKey: a.apiKey === undefined ? (was.apiKey || '') : String(a.apiKey),
        accessCode: a.accessCode === undefined ? (was.accessCode || '') : String(a.accessCode),
      };
      // Switching a printer off must not throw its credentials away — a shop
      // that unplugs a machine for a week should not have to find its key
      // again to plug it back in.
      m.printerApi = next;
    }
    if (has('nozzle')) {
      const n = i.nozzle || {};
      const material = trim(n.material) || 'brass';
      const W = wear();
      m.nozzle = {
        material,
        installedAt: n.installedAt || '',
        gramsThreshold: num(n.gramsThreshold, 0) > 0
          ? num(n.gramsThreshold, 0)
          : (W ? W.defaultThresholdFor(material, c.settings) : 0),
        gramsAtInstall: Math.max(0, num(n.gramsAtInstall, 0)),
      };
    }
    return {};
  }

  const api = { COLORS, newMachine, applySpecs, specsLine, applyEdit };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytMachineEdit = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
