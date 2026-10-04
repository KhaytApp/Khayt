'use strict';
/*
 * Bundled filament swatch reference (Bed Ready).
 *
 * A curated, OFFLINE library of popular filament colours so the Colour Studio matcher can answer
 * "what real filament is closest to this colour?" even before the user has logged any stock — and so
 * a fresh install isn't a dead-end. It's the offline, integrated counterpart to filamentcolors.xyz.
 *
 * hex values are nominal — manufacturer-published (Bambu/Prusament publish theirs) or community-
 * referenced approximations, for PERCEPTUAL matching, not colorimeter-measured. Close enough to rank
 * "nearest known filament" by ΔE; not a substitute for holding the spool in your hand.
 *
 * Exposed as global.BedReadyFilamentSwatches (an array of { brand, name, material, hex }). Loaded only
 * by bedready.html, so it stays a Bed Ready feature; colorstudio.js degrades gracefully without it.
 */
(function (global) {
  var SWATCHES = [
    // ── Bambu Lab · PLA Basic (manufacturer-published) ──────────────────────
    { brand: 'Bambu Lab', name: 'PLA Basic Jade White', material: 'PLA', hex: '#FFFFFF' },
    { brand: 'Bambu Lab', name: 'PLA Basic Black', material: 'PLA', hex: '#000000' },
    { brand: 'Bambu Lab', name: 'PLA Basic Gray', material: 'PLA', hex: '#8E9089' },
    { brand: 'Bambu Lab', name: 'PLA Basic Dark Gray', material: 'PLA', hex: '#545454' },
    { brand: 'Bambu Lab', name: 'PLA Basic Silver', material: 'PLA', hex: '#A6A9AA' },
    { brand: 'Bambu Lab', name: 'PLA Basic Gold', material: 'PLA', hex: '#E4BD68' },
    { brand: 'Bambu Lab', name: 'PLA Basic Beige', material: 'PLA', hex: '#F7E6DE' },
    { brand: 'Bambu Lab', name: 'PLA Basic Bambu Green', material: 'PLA', hex: '#00AE42' },
    { brand: 'Bambu Lab', name: 'PLA Basic Mistletoe Green', material: 'PLA', hex: '#3F8E43' },
    { brand: 'Bambu Lab', name: 'PLA Basic Cyan', material: 'PLA', hex: '#0086D6' },
    { brand: 'Bambu Lab', name: 'PLA Basic Blue', material: 'PLA', hex: '#0A2989' },
    { brand: 'Bambu Lab', name: 'PLA Basic Blue Gray', material: 'PLA', hex: '#5B6579' },
    { brand: 'Bambu Lab', name: 'PLA Basic Turquoise', material: 'PLA', hex: '#00B1B7' },
    { brand: 'Bambu Lab', name: 'PLA Basic Sunflower Yellow', material: 'PLA', hex: '#FEC600' },
    { brand: 'Bambu Lab', name: 'PLA Basic Yellow', material: 'PLA', hex: '#F4EE2A' },
    { brand: 'Bambu Lab', name: 'PLA Basic Orange', material: 'PLA', hex: '#FF6A13' },
    { brand: 'Bambu Lab', name: 'PLA Basic Pink', material: 'PLA', hex: '#F55A74' },
    { brand: 'Bambu Lab', name: 'PLA Basic Magenta', material: 'PLA', hex: '#EC008C' },
    { brand: 'Bambu Lab', name: 'PLA Basic Red', material: 'PLA', hex: '#C12E1F' },
    { brand: 'Bambu Lab', name: 'PLA Basic Purple', material: 'PLA', hex: '#5E43B7' },
    { brand: 'Bambu Lab', name: 'PLA Basic Brown', material: 'PLA', hex: '#9D432C' },
    // ── Bambu Lab · PLA Matte ───────────────────────────────────────────────
    { brand: 'Bambu Lab', name: 'PLA Matte Apple Green', material: 'PLA', hex: '#C2E189' },
    { brand: 'Bambu Lab', name: 'PLA Matte Ash Gray', material: 'PLA', hex: '#9B9EA0' },
    { brand: 'Bambu Lab', name: 'PLA Matte Bone White', material: 'PLA', hex: '#CBC6B8' },
    { brand: 'Bambu Lab', name: 'PLA Matte Caramel', material: 'PLA', hex: '#AE835B' },
    { brand: 'Bambu Lab', name: 'PLA Matte Charcoal', material: 'PLA', hex: '#000000' },
    { brand: 'Bambu Lab', name: 'PLA Matte Dark Blue', material: 'PLA', hex: '#042F56' },
    { brand: 'Bambu Lab', name: 'PLA Matte Dark Brown', material: 'PLA', hex: '#7D6556' },
    { brand: 'Bambu Lab', name: 'PLA Matte Dark Chocolate', material: 'PLA', hex: '#4D3324' },
    { brand: 'Bambu Lab', name: 'PLA Matte Dark Green', material: 'PLA', hex: '#68724D' },
    { brand: 'Bambu Lab', name: 'PLA Matte Dark Red', material: 'PLA', hex: '#BB3D43' },
    { brand: 'Bambu Lab', name: 'PLA Matte Desert Tan', material: 'PLA', hex: '#E8DBB7' },
    { brand: 'Bambu Lab', name: 'PLA Matte Grass Green', material: 'PLA', hex: '#61C680' },
    { brand: 'Bambu Lab', name: 'PLA Matte Ice Blue', material: 'PLA', hex: '#A3D8E1' },
    { brand: 'Bambu Lab', name: 'PLA Matte Ivory White', material: 'PLA', hex: '#FFFFFF' },
    { brand: 'Bambu Lab', name: 'PLA Matte Latte Brown', material: 'PLA', hex: '#D3B7A7' },
    { brand: 'Bambu Lab', name: 'PLA Matte Lemon Yellow', material: 'PLA', hex: '#F7D959' },
    { brand: 'Bambu Lab', name: 'PLA Matte Lilac Purple', material: 'PLA', hex: '#AE96D4' },
    { brand: 'Bambu Lab', name: 'PLA Matte Mandarin Orange', material: 'PLA', hex: '#F99963' },
    { brand: 'Bambu Lab', name: 'PLA Matte Marine Blue', material: 'PLA', hex: '#0078BF' },
    { brand: 'Bambu Lab', name: 'PLA Matte Nardo Gray', material: 'PLA', hex: '#757575' },
    { brand: 'Bambu Lab', name: 'PLA Matte Plum', material: 'PLA', hex: '#950051' },
    { brand: 'Bambu Lab', name: 'PLA Matte Sakura Pink', material: 'PLA', hex: '#E8AFCF' },
    { brand: 'Bambu Lab', name: 'PLA Matte Scarlet Red', material: 'PLA', hex: '#DE4343' },
    { brand: 'Bambu Lab', name: 'PLA Matte Sky Blue', material: 'PLA', hex: '#56B7E6' },
    { brand: 'Bambu Lab', name: 'PLA Matte Terracotta', material: 'PLA', hex: '#B15533' },
    // ── Prusament · PLA (manufacturer-published) ────────────────────────────
    { brand: 'Prusament', name: 'PLA Prusa Orange', material: 'PLA', hex: '#FF6600' },
    { brand: 'Prusament', name: 'PLA Galaxy Black', material: 'PLA', hex: '#1A1A1A' },
    { brand: 'Prusament', name: 'PLA Jet Black', material: 'PLA', hex: '#000000' },
    { brand: 'Prusament', name: 'PLA Vanilla White', material: 'PLA', hex: '#F6F2E9' },
    { brand: 'Prusament', name: 'PLA Lipstick Red', material: 'PLA', hex: '#C7273B' },
    { brand: 'Prusament', name: 'PLA Ms. Pink', material: 'PLA', hex: '#F53A9E' },
    { brand: 'Prusament', name: 'PLA Mystic Green', material: 'PLA', hex: '#1B7A50' },
    { brand: 'Prusament', name: 'PLA Galaxy Silver', material: 'PLA', hex: '#8A8D8F' },
    { brand: 'Prusament', name: 'PLA Ocean Blue', material: 'PLA', hex: '#1B5AA6' },
    { brand: 'Prusament', name: 'PLA Gravity Grey', material: 'PLA', hex: '#5A5D60' },
    { brand: 'Prusament', name: 'PLA Yellow', material: 'PLA', hex: '#F5C518' },
    // ── Polymaker · PolyTerra PLA ───────────────────────────────────────────
    { brand: 'Polymaker', name: 'PolyTerra Cotton White', material: 'PLA', hex: '#F7F7F5' },
    { brand: 'Polymaker', name: 'PolyTerra Charcoal Black', material: 'PLA', hex: '#1D1D1D' },
    { brand: 'Polymaker', name: 'PolyTerra Muted Grey', material: 'PLA', hex: '#8C8F8E' },
    { brand: 'Polymaker', name: 'PolyTerra Army Green', material: 'PLA', hex: '#5A5F3C' },
    { brand: 'Polymaker', name: 'PolyTerra Forest Green', material: 'PLA', hex: '#1F5C3A' },
    { brand: 'Polymaker', name: 'PolyTerra Sapphire Blue', material: 'PLA', hex: '#1C4E8A' },
    { brand: 'Polymaker', name: 'PolyTerra Sunrise Orange', material: 'PLA', hex: '#F26A2E' },
    { brand: 'Polymaker', name: 'PolyTerra Lava Red', material: 'PLA', hex: '#C0392B' },
    { brand: 'Polymaker', name: 'PolyTerra Sakura Pink', material: 'PLA', hex: '#F4B8C4' },
    { brand: 'Polymaker', name: 'PolyTerra Banana', material: 'PLA', hex: '#F4D35E' },
    // ── Common generics (Hatchbox / Overture / SUNLU / eSUN / Elegoo) ───────
    { brand: 'Hatchbox', name: 'PLA True White', material: 'PLA', hex: '#F4F4F4' },
    { brand: 'Hatchbox', name: 'PLA True Black', material: 'PLA', hex: '#0B0B0B' },
    { brand: 'Hatchbox', name: 'PLA True Red', material: 'PLA', hex: '#B81E28' },
    { brand: 'Hatchbox', name: 'PLA Blue', material: 'PLA', hex: '#1C4FA0' },
    { brand: 'Hatchbox', name: 'PLA Green', material: 'PLA', hex: '#2E8B57' },
    { brand: 'Hatchbox', name: 'PLA Yellow', material: 'PLA', hex: '#F6C915' },
    { brand: 'Overture', name: 'PLA White', material: 'PLA', hex: '#F5F5F5' },
    { brand: 'Overture', name: 'PLA Black', material: 'PLA', hex: '#101010' },
    { brand: 'Overture', name: 'PLA Space Gray', material: 'PLA', hex: '#5C5F63' },
    { brand: 'Overture', name: 'PLA Rock White', material: 'PLA', hex: '#E9E7E0' },
    { brand: 'SUNLU', name: 'PLA+ White', material: 'PLA', hex: '#F6F6F6' },
    { brand: 'SUNLU', name: 'PLA+ Black', material: 'PLA', hex: '#0A0A0A' },
    { brand: 'SUNLU', name: 'PLA+ Grey', material: 'PLA', hex: '#7E8183' },
    { brand: 'SUNLU', name: 'PLA+ Red', material: 'PLA', hex: '#C0272D' },
    { brand: 'eSUN', name: 'PLA+ Cold White', material: 'PLA', hex: '#F3F4F2' },
    { brand: 'eSUN', name: 'PLA+ Black', material: 'PLA', hex: '#080808' },
    { brand: 'eSUN', name: 'PLA+ Grey', material: 'PLA', hex: '#8B8E8F' },
    { brand: 'eSUN', name: 'PLA+ Fire Engine Red', material: 'PLA', hex: '#B71C1C' },
    { brand: 'Elegoo', name: 'PLA White', material: 'PLA', hex: '#F5F5F5' },
    { brand: 'Elegoo', name: 'PLA Black', material: 'PLA', hex: '#0B0B0B' },
    { brand: 'Elegoo', name: 'PLA Grey', material: 'PLA', hex: '#808385' },
    // ── A few common PETG references ────────────────────────────────────────
    { brand: 'Prusament', name: 'PETG Jet Black', material: 'PETG', hex: '#0A0A0A' },
    { brand: 'Prusament', name: 'PETG Signal White', material: 'PETG', hex: '#F1F1F1' },
    { brand: 'Prusament', name: 'PETG Orange', material: 'PETG', hex: '#F26522' },
    { brand: 'Overture', name: 'PETG Black', material: 'PETG', hex: '#111111' },
    { brand: 'Overture', name: 'PETG White', material: 'PETG', hex: '#F4F4F4' },
    { brand: 'SUNLU', name: 'PETG Grey', material: 'PETG', hex: '#7C7F81' },
  ];

  global.BedReadyFilamentSwatches = SWATCHES;
})(typeof globalThis !== 'undefined' ? globalThis : this);
