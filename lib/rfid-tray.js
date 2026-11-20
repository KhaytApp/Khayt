'use strict';
(function (global) {

/**
 * A spool's RFID tag, as a Snapmaker U1 head reads it (U1 idea 2, Mac plan
 * Nov 19), and which of the shop's spools it is (KhaytRfidTray).
 *
 * Ideas only from bloodf/u1control (GPL-3.0): no code, no identifiers. The
 * shapes are the U1's own, from a logged read-only GET on the shop's Baby U1
 * (test/fixtures/u1-filament-detect.json, Moonraker 2.0.0, stock firmware):
 *
 *   filament_detect.info[head]
 *     VERSION        1 on a tag; 0 when the head reads no tag
 *     VENDOR, MANUFACTURER, MAIN_TYPE, SUB_TYPE   strings, "NONE" with no tag
 *     RGB_1..5       packed 0xRRGGBB ints, COLOR_NUMS of them in use
 *     ARGB_COLOR     packed 0xAARRGGBB
 *     DIAMETER       hundredths of a mm (175 = 1.75 mm)   } units inferred,
 *     WEIGHT         grams on a full spool (500)          } not documented
 *     LENGTH         metres (150)                         }
 *     SKU, OFFICIAL  the maker's product number; a maker's own tag
 *
 * "No tag" is VERSION 0 or MAIN_TYPE "NONE", never a colour: an empty head
 * reports white (RGB_1 16777215), and white is a real colour (Mac, Nov 19).
 * A head with no tag may still hold filament (print_task_config says so);
 * this module only reads the TAG.
 *
 * NEVER CHANGES A SPOOL. spoolMatch answers link / new / ask; linking a head
 * to a spool is the caller's record, and changing anything about an existing
 * spool always goes through the shop's confirmation. Pure; no DOM, no I/O.
 */

const NONE = 'NONE';

const str = (v) => (typeof v === 'string' ? v.trim() : '');
const int = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : null);
const said = (v) => { const s = str(v); return s && s.toUpperCase() !== NONE ? s : ''; };

/** A packed 0xRRGGBB int as "#RRGGBB", or null. */
function hexOf(packed) {
  const n = int(packed);
  if (n === null || n < 0 || n > 0xFFFFFF) return null;
  return '#' + n.toString(16).toUpperCase().padStart(6, '0');
}

/**
 * One head's tag, or null when the head reads no tag.
 * @returns {null | { vendor, manufacturer, material, sub, colours: string[],
 *   weightG: number|null, diameterMm: number|null, lengthM: number|null,
 *   sku: number|null, official: boolean }}
 */
function rfidTray(info) {
  if (!info || typeof info !== 'object' || Array.isArray(info)) return null;
  if (int(info.VERSION) === 0) return null;
  const material = said(info.MAIN_TYPE);
  if (!material) return null;
  const nums = int(info.COLOR_NUMS);
  const count = nums !== null && nums >= 1 && nums <= 5 ? nums : 1;
  const colours = [];
  for (let i = 1; i <= count; i++) {
    const h = hexOf(info['RGB_' + i]);
    if (h) colours.push(h);
  }
  const pos = (v) => { const n = int(v); return n !== null && n > 0 ? n : null; };
  const dia = pos(info.DIAMETER);
  return {
    vendor: said(info.VENDOR) || null,
    manufacturer: said(info.MANUFACTURER) || null,
    material,
    sub: said(info.SUB_TYPE) || null,
    colours,
    weightG: pos(info.WEIGHT),
    diameterMm: dia !== null ? dia / 100 : null,
    lengthM: pos(info.LENGTH),
    sku: pos(info.SKU),
    official: info.OFFICIAL === true,
  };
}

/** Every head's tag from a filament_detect object (null where no tag). */
function trays(filamentDetect) {
  const info = filamentDetect && Array.isArray(filamentDetect.info) ? filamentDetect.info.slice(0, 16) : [];
  return info.map(rfidTray);
}

function lib(name, file) {
  if (global && global[name]) return global[name];
  if (typeof require === 'function') { try { return require(file); } catch (_) { return null; } }
  return null;
}

/**
 * Which of the shop's spools a tag is.
 *
 *   { action: 'link', spoolId }      exactly one spool matches strongly: the
 *                                    same material family, a close colour
 *                                    (spool-match's GOOD_MATCH), and the same
 *                                    brand when the spool records one
 *   { action: 'ask', candidates }    more than one, or only near matches:
 *                                    the shop chooses (best first)
 *   { action: 'new', prefill }       nothing like it: "Add spool", filled in
 *                                    from the tag
 *   { action: 'none' }               no tag
 *
 * Spools that are used up (weight 0) or resin are never offered.
 */
function spoolMatch(tray, spools) {
  if (!tray || !tray.material) return { action: 'none' };
  const LC = lib('KhaytLoadedColours', './loaded-colours.js');
  const SM = lib('KhaytSpoolMatch', './spool-match.js');
  const fam = (m) => (LC && typeof LC.family === 'function' ? LC.family(m) : String(m || '').toUpperCase());
  const want = fam(tray.material);
  const colour = tray.colours && tray.colours[0];
  const brands = [tray.manufacturer, tray.vendor].filter(Boolean).map((b) => b.toLowerCase());
  const scored = [];
  for (const s of Array.isArray(spools) ? spools : []) {
    if (!s || !s.id || s.materialType === 'resin') continue;
    if (s.weight !== undefined && !(+s.weight > 0)) continue;
    if (!want || fam(s.material) !== want) continue;
    const d = colour && s.color && SM && typeof SM.colorDistance === 'function' ? SM.colorDistance(colour, s.color) : null;
    const closeColour = d !== null && d < SM.GOOD_MATCH;
    const brand = str(s.brand).toLowerCase();
    const brandOk = !brand || brands.includes(brand);
    const brandSame = !!brand && brands.includes(brand);
    scored.push({ spoolId: String(s.id), deltaE: d === null ? null : Math.round(d * 10) / 10, strong: closeColour && brandOk, brandSame, near: d !== null && d < (SM ? SM.FAR_MATCH : 25) });
  }
  const strong = scored.filter((x) => x.strong);
  if (strong.length === 1) return { action: 'link', spoolId: strong[0].spoolId };
  const pool = strong.length ? strong : scored.filter((x) => x.near);
  if (pool.length) {
    const candidates = pool.slice().sort((a, b) => (b.brandSame - a.brandSame) || ((a.deltaE ?? 99) - (b.deltaE ?? 99)) || a.spoolId.localeCompare(b.spoolId))
      .map((x) => ({ spoolId: x.spoolId, deltaE: x.deltaE }));
    return { action: 'ask', candidates };
  }
  return {
    action: 'new',
    prefill: {
      material: tray.sub ? tray.material + ' ' + tray.sub : tray.material,
      color: colour || null,
      brand: tray.manufacturer || tray.vendor || null,
      spoolWeight: tray.weightG,
      weight: tray.weightG,
      diameterMm: tray.diameterMm,
    },
  };
}

const api = { NONE, hexOf, rfidTray, trays, spoolMatch };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytRfidTray = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
