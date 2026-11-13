'use strict';
(function (global) {

/**
 * Which colour FAMILY a filament colour belongs to: red, orange, yellow,
 * green, blue, purple, pink, brown, black, grey or white.
 *
 * ── WHY IT EXISTS ─────────────────────────────────────────────────────────
 *
 * A model's record keeps the colours it was sliced with as hex values
 * (`printFiles[].colors: [{ hex, label, grams }]`). A shop looking for
 * "something red to print" cannot filter on #C8102E, and a thousand models
 * hold a thousand slightly different reds. The library's Colour filter needs
 * eleven names, and every app that draws that filter has to put the same
 * model under the same name — so the rule has one author, here.
 *
 * Only what the slicer wrote is read. A model with no colours on its record
 * has NO colour information (`tokensOf` → ['none']); nothing is guessed from
 * the shop's spools.
 *
 * ── WHY HSL, AND NOT OKLCH ────────────────────────────────────────────────
 *
 * The thresholds are set in HSL (hue in degrees, saturation and lightness
 * 0–1) worked out from the 8-bit sRGB channels. OKLCH is the better
 * perceptual space, but it needs a cube root and a power per channel, and
 * those are not guaranteed to round the same way in JavaScript, Swift and
 * Kotlin: a colour sitting on a boundary could be "orange" on the desktop and
 * "yellow" on the Mac. HSL from integers uses only + − × ÷, which IEEE 754
 * fixes bit for bit, so the Mac's native copy of this rule
 * (`KhaytCore.ColourFamily`) is held to this file over the whole colour cube
 * by a test, and can be. HSL's known faults are handled by rule rather than
 * by a better space: its saturation is meaningless near black and near white
 * (so lightness is asked first, and the raw channel spread beside it), and
 * it has no brown or pink (so those are bands of lightness and saturation
 * inside the red, orange and magenta hues).
 *
 * ── THE RULE, IN ORDER ────────────────────────────────────────────────────
 *
 * L is HSL lightness, S is HSL saturation, and V is the spread of the
 * channels over the largest one (HSV's saturation) — the measure of how
 * washed out a colour is that stays honest for light colours, where S does
 * not (cream #EDE3D2 has S 0.43 and V 0.11).
 *
 *   1. L < 0.10                              → black   (whatever the tint)
 *   2. L > 0.93                              → white   (#FAF7F0, ivory)
 *   3. S < 0.15, V < 0.12 or spread < 24/255 → no hue: black below L 0.20,
 *                                              white above L 0.85, else grey
 *                                              (#1A1A1E black, #C0C0C0 grey)
 *   4. by hue:
 *      345°–14°   red;   pink when light (L ≥ 0.72), or washed out
 *                 (V < 0.45, L ≥ 0.55); brown when dull and dark
 *                 (V < 0.50, L < 0.45). Maroon (#800000) is RED: it is
 *                 fully saturated, and a shop calls that spool dark red.
 *      14°–50°    brown when dark (L < 0.42) or dull (V < 0.45, L < 0.85) —
 *                 chocolate, coffee, tan and beige (#C8AD7F);
 *                 otherwise orange below 42° (#F28C28, amber #F2A541) and
 *                 yellow from 42° (gold #D4AF37). Peach (#FFDAB9) is
 *                 ORANGE: a light orange, by its hue.
 *      50°–70°    yellow; a dark one (L < 0.35) is olive, which is GREEN.
 *      70°–188°   green. Teal is green (#0E8A7E, and #008080 at 180°).
 *      188°–255°  blue (cyan #00B7EB and navy #0A2A50 included).
 *      255°–290°  purple.
 *      290°–320°  purple; pink when light (L ≥ 0.60). Pure magenta
 *                 (#FF00FF, L 0.50) is PURPLE.
 *      320°–345°  pink (L ≥ 0.45); darker is purple below 335°, else red.
 *
 * A boundary belongs to the band that STARTS at it (42° is yellow).
 */

/** The families, in the order every menu lists them. */
const FAMILIES = ['red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink', 'brown', 'black', 'grey', 'white'];

/** A model with two or more different families; and one with no readable colour. */
const MULTI = 'multi';
const NONE = 'none';

/** Every id the Colour filter can hold, in menu order. */
const TOKENS = FAMILIES.concat([MULTI, NONE]);

/**
 * One typical colour per family, for the swatch beside its name. Drawn, never
 * matched against: the rule above decides what is in a family.
 */
const SWATCH = {
  red: '#D92D20', orange: '#F28C28', yellow: '#F2C811', green: '#2E9E4F', blue: '#2F6FDE',
  purple: '#7F56D9', pink: '#F27EB2', brown: '#8B5A2B', black: '#1A1A1A', grey: '#9AA0A6', white: '#FFFFFF',
};

/**
 * `[r, g, b]` (0–255) from a hex colour: 3 or 6 digits, with or without '#',
 * any case, spaces around it ignored. 4 and 8 digits carry an alpha, which is
 * dropped. Null for anything else.
 */
function parseHex(hex) {
  if (typeof hex !== 'string') return null;
  let s = hex.trim();
  if (s.charAt(0) === '#') s = s.slice(1);
  if (!/^[0-9a-fA-F]+$/.test(s)) return null;
  if (s.length === 3 || s.length === 4) {
    return [0, 1, 2].map((i) => parseInt(s.charAt(i) + s.charAt(i), 16));
  }
  if (s.length === 6 || s.length === 8) {
    return [0, 2, 4].map((i) => parseInt(s.slice(i, i + 2), 16));
  }
  return null;
}

/** The family of one colour given as channels 0–255. */
function familyOfRgb(r, g, b) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const spread = max - min;
  const sum = max + min;
  const light = sum / 510;
  if (light < 0.10) return 'black';
  if (light > 0.93) return 'white';
  // A spread of 0 is a grey; asked first so black and white never divide by 0.
  const sat = spread === 0 ? 0 : spread / (255 - Math.abs(sum - 255));
  const wash = max === 0 ? 0 : spread / max;
  if (sat < 0.15 || wash < 0.12 || spread < 24) {
    if (light < 0.20) return 'black';
    if (light > 0.85) return 'white';
    return 'grey';
  }
  let hue;
  if (max === r) hue = 60 * ((g - b) / spread);
  else if (max === g) hue = 60 * ((b - r) / spread) + 120;
  else hue = 60 * ((r - g) / spread) + 240;
  if (hue < 0) hue += 360;

  if (hue >= 345 || hue < 14) {
    if (light >= 0.72) return 'pink';
    if (wash < 0.45 && light >= 0.55) return 'pink';
    if (wash < 0.50 && light < 0.45) return 'brown';
    return 'red';
  }
  if (hue < 50) {
    if (light < 0.42) return 'brown';
    if (wash < 0.45 && light < 0.85) return 'brown';
    return hue < 42 ? 'orange' : 'yellow';
  }
  if (hue < 70) return light < 0.35 ? 'green' : 'yellow';
  if (hue < 188) return 'green';
  if (hue < 255) return 'blue';
  if (hue < 290) return 'purple';
  if (hue < 320) return light >= 0.60 ? 'pink' : 'purple';
  if (light >= 0.45) return 'pink';
  return hue < 335 ? 'purple' : 'red';
}

/** The family of one hex colour, or null when it cannot be read. */
function familyOf(hex) {
  const rgb = parseHex(hex);
  return rgb ? familyOfRgb(rgb[0], rgb[1], rgb[2]) : null;
}

/**
 * The families among a model's colours, each once, in `FAMILIES` order.
 * `colors` is the record's list — `[{ hex }]` — or plain hex strings; an
 * entry that cannot be read is skipped, and anything that is not a list is
 * no colours.
 */
function familiesOf(colors) {
  if (!Array.isArray(colors)) return [];
  const seen = {};
  for (const c of colors) {
    const f = familyOf(c && typeof c === 'object' ? c.hex : c);
    if (f) seen[f] = true;
  }
  return FAMILIES.filter((f) => seen[f]);
}

/**
 * The Colour filter ids a model is found under: each family it has, then
 * 'multi' when it has two or more DIFFERENT families (two reds are one
 * colour to a shop choosing a spool) — or ['none'] when no colour on it can
 * be read. A multicolour model is under each of its families AND under
 * 'multi'.
 */
function tokensOf(colors) {
  const families = familiesOf(colors);
  if (!families.length) return [NONE];
  return families.length >= 2 ? families.concat([MULTI]) : families;
}

const api = { FAMILIES, MULTI, NONE, TOKENS, SWATCH, parseHex, familyOfRgb, familyOf, familiesOf, tokensOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytColourFamily = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
