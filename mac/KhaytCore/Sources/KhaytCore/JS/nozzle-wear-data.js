'use strict';

/**
 * How long a nozzle lasts, and what wears it out — with sources.
 *
 * ── Why this file exists at all ──────────────────────────────────────────────
 * The first version of the wear model carried a table of numbers that were not
 * checked against anything. They were plausible, they were labelled "rules of
 * thumb", and they were invented. Two of them were WRONG IN A DIRECTION THAT
 * MATTERS, and finding out took one afternoon of reading published tests:
 *
 *   Glow-in-the-dark was rated the most abrasive filament there is, above
 *   carbon fibre. CNC Kitchen pushed 330 g of glow PLA through a cheap brass
 *   nozzle and measured NO CHANGE in orifice diameter. It is mild.
 *
 *   Brass was given 2 kg of life. Published figures for plain PLA and PETG run
 *   from 3 kg to nearly 20 kg. The old default would have told a shop printing
 *   ordinary filament to bin a perfectly good nozzle, repeatedly.
 *
 * So every number below now carries where it came from, and the ones that are
 * still guesses SAY SO in the same field. `estimated: true` is not decoration —
 * it is what the UI reads to mark a row as unverified, and what a shop needs in
 * order to know which figures are worth arguing with.
 *
 * ── On the spread ───────────────────────────────────────────────────────────
 * Published measurements disagree by an ORDER OF MAGNITUDE, and not because
 * anyone is wrong. E3D found significant, microscope-visible degradation of a
 * brass nozzle after 250 g of carbon-filled PETG; other sources put brass at
 * 1–2 kg of the same class of filament. Both are true — they are answering
 * "when is this measurably worn" and "when do prints stop being acceptable",
 * which for a shop selling parts are months apart.
 *
 * These defaults sit between the two and are deliberately EDITABLE. A shop's
 * own filament, flow rate and tolerance for dimensional drift decide the real
 * figure, and nothing in this file can know those. See `settings.nozzleWear`
 * for the override path and docs/NOZZLE-WEAR.md for the full dated table.
 *
 * Pure: no network, no fs, no Electron.
 *
 * Wrapped in an IIFE because the renderer loads lib/ modules with plain
 * <script> tags into ONE shared global scope, where a top-level `const api`
 * collides with every other module that has one.
 */
