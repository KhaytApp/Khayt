'use strict';
/**
 * Printer facts that are CHECKED, layered over the bundled catalog.
 *
 * lib/printer-catalog.js is a curated list whose bed sizes, power figures and
 * extruder types were written from general knowledge and cite nothing. Most of
 * it is fine. Two parts of it were not, and both mattered:
 *
 *   `extruder` had exactly two values, 'direct' and 'bowden'. A toolchanger is
 *   neither. The Snapmaker U1 — four toolheads, five-second swaps — was recorded
 *   as "direct", and so was the Prusa XL, which carries up to five independent
 *   toolheads each with its own hotend. Anyone reading the field to decide how a
 *   machine behaves was reading a wrong answer confidently.
 *
 *   There was no nozzle material at all, which is the field the wear model in
 *   lib/nozzle-wear.js needs most. A Bambu X1C ships hardened steel and a Prusa
 *   MK4S ships brass — a TEN-fold difference in expected life — and both were
 *   getting the same default.
 *
 * So this file adds only what has been looked up, and every entry names where it
 * came from. Anything absent here stays absent rather than being guessed: a
 * missing nozzleMaterial means the shop is asked, which is honest, while an
 * invented one silently sets a maintenance threshold nobody chose.
 *
 * THE CATALOG IS A DEFAULT, NEVER A CONSTRAINT. Everything here lands in the
 * machine editor as a starting value the shop can overwrite — picking a model
 * fills the form, it does not lock it. A shop that has fitted a hardened nozzle
 * to its A1 says so and the wear model follows.
 *
 * Pure: no network, no fs, no Electron.
 */
