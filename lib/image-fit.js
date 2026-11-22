'use strict';

/**
 * Getting an image under an upload's size limit without ruining it.
 *
 * Storefronts cap what they will accept — Medusa at 1 MB an image — and a
 * rejected upload is discovered at the end of making a listing, after the
 * description is written and the price is set. Khayt already holds the photos,
 * so it can answer "will this be accepted" before anyone finds out the hard way.
 *
 * ── THIS MODULE ONLY DECIDES; IT NEVER ENCODES ─────────────────────────────
 *
 * The encoding needs Electron's nativeImage. The DECIDING is where the mistakes
 * live — re-compressing something that was already fine, or grinding a photo
 * down until it is unusable and calling that success — so it is pure, injected
 * and tested, and the encoder is the dull part that follows a plan.
 */

/** A product photo bigger than this is bigger than any storefront renders it. */
const DEFAULT_MAX_EDGE = 2000;

/**
 * Below these a product photo stops being one.
 *
 * Reached without getting under the limit, the answer is "this cannot be done",
 * not a 400×400 smear at quality 30. A shop can crop or re-shoot; it cannot undo
 * what we silently did to its only picture.
 */
const FLOOR_EDGE = 800;
const FLOOR_QUALITY = 58;

/** JPEG qualities to try before giving up resolution. Visually near-identical at
 *  the top end; the drop to 58 is where a photograph starts to show it. */
const QUALITY_LADDER = [90, 82, 74, 66, FLOOR_QUALITY];
/** Then trade pixels, at a quality that still looks like a photograph. */
const EDGE_LADDER = [1600, 1200, 1000, FLOOR_EDGE];

const longestEdge = (w, h) => Math.max(Number(w) || 0, Number(h) || 0);

/**
 * What to try, in order, to get `bytes` under `budgetBytes`.
 *
 * @param {object} input
 * @param {number} input.bytes         current encoded size
 * @param {number} input.width
 * @param {number} input.height
 * @param {string} input.format        'jpeg' | 'png' | other
 * @param {boolean} [input.hasAlpha]   PNG transparency the shop may rely on
 * @param {number} [input.budgetBytes] default 1 MB
 * @param {number} [input.maxEdge]     default 2000
 * @returns {{ keep: boolean, steps: Array<{maxEdge:number, format:string, quality:number|null}>, note: string }}
 */
function fitPlan(input) {
  const i = input || {};
  const budget = Math.max(1, Number(i.budgetBytes) || 1024 * 1024);
  const maxEdge = Math.max(FLOOR_EDGE, Number(i.maxEdge) || DEFAULT_MAX_EDGE);
  const bytes = Math.max(0, Number(i.bytes) || 0);
  const edge = longestEdge(i.width, i.height);
  const format = String(i.format || '').toLowerCase() === 'png' ? 'png' : 'jpeg';
  const hasAlpha = !!i.hasAlpha;

  /* ALREADY FINE MEANS LEAVE IT ALONE.
   *
   * Re-encoding an image that would have been accepted costs quality and buys
   * nothing — and doing it every time a shop opens a listing would degrade the
   * same photo repeatedly, each pass a little worse than the last, with nothing
   * to show for it. Oversized DIMENSIONS on a within-budget file are not a
   * reason either: the storefront's limit is bytes. */
  if (bytes > 0 && bytes <= budget && edge <= maxEdge) {
    return { keep: true, steps: [], note: 'already within the limit' };
  }

  const steps = [];

  /* TRANSPARENCY IS TRIED IN PNG FIRST.
   *
   * Flattening alpha onto white is a visible change to somebody's product photo
   * — a mug shot with a cut-out background becomes a mug on a white rectangle —
   * so it is the fallback, not the opening move. If PNG at a sane size fits, the
   * shop never loses the transparency it chose. */
  if (hasAlpha) {
    for (const e of [Math.min(edge || maxEdge, maxEdge), ...EDGE_LADDER]) {
      if (e > (edge || maxEdge)) continue;
      steps.push({ maxEdge: e, format: 'png', quality: null });
    }
  }

  // Same size, less quality: the cheapest thing that usually works.
  const firstEdge = Math.min(edge || maxEdge, maxEdge);
  for (const q of QUALITY_LADDER) steps.push({ maxEdge: firstEdge, format: 'jpeg', quality: q });
  // Then fewer pixels, at a quality that still reads as a photograph.
  for (const e of EDGE_LADDER) {
    if (e >= firstEdge) continue;
    steps.push({ maxEdge: e, format: 'jpeg', quality: 74 });
  }

  return {
    keep: false,
    steps,
    note: hasAlpha
      ? 'tries PNG first so transparency survives, then JPEG'
      : (format === 'png' ? 'converts to JPEG, which is far smaller for a photograph' : 'recompresses, then reduces size'),
  };
}

/**
 * A sentence for the shop about what happened to its picture.
 *
 * Said rather than implied. A photo that was silently recompressed is a photo a
 * shop will one day notice looks worse than the file on its disk, and wonder
 * what else Khayt changed without saying.
 */
function describeResult(result) {
  if (!result) return '';
  if (result.keep) return 'Used as-is — already within the limit.';
  if (result.reason === 'too-many-pixels') {
    const px = result.originalWidth && result.originalHeight
      ? ` (${result.originalWidth}×${result.originalHeight})` : '';
    return `That image has too many pixels to process${px}. Export it at a smaller size and try again.`;
  }
  if (result.reason === 'unreadable') return 'Khayt could not read that as an image.';
  if (!result.ok) return 'Could not get this under the limit without ruining it. Crop it, or use a smaller picture.';
  const bits = [];
  if (result.format && result.originalFormat && result.format !== result.originalFormat) {
    bits.push(`converted to ${String(result.format).toUpperCase()}`);
  }
  if (result.width && result.originalWidth && result.width < result.originalWidth) {
    bits.push(`resized to ${result.width}×${result.height}`);
  } else if (result.quality) {
    bits.push('recompressed');
  }
  const from = Math.round((result.originalBytes || 0) / 1024);
  const to = Math.round((result.bytes || 0) / 1024);
  return `${bits.join(', ') || 'recompressed'} — ${from} KB down to ${to} KB.`;
}

module.exports = {
  fitPlan, describeResult,
  DEFAULT_MAX_EDGE, FLOOR_EDGE, FLOOR_QUALITY, QUALITY_LADDER, EDGE_LADDER,
};