(function (global) {

  const CHECKED_ON = '2026-08-30';

  const SOURCES = {
    e3d: {
      name: 'E3D — Are Abrasives Killing Your Nozzle?',
      url: 'https://e3d-online.com/blogs/news/are-abrasives-killing-your-nozzle',
      what: 'Microscope study. 250 g of ColorFabb XT-CF20 through a 0.40 mm brass nozzle '
          + 'left deep gouging, a rounded-over tip and a measurably enlarged orifice. The same '
          + 'class of filament left ZERO observable wear on hardened steel at 2.5 kg — ten times '
          + 'the brass test. Stainless is put at roughly 30% the wear rate of brass.',
    },
    cnckitchen: {
      name: 'CNC Kitchen — How much abrasive filaments damage your nozzle',
      url: 'https://www.cnckitchen.com/blog/how-much-abrasive-filaments-damage-your-nozzle',
      what: 'Controlled extrusion through cheap brass. 330 g of glow-in-the-dark PLA (DAS '
          + 'FILAMENT): no measurable change in orifice diameter, print quality matched the '
          + 'control. 360 g of carbon-fibre PETG (XT-CF20): orifice barely widened but the TIP '
          + 'was severely worn away, so first-layer thickness drifted as the nozzle shortened.',
    },
    imd: {
      name: 'Industrial Monitor Direct — Hardened nozzle selection for CF and GF printing',
      url: 'https://industrialmonitordirect.com/blogs/knowledgebase/hardened-nozzle-selection-for-carbon-fiber-and-glass-fiber-3d-printing',
      what: 'Puts brass at 1–2 kg of carbon- or glass-filled filament, and reports glass-filled '
          + 'nylon destroying a brass nozzle after only 100 g.',
    },
    prusa: {
      name: 'Prusa forum — Lifetime of a nozzle / brass nozzle wear',
      url: 'https://forum.prusa3d.com/forum/english-forum-general-discussion-announcements-and-releases/lifetime-of-a-nozzle-2/',
      what: 'Field reports rather than measurement: 3–4 kg of PLA a month wearing out 2–3 brass '
          + 'nozzles a year (≈14–19 kg each), and PETG widening a brass bore after roughly 3–5 kg.',
    },
    uavmodel: {
      name: 'UAVMODEL — Nozzle comparison: brass vs hardened vs ruby vs tungsten carbide',
      url: 'https://blog.uavmodel.com/3d-printer-nozzle-comparison-brass-vs-hardened-steel-vs-ruby-vs-tungsten-carbide-wear-flow-and-application-2026/',
      what: 'Lifespans in months rather than grams: on non-abrasive filament brass 6–12 months, '
          + 'hardened and stainless 2+ years, ruby 3+ years, tungsten carbide 5+ years. On '
          + 'abrasives, brass is given "2–3 prints".',
    },
  };

  /**
   * Grams of NON-ABRASIVE filament before a nozzle is worth checking.
   *
   * Anchored on the tightest sourced non-abrasive figure there is: PETG widening a
   * brass bore at 3–5 kg. PLA runs far longer — the same reports put it near 15 kg
   * — so 5,000 is the pessimistic end of ordinary printing rather than the middle.
   * A shop that prints only PLA should raise it, and the UI says so.
   */
  const NOZZLE_LIFE_G = {
    brass: {
      grams: 5000,
      label: 'Brass',
      source: 'prusa',
      note: 'PETG widens a brass bore at ~3–5 kg; PLA reports run to ~15 kg. Set to the harsher of the two.',
    },
    stainless: {
      grams: 15000,
      label: 'Stainless steel',
      source: 'e3d',
      note: 'E3D puts stainless at roughly 30% the wear rate of brass, so ~3× the life.',
    },
    hardened: {
      grams: 50000,
      label: 'Hardened steel',
      source: 'e3d',
      note: 'Zero observable wear at 2.5 kg of carbon/glass-filled — ten times the amount that visibly damaged brass.',
    },
    ruby: {
      grams: 150000,
      label: 'Ruby tip',
      source: 'uavmodel',
      note: 'Reported at 3+ years against brass at 6–12 months on the same filament. The body gives up before the tip.',
    },
    tungsten: {
      grams: 250000,
      label: 'Tungsten carbide',
      source: 'uavmodel',
      note: '5+ years. In practice this is "replace the printer first".',
    },
    other: {
      grams: 5000,
      label: 'Other / unknown',
      source: null,
      estimated: true,
      note: 'An unknown fitment is assumed to be as soft as brass. Guessing generously would quietly extend a nozzle nobody has described.',
    },
  };

  /**
   * How many grams of wear one gram of filament causes, relative to unfilled.
   *
   * Matched in order, so the ones that must win go first — a spool labelled
   * "PLA-CF Glow" has to land on carbon fibre, which is the worse of the two by
   * measurement even though intuition says otherwise.
   */
  const ABRASIVE_CLASSES = [
    {
      key: 'glass',
      label: 'Glass-filled',
      multiplier: 15,
      pattern: /\bgf\b|glass[\s-]?fill|glass[\s-]?fib|fibregl|fiberg/i,
      source: 'imd',
      note: 'Reported destroying a brass nozzle after 100 g — the harshest figure found for any common filament.',
    },
    {
      key: 'carbon',
      // `carbon` unanchored matches polyCARBONate, which is not abrasive at all,
      // merely hot. That would have told every PC-printing shop its nozzle was
      // wearing 10× too fast. Caught by a test, not by re-reading the regex.
      label: 'Carbon-filled',
      multiplier: 10,
      pattern: /\bcarbon\b|carbon[\s-]?fib|\bcf\b|\bcf-|-cf\b/i,
      source: 'e3d',
      note: 'E3D saw significant wear at 250 g; other sources say 1–2 kg. 10× sits between them — 500 g on brass.',
    },
    {
      key: 'metal',
      label: 'Metal-filled',
      multiplier: 5,
      pattern: /metal[\s-]?fill|bronze|copper[\s-]?fill|\bsteel[\s-]?fill|iron[\s-]?fill|\bmagnet/i,
      source: null,
      estimated: true,
      note: 'No controlled test found. Placed below carbon fibre because the particles are softer than the nozzle in a way carbon fibre is not.',
    },
    {
      key: 'glow',
      label: 'Glow in the dark',
      multiplier: 3,
      pattern: /glow|gitd|luminous/i,
      source: 'cnckitchen',
      note: 'Measured NO orifice change after 330 g through cheap brass. Kept above 1× because filler loads vary hugely by brand, but it is nothing like carbon fibre.',
    },
    {
      key: 'ceramic',
      label: 'Marble / stone / ceramic-filled',
      multiplier: 3,
      pattern: /marble|stone|ceram|granite/i,
      source: null,
      estimated: true,
      note: 'No controlled test found. Grouped with glow because the filler is a hard mineral powder rather than a fibre.',
    },
    {
      key: 'sparkle',
      label: 'Glitter / sparkle',
      multiplier: 2,
      pattern: /sparkl|glitter|\bsand\b/i,
      source: null,
      estimated: true,
      note: 'No controlled test found. Widely described as mildly abrasive.',
    },
    {
      key: 'wood',
      label: 'Wood-filled',
      multiplier: 2,
      pattern: /wood|bamboo|cork/i,
      source: null,
      estimated: true,
      note: 'No controlled test found. Wood-fill is usually reported as a clogging problem rather than a wear one.',
    },
  ];

  const api = { CHECKED_ON, SOURCES, NOZZLE_LIFE_G, ABRASIVE_CLASSES };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytNozzleWearData = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