(function (global) {

  const CHECKED_ON = '2026-08-30';

  const SOURCES = {
    bambuNozzles: {
      name: 'Bambu Lab wiki — Introduction to Bambu Nozzles',
      url: 'https://wiki.bambulab.com/en/filament-acc/acc/nozzles',
      what: 'X1 Carbon ships a 0.4 mm hardened steel nozzle; P1S, A1 and A1 mini ship '
          + '0.4 mm stainless steel as the factory default.',
    },
    prusaNozzles: {
      name: 'Prusa Knowledge Base — Different nozzle types',
      url: 'https://help.prusa3d.com/article/different-nozzle-types_2193',
      what: 'Prusa FFF printers ship with a brass nozzle; the MK4S, CORE One and XL ship '
          + 'CHT brass on the Nextruder. Brass "wears too quickly" with abrasives.',
    },
    prusaXL: {
      name: 'Prusa — Original Prusa XL 5-toolhead',
      url: 'https://www.prusa3d.com/en/product/original-prusa-xl-assembled-5-toolhead-3d-printer/',
      what: 'The XL is an active toolchanger expandable to five toolheads, each a complete '
          + 'print head with its own hotend and nozzle.',
    },
    snapmakerU1: {
      name: 'Snapmaker — U1 Toolchanger 3D Printer',
      url: 'https://www.snapmaker.com/en-US/snapmaker-u1',
      what: 'Four toolheads with a five-second toolchange, 270×270×270 mm. Toolheads are '
          + 'fitted with stainless steel nozzles.',
    },
    crealityK2: {
      name: 'Creality — K2 Plus Unicorn nozzle',
      url: 'https://crealitysg.com/products/creality-k2-plus-nozzle',
      what: 'The stock K2 Plus "Unicorn" nozzle is a copper-alloy body with a hardened '
          + 'steel tip — Creality documents a hardened-steel tip in its replacement guide.',
    },
    elegooCC: {
      name: 'Elegoo — Centauri Carbon nozzle kits',
      url: 'https://us.elegoo.com/products/multi-size-brass-hardened-steel-nozzle-kit-for-centauri-carbon-series',
      what: 'The Centauri Carbon ships a standard 0.4 mm brass nozzle; hardened steel is '
          + 'sold as the abrasive-filament upgrade.',
    },
    bambuSpecs: {
      name: 'Bambu Lab specs, cross-checked against the Polymaker printer wiki',
      url: 'https://wiki.polymaker.com/the-basics/3d-printers/popular-printers/bambu-lab',
      what: 'Nozzle 300 °C and bed 100 °C across X1C, P1S and A1; A1 mini bed 80 °C. '
          + 'X1C and P1S have a passively heated chamber reaching roughly 50 °C; the A1 line '
          + 'is open-frame. H2D: 350 °C nozzle, 120 °C bed, actively heated chamber to 65 °C. '
          + 'NOTE: this table disagrees with Bambu\'s own wiki twice — it calls the P1S nozzle '
          + 'hardened (Bambu says stainless) and gives the X1E the H2D\'s build volume. The '
          + 'vendor wins on both; only the figures above are taken from here.',
    },
    prusaMK4S: {
      name: 'Prusa — Original Prusa MK4S product page',
      url: 'https://www.prusa3d.com/product/original-prusa-mk4s-3d-printer/',
      what: '250×210×220 mm, nozzle to 290 °C, heatbed to 120 °C, 1.75 mm filament, layer '
          + '0.05–0.30 mm, Ethernet + optional ESP Wi-Fi, 80 W on PLA and 120 W on ABS. '
          + 'Stock nozzle: high-flow Prusa CHT brass 0.4 mm.',
    },
    prusaXLspec: {
      name: 'Prusa — Original Prusa XL, 5 toolhead',
      url: 'https://www.prusa3d.com/en/product/original-prusa-xl-assembled-5-toolhead-3d-printer/',
      what: '360×360×360 mm, nozzle to 290 °C, heatbed to 120 °C, 1.75 mm filament, up to five '
          + 'independent toolheads with automatic changing, 235 W printing PETG, brass stock '
          + 'nozzle. Chamber reaches 50 °C with the optional enclosure, 60 °C with a heater.',
    },
    prusaCoreOne: {
      name: 'Prusa CORE One — technical specifications',
      url: 'https://www.prusa3d.com/product/prusa-core-one/',
      what: '250×220×270 mm, nozzle to 290 °C, heatbed to 120 °C, actively heated chamber to '
          + '55 °C.',
    },
    bambuA1pdf: {
      name: 'Bambu Lab — A1 specification sheet (PDF)',
      url: 'https://cdn.shopify.com/s/files/1/0635/8247/0318/files/A1_Spec_EN_1.pdf',
      what: 'The vendor\'s own sheet: 256³ mm, STAINLESS STEEL nozzle, 300 °C hot end, '
          + '100 °C plate, 1.75 mm filament, 500 mm/s toolhead, 10 000 mm/s² acceleration. '
          + 'Settles the stainless-vs-hardened disagreement in Bambu\'s favour.',
    },
    crealityK1Max: {
      name: 'Creality — K1 Max product page',
      url: 'https://www.creality.com/products/creality-k1-max-3d-printer',
      what: '300×300×300 mm, nozzle to 300 °C, bed to 120 °C, up to 600 mm/s.',
    },
    polymakerCreality: {
      name: 'Polymaker printer wiki — Creality (SECONDARY)',
      url: 'https://wiki.polymaker.com/the-basics/3d-printers/popular-printers/creality',
      what: 'Aggregated table: K2 Plus 350 °C nozzle / 120 °C bed / actively heated chamber '
          + 'to 60 °C; Ender-3 V3 SE 260 °C / 110 °C, unheated. Treated as SECONDARY — the '
          + 'same wiki\'s Bambu table got two facts wrong, so build volumes are NOT taken '
          + 'from here, only temperatures, and only where nothing better was found.',
    },
    qidiPlus4: {
      name: 'QIDI — Plus4 technical specifications',
      url: 'https://qidi3d.com/pages/qidi-plus-4-techspecs',
      what: '305×305×280 mm CoreXY, 370 °C integrated nozzle, 120 °C bed with double-sided '
          + 'PEI, actively heated chamber to 65 °C, up to 600 mm/s.',
    },
    sovolSV: {
      name: 'Sovol — SV08 / SV06 product pages and support forum',
      url: 'https://www.sovol3d.com/products/sovol-sv08-3d-printer',
      what: 'SV08: nozzle to 300 °C, bed to 100 °C, CoreXY to 700 mm/s. SV06: nozzle ≤300 °C, '
          + 'bed ≤100 °C, 220×220×250 mm all-metal direct drive.',
    },
    flsunV400: {
      name: 'FLSUN — V400 detailed specifications',
      url: 'https://store.flsun3d.com/blogs/news/flusn-v400-more-detailed-specifications',
      what: 'Delta, 300×300×410 mm, direct extruder to 300 °C, hotbed to 110 °C, up to '
          + '600 mm/s at 10 000 mm/s².',
    },
    ultimakerS: {
      name: 'UltiMaker S5 / S3 specifications',
      url: 'https://www.wevolver.com/specs/ultimaker-s5',
      what: 'S5 330×240×300 mm, S3 230×190×200 mm, both 180–280 °C nozzle and — the fact '
          + 'that catches people out — 2.85 mm filament, not 1.75 mm.',
    },
    elegooCentauri: {
      name: 'Elegoo — Centauri Carbon',
      url: 'https://us.elegoo.com/products/multi-size-brass-hardened-steel-nozzle-kit-for-centauri-carbon-series',
      what: 'Enclosed CoreXY, 256×256×256 mm, 320 °C nozzle, brass 0.4 mm stock with hardened '
          + 'steel sold as the abrasive upgrade.',
    },
    raise3dPro3: {
      name: 'Raise3D Pro3 specifications',
      url: 'https://www.raise3d.com/pro3-hs-series-ad-version/',
      what: 'Dual extrusion to 300 °C, 1.75 mm filament, enclosed chamber with an air-flow '
          + 'manager and HEPA filtration.',
    },
    elegooSaturn4U: {
      name: 'Elegoo — Saturn 4 Ultra official page',
      url: 'https://www.elegoo.com/pages/elegoo-saturn-4-ultra',
      what: '10-inch 12K mono LCD at 11520×5120, XY 19×24 µm, build 218.88×122.88×220 mm, '
          + '405 nm COB light source with a Fresnel collimating lens, up to 150 mm/h.',
    },
    elegooMars5U: {
      name: 'Elegoo — Mars 5 Ultra',
      url: 'https://us.elegoo.com/products/mars-5-ultra-9k-7inch-monochrome-lcd-resin-3d-printer',
      what: '7-inch 9K mono LCD, XY 18×18 µm, build 153.36×77.76×165 mm, up to 150 mm/h.',
    },
    anycubicM5s: {
      name: 'Anycubic — Photon Mono M5s',
      url: 'https://store.anycubic.com/products/photon-mono-m5s',
      what: '10.1-inch 12K mono LCD at 11520×5120, XY 19 µm, build 218×123×200 mm, '
          + 'levelling-free.',
    },
    anycubicM3: {
      name: 'Anycubic — Photon M3 series',
      url: 'https://store.anycubic.com/collections/3d-printers',
      what: '9.25-inch 6K LCD, XY 34 µm, build 197×122×245 mm for the M3 series.',
    },
    anycubicKobra3: {
      name: 'Anycubic Kobra 3 series',
      url: 'https://wiki.anycubic.com/en/fdm-3d-printer/kobra-3-combo/faq',
      what: 'Kobra 3: extrusion to 300 °C, bed to 110 °C, ACE Pro multi-colour unit. The '
          + 'Kobra 2 line is lower: 260 °C nozzle and 90 °C bed on the Kobra 2 Max.',
    },
    elegooNeptune4: {
      name: 'Elegoo — Neptune 4 / 4 Pro',
      url: 'https://www.elegoo.com/products/elegoo-neptune-4-pro-fdm-3d-printer',
      what: '300 °C high-temperature hotend with an extended melt zone, rated for PLA, PETG, '
          + 'ABS, ASA, TPU and nylon.',
    },
    sovolSV07: {
      name: 'Sovol SV07 specifications',
      url: 'https://simplyprint.io/compatibility/sovol-sv07',
      what: 'Klipper direct drive, nozzle to 300 °C, bed to 100 °C.',
    },
    qidiX3: {
      name: 'QIDI X-Max 3 / X-Plus 3',
      url: 'https://us.qidi3d.com/products/qidi-x-max-3',
      what: 'Both take 350 °C nozzles with an integrated heated chamber to 65 °C. X-Max 3 is '
          + '325×325×315 mm at up to 600 mm/s.',
    },
    flsunS1: {
      name: 'FLSUN S1 specifications',
      url: 'https://simplyprint.io/compatibility/flsun-s1',
      what: 'Delta, 320 mm diameter × 430 mm, all-metal hotend to 350 °C, claimed 1200 mm/s '
          + 'at up to 40 000 mm/s².',
    },
    snapmakerJ1: {
      name: 'Snapmaker — J1 / J1s specifications',
      url: 'https://support.snapmaker.com/hc/en-us/articles/9773156785175-What-are-the-specs-of-J1',
      what: 'IDEX, 300×200×200 mm, 300 °C hotends, 100 °C heated bed, easy-swap hotends and '
          + 'built-in nozzle wipers.',
    },
  };

  /**
   * Where to get help for a printer, per vendor.
   *
   * Every URL below returned 200 on CHECKED_ON — checked, not assumed, because a
   * support link that 404s is worse than no link: it sends a shop with a broken
   * printer to a dead page and looks like the app is out of date.
   *
   * Vendor-level rather than per-model wherever a model page could not be
   * verified. A working vendor hub beats a guessed deep link, and there is a
   * per-printer override below for the ones that have a real page of their own.
   */
  const VENDOR_SUPPORT = {
    'Bambu Lab': 'https://wiki.bambulab.com/en/home',
    Prusa:       'https://help.prusa3d.com/',
    Creality:    'https://www.creality.com/pages/download',
    Anycubic:    'https://support.anycubic.com/',
    Elegoo:      'https://us.elegoo.com/pages/support',
    Snapmaker:   'https://wiki.snapmaker.com/',
    QIDI:        'https://qidi3d.com/pages/support',
    Voron:       'https://docs.vorondesign.com/',
    FLSUN:       'https://flsun3d.com/pages/support',
    UltiMaker:   'https://support.ultimaker.com/',
    Raise3D:     'https://support.raise3d.com/',
    Sovol:       'https://www.sovol3d.com/pages/faq',
  };

  /** Model-specific support pages, where one was verified to exist. */
  const MODEL_SUPPORT = {
    'bambu-x1c':      'https://wiki.bambulab.com/en/x1',
    'bambu-x1e':      'https://wiki.bambulab.com/en/x1',
    'bambu-p1s':      'https://wiki.bambulab.com/en/p1',
    'bambu-p1p':      'https://wiki.bambulab.com/en/p1',
    'bambu-a1':       'https://wiki.bambulab.com/en/a1',
    'bambu-a1-mini':  'https://wiki.bambulab.com/en/a1',
    'bambu-h2d':      'https://wiki.bambulab.com/en/h2d',
    'prusa-mk4s':     'https://help.prusa3d.com/tag/mk4s',
    'prusa-mk4':      'https://help.prusa3d.com/tag/mk4',
    'prusa-mk3s':     'https://help.prusa3d.com/tag/mk3s',
    'prusa-mini':     'https://help.prusa3d.com/tag/mini',
    'prusa-xl':       'https://help.prusa3d.com/tag/xl',
    'prusa-core-one': 'https://help.prusa3d.com/tag/core-one',
    'snapmaker-u1':   'https://wiki.snapmaker.com/en/FAQ/u1',
  };

  /** The best support link for a printer: its own page, else its vendor hub. */
  function supportUrl(entry) {
    if (!entry) return null;
    return MODEL_SUPPORT[entry.id] || VENDOR_SUPPORT[entry.vendor] || null;
  }

  /**
   * TWO SEPARATE QUESTIONS, which the first version of this file collapsed into
   * one and got wrong for every machine it touched.
   *
   * `extruder` is how filament is DRIVEN — direct or bowden. That is a property
   * of a single toolhead and it stays exactly as the catalog always had it.
   *
   * `feed` is how a machine gets more than one colour, which is a different
   * axis entirely. A Bambu X1C is direct drive AND fed by an AMS. A Snapmaker
   * U1 is a toolchanger whose four toolheads are each direct drive. Writing
   * 'multi' into `extruder` threw away the drive type and broke a test that was
   * right to complain.
   *
   *   single       one nozzle, one colour at a time
   *   multi        one nozzle fed by a multi-material unit (AMS, CFS, MMU)
   *   toolchanger  several complete toolheads, parked and swapped mid-print
   *   idex         two independent carriages on one gantry
   *   dual         two nozzles on one carriage
   *
   * The distinction earns its keep in the wear model: four toolheads spread wear
   * across four nozzles, while an AMS puts every colour through ONE.
   */
  const EXTRUDER_KINDS = {
    direct: 'Direct Drive',
    bowden: 'Bowden',
  };

  const FEED_KINDS = {
    single: 'Single colour',
    multi: 'Multi-material unit (AMS / CFS / MMU)',
    toolchanger: 'Toolchanger',
    idex: 'IDEX (two carriages)',
    dual: 'Dual nozzle',
  };

  /**
   * Checked facts, keyed by catalog id. Merged over the bundled entry.
   *
   * `nozzleMaterial` uses the same keys as lib/nozzle-wear-data.js, so picking a
   * printer sets a wear threshold that matches what is actually fitted.
   */
  const FACTS = {
    // ── Bambu Lab: the AMS feeds ONE nozzle, so colours do not spread the wear.
    'bambu-x1c':     { nozzleMaterial: 'hardened',  feed: 'multi', enclosed: true,  maxHotendC: 300, maxBedC: 100, chamber: 'passive', maxChamberC: 50, filamentMm: 1.75, src: 'bambuNozzles' },
    'bambu-x1e':     { nozzleMaterial: 'hardened',  feed: 'multi', enclosed: true,  maxHotendC: 320, maxBedC: 110, chamber: 'active',  maxChamberC: 60, filamentMm: 1.75, src: 'bambuNozzles' },
    'bambu-p1s':     { nozzleMaterial: 'stainless', feed: 'multi', enclosed: true,  maxHotendC: 300, maxBedC: 100, chamber: 'passive', maxChamberC: 50, filamentMm: 1.75, src: 'bambuNozzles' },
    'bambu-p1p':     { nozzleMaterial: 'stainless', feed: 'multi', enclosed: false, maxHotendC: 300, maxBedC: 100, chamber: 'none',                     filamentMm: 1.75, src: 'bambuNozzles' },
    'bambu-a1':      { nozzleMaterial: 'stainless', feed: 'multi', enclosed: false, maxHotendC: 300, maxBedC: 100, chamber: 'none',                     filamentMm: 1.75, maxSpeedMms: 500, maxAccelMms2: 10000, src: 'bambuA1pdf' },
    'bambu-a1-mini': { nozzleMaterial: 'stainless', feed: 'multi', enclosed: false, maxHotendC: 300, maxBedC: 80,  chamber: 'none',                     filamentMm: 1.75, src: 'bambuNozzles' },
    'bambu-h2d':     { feed: 'dual', enclosed: true, maxHotendC: 350, maxBedC: 120, chamber: 'active', maxChamberC: 65, filamentMm: 1.75, src: 'bambuSpecs' },

    // ── Prusa: brass everywhere, which is why the wear warning matters here.
    'prusa-mk4s':     { nozzleMaterial: 'brass', feed: 'multi',  enclosed: false, maxHotendC: 290, maxBedC: 120, chamber: 'none', filamentMm: 1.75, layerMm: [0.05, 0.30], src: 'prusaMK4S' },
    'prusa-mk4':      { nozzleMaterial: 'brass', feed: 'multi',  enclosed: false, maxHotendC: 290, maxBedC: 120, chamber: 'none', filamentMm: 1.75, src: 'prusaNozzles' },
    'prusa-mk3s':     { nozzleMaterial: 'brass', feed: 'multi',  enclosed: false, maxHotendC: 300, maxBedC: 120, chamber: 'none', filamentMm: 1.75, src: 'prusaNozzles' },
    'prusa-mini':     { nozzleMaterial: 'brass', feed: 'single', enclosed: false, maxHotendC: 280, maxBedC: 100, chamber: 'none', filamentMm: 1.75, src: 'prusaNozzles' },
    'prusa-core-one': { nozzleMaterial: 'brass', feed: 'multi',  enclosed: true,  maxHotendC: 290, maxBedC: 120, chamber: 'active', maxChamberC: 55, filamentMm: 1.75, src: 'prusaCoreOne' },
    'prusa-xl':       { nozzleMaterial: 'brass', feed: 'toolchanger', toolheads: 5, enclosed: false, maxHotendC: 290, maxBedC: 120, chamber: 'none', filamentMm: 1.75, src: 'prusaXLspec' },


    // ── Creality
    'creality-k1-max':     { maxHotendC: 300, maxBedC: 120, chamber: 'passive', enclosed: true, filamentMm: 1.75, maxSpeedMms: 600, src: 'crealityK1Max' },
    'creality-k2-plus':    { nozzleMaterial: 'hardened', feed: 'multi', enclosed: true, maxHotendC: 350, maxBedC: 120, chamber: 'active', maxChamberC: 60, filamentMm: 1.75, src: 'crealityK2' },
    'creality-ender3v3se': { maxHotendC: 260, maxBedC: 110, chamber: 'none', filamentMm: 1.75, src: 'polymakerCreality' },
    'creality-k1':         { enclosed: true, chamber: 'passive', filamentMm: 1.75, maxSpeedMms: 600, src: 'crealityK1Max' },

    // ── Elegoo
    'elegoo-centauri-carbon': { nozzleMaterial: 'brass', enclosed: true, maxHotendC: 320, filamentMm: 1.75, src: 'elegooCentauri' },

    // ── Sovol
    'sovol-sv08': { maxHotendC: 300, maxBedC: 100, chamber: 'none', filamentMm: 1.75, maxSpeedMms: 700, src: 'sovolSV' },
    'sovol-sv06': { maxHotendC: 300, maxBedC: 100, chamber: 'none', filamentMm: 1.75, src: 'sovolSV' },

    // ── QIDI
    'qidi-plus4': { enclosed: true, maxHotendC: 370, maxBedC: 120, chamber: 'active', maxChamberC: 65, filamentMm: 1.75, maxSpeedMms: 600, src: 'qidiPlus4' },

    // ── FLSUN
    'flsun-v400': { maxHotendC: 300, maxBedC: 110, chamber: 'none', filamentMm: 1.75, maxSpeedMms: 600, maxAccelMms2: 10000, src: 'flsunV400' },

    // ── UltiMaker — 2.85 mm filament, which is the fact most likely to catch a
    //    shop out: 1.75 mm spools simply will not feed.
    'ultimaker-s5': { feed: 'dual', enclosed: true, maxHotendC: 280, filamentMm: 2.85, src: 'ultimakerS' },
    'ultimaker-s3': { feed: 'dual', enclosed: true, maxHotendC: 280, filamentMm: 2.85, src: 'ultimakerS' },

    // ── Raise3D
    'raise3d-pro3': { feed: 'dual', enclosed: true, maxHotendC: 300, filamentMm: 1.75, src: 'raise3dPro3' },



    // ── Anycubic
    'anycubic-kobra3': { feed: 'multi', maxHotendC: 300, maxBedC: 110, chamber: 'none', filamentMm: 1.75, src: 'anycubicKobra3' },
    'anycubic-kobra2': { maxHotendC: 260, maxBedC: 90,  chamber: 'none', filamentMm: 1.75, src: 'anycubicKobra3' },

    // ── Elegoo (FDM)
    'elegoo-neptune4':    { maxHotendC: 300, chamber: 'none', filamentMm: 1.75, src: 'elegooNeptune4' },
    'elegoo-neptune4pro': { maxHotendC: 300, chamber: 'none', filamentMm: 1.75, src: 'elegooNeptune4' },

    'sovol-sv07': { maxHotendC: 300, maxBedC: 100, chamber: 'none', filamentMm: 1.75, src: 'sovolSV07' },

    'qidi-x-max3':  { enclosed: true, maxHotendC: 350, chamber: 'active', maxChamberC: 65, filamentMm: 1.75, maxSpeedMms: 600, src: 'qidiX3' },
    'qidi-x-plus3': { enclosed: true, maxHotendC: 350, chamber: 'active', maxChamberC: 65, filamentMm: 1.75, src: 'qidiX3' },

    'flsun-s1': { maxHotendC: 350, chamber: 'none', filamentMm: 1.75, maxSpeedMms: 1200, maxAccelMms2: 40000, src: 'flsunS1' },

    // ── RESIN. A different machine with a different set of questions.
    //
    // These six used to be described with FDM fields — hotend temperature, bed
    // temperature, extruder type — none of which exists on an MSLA printer. The
    // catalog carried `extruder: 'direct'` and `nozzle: 0` for all of them,
    // which is not a small spec, it is a wrong one: it says these machines have
    // a nozzle whose diameter happens to be zero.
    //
    // What a shop actually needs to know here is the LCD (how fine the detail
    // can be) and the XY pixel size (what a part will actually resolve to).
    // Layer height on resin is set in the slicer, not by a nozzle.
    'elegoo-saturn4-ultra': { lcdInch: 10,   lcdResolution: '11520×5120', lcdK: '12K', xyMicrons: 19, maxSpeedMmH: 150, lightNm: 405, src: 'elegooSaturn4U' },
    'elegoo-mars5-ultra':   { lcdInch: 7,    lcdResolution: '9K',         lcdK: '9K',  xyMicrons: 18, maxSpeedMmH: 150, lightNm: 405, src: 'elegooMars5U' },
    'anycubic-photon-m5s':  { lcdInch: 10.1, lcdResolution: '11520×5120', lcdK: '12K', xyMicrons: 19, lightNm: 405, src: 'anycubicM5s' },
    'anycubic-photon-m3':   { lcdInch: 9.25, lcdResolution: '6K',         lcdK: '6K',  xyMicrons: 34, lightNm: 405, src: 'anycubicM3' },

    // ── Voron is DELIBERATELY unswept. They are self-sourced kits: hotend, bed
    //    and extruder are whatever the builder fitted, so a "spec" here would
    //    describe a machine nobody owns. The support link goes to the build
    //    documentation, which is the useful answer for a Voron.

    // ── Snapmaker
    'snapmaker-u1': { nozzleMaterial: 'stainless', feed: 'toolchanger', toolheads: 4, enclosed: false, filamentMm: 1.75, src: 'snapmakerU1' },
    'snapmaker-j1': { feed: 'idex', enclosed: true, maxHotendC: 300, maxBedC: 100, filamentMm: 1.75, src: 'snapmakerJ1' },

    // ── Creality / Elegoo
  };

  /** Facts for one catalog id, or an empty object. */
  function factsFor(id) {
    const f = FACTS[id];
    if (!f) return {};
    const { src, ...rest } = f;
    return src ? { ...rest, source: SOURCES[src] } : { ...rest };
  }

  /** Merge the checked facts and the support link onto a bundled catalog entry. */
  function apply(entry) {
    if (!entry || !entry.id) return entry;
    return { ...entry, ...factsFor(entry.id), support: supportUrl(entry) };
  }

  const api = { CHECKED_ON, SOURCES, EXTRUDER_KINDS, FEED_KINDS, FACTS,
    VENDOR_SUPPORT, MODEL_SUPPORT, supportUrl, factsFor, apply };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrinterFacts = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
