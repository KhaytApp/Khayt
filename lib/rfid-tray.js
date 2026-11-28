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
 * MORE SHAPES, from the U1 Extended Firmware's own design notes
 * (github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware,
 * docs/design/rfid.md and filament_detect.md; GPL-3, read for the field list
 * only, no code), Nov 27 2026:
 *   CARD_UID       the tag's id, a list of bytes ([112, 175, 145, 226]: a
 *                  Mifare Classic 1K's 4-byte UID). A reel carries a tag on
 *                  EACH flange (one spool read [112,175,145,226] in one head
 *                  and [144,187,145,226] in another, Turki, Nov 27), so a
 *                  spool keeps a SET of them (`tagUids`), and a uid it does
 *                  not hold proves nothing.
 *   VENDOR "Generic"   the extended firmware's word for no maker.
 *   "UID only"     CARD_UID present, OFFICIAL false, no filament data: a tag
 *                  Khayt cannot read. No tag for showing, but its uid still
 *                  finds a spool that was linked to it before.
 *   CARD_TYPE "M1" / "NTAG", CARD_EVENT_TIME (extended firmware only).
 *   ARGB_COLOR = (ALPHA << 24) | RGB_1; COLOR_NUMS counts the RGB_x fields.
 *   Numbers may come as decimal strings ("526861"); they are read.
 * The extended firmware's POST /printer/filament_detect/set can WRITE all of
 * this, CARD_UID included. Khayt never calls it, and a uid is a hint, never
 * an identity.
 *
 * NEVER CHANGES A SPOOL. spoolMatch answers link / new / ask; linking a head
 * to a spool is the caller's record, and changing anything about an existing
 * spool always goes through the shop's confirmation. Pure; no DOM, no I/O.
 */

const NONE = 'NONE';

const str = (v) => (typeof v === 'string' ? v.trim() : '');
// A number, or a whole number written as text ("526861"): the extended
// firmware's readers are not all of one mind about which they send.
const int = (v) => {
  if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v);
  if (typeof v === 'string' && /^\s*-?\d+\s*$/.test(v)) return Number(v.trim());
  return null;
};
const said = (v) => { const s = str(v); return s && s.toUpperCase() !== NONE ? s : ''; };
/** A maker's name, or '' for none: "Generic" is the extended firmware's word for none. */
const maker = (v) => { const s = said(v); return /^generic$/i.test(s) ? '' : s; };

/**
 * A tag's id as one upper-case hex string ("70AF91E2"), from CARD_UID's list
 * of bytes (or a hex string already); null when there is none or it is not
 * one (all zeros is a reader that read nothing).
 */
function uidOf(raw) {
  let hex = '';
  if (Array.isArray(raw)) {
    if (!raw.length || raw.length > 16) return null;
    for (const b of raw) {
      const n = int(b);
      if (n === null || n < 0 || n > 255) return null;
      hex += n.toString(16).toUpperCase().padStart(2, '0');
    }
  } else if (typeof raw === 'string' && /^[0-9a-f]{4,32}$/i.test(raw.trim())) {
    hex = raw.trim().toUpperCase();
  } else return null;
  return /^0+$/.test(hex) ? null : hex;
}

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
    vendor: maker(info.VENDOR) || null,
    manufacturer: maker(info.MANUFACTURER) || null,
    material,
    sub: said(info.SUB_TYPE) || null,
    colours,
    weightG: pos(info.WEIGHT),
    diameterMm: dia !== null ? dia / 100 : null,
    lengthM: pos(info.LENGTH),
    sku: pos(info.SKU),
    official: info.OFFICIAL === true,
    uid: uidOf(info.CARD_UID),
  };
}

/** The tag's uid from one head's info, whether or not the tag can be read: a "UID only" tag has one. */
function headUid(info) {
  if (!info || typeof info !== 'object' || Array.isArray(info)) return null;
  return uidOf(info.CARD_UID);
}

/** The uids a spool keeps, normalised and without repeats. */
function tagUidsOf(spool) {
  const raw = spool && Array.isArray(spool.tagUids) ? spool.tagUids : [];
  const out = [];
  for (const u of raw) { const h = uidOf(u); if (h && out.indexOf(h) < 0) out.push(h); }
  return out;
}

/**
 * The spool with this uid added to its set, or the same spool when it already
 * holds it (or the uid is not one). For the caller's write when a spool is
 * added from a tag, linked to a head that read one, or confirmed as the same
 * spool. Pure: never changes the spool given.
 */
function withTagUid(spool, uid) {
  const h = uidOf(uid);
  if (!spool || typeof spool !== 'object' || !h) return spool;
  const have = tagUidsOf(spool);
  if (have.indexOf(h) >= 0) return spool;
  return Object.assign({}, spool, { tagUids: have.concat([h]) });
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
function spoolMatch(tray, spools, opts) {
  // A uid the shop's spool already holds is that spool: first, and even for a
  // tag that cannot be read ("UID only"). A uid it does NOT hold proves
  // nothing (a reel has a tag on each flange), so the match goes on as before.
  const uid = uidOf(opts && opts.uid !== undefined ? opts.uid : tray && tray.uid);
  if (uid) {
    const held = (Array.isArray(spools) ? spools : []).filter((s) => s && s.id && s.materialType !== 'resin'
      && !(s.weight !== undefined && !(+s.weight > 0)) && tagUidsOf(s).indexOf(uid) >= 0);
    if (held.length === 1) return { action: 'link', spoolId: String(held[0].id), by: 'uid' };
  }
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
    // A tag that names no maker ("Generic", or none) cannot rule a spool's brand out.
    const brandOk = !brand || !brands.length || brands.includes(brand);
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
  const prefill = {
    material: tray.sub ? tray.material + ' ' + tray.sub : tray.material,
    color: colour || null,
    brand: tray.manufacturer || tray.vendor || null,
    spoolWeight: tray.weightG,
    weight: tray.weightG,
    diameterMm: tray.diameterMm,
  };
  // The new spool keeps the tag it was added from, so it is found by it next time.
  if (tray.uid) prefill.tagUids = [tray.uid];
  return { action: 'new', prefill };
}

const api = { NONE, hexOf, uidOf, rfidTray, headUid, trays, tagUidsOf, withTagUid, spoolMatch };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytRfidTray = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
