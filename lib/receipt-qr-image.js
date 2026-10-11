/**
 * Finding the QR code in a picture of a receipt, for the desktop's "Add from
 * receipt". What the code SAYS is lib/zatca-qr.js's `decodeTLV`; this only
 * finds it.
 *
 * The Mac reads the code with Vision. Electron's renderer has BarcodeDetector
 * on macOS only, and a Windows or Linux shop photographs receipts too, so the
 * desktop decodes in the main process with jsQR (Apache-2.0, no dependencies),
 * from the bitmap Electron's nativeImage hands back. Pure apart from the
 * decoder, which is passed in, so the test drives it with a code drawn by the
 * `qrcode` package and no Electron.
 *
 * A PHONE PHOTO IS NOT A SCAN. The code is a small part of a large picture,
 * and jsQR reads it at full size more often than at a reduced one — but a 12 MP
 * photo takes a second at full size, and a blurry one sometimes reads only
 * once it is scaled down. So each size in `edgesToTry` is tried in turn,
 * starting with the picture as taken, and the first code found wins.
 */
(function (global) {
  'use strict';

  /** Past any real camera, and nowhere near the shapes that exhaust memory
   *  (the same cap as main.js `fitImageBuffer`). */
  const MAX_MEGAPIXELS = 60;

  /**
   * The long-edge sizes to try, largest first. 0 means "as taken". A picture
   * already smaller than a size is not scaled UP to it.
   */
  function edgesToTry(width, height) {
    const w = Number(width) || 0;
    const h = Number(height) || 0;
    if (!(w > 0 && h > 0)) return [];
    if ((w * h) / 1e6 > MAX_MEGAPIXELS) return [];
    const longest = Math.max(w, h);
    return [0].concat([2400, 1600, 1000].filter((e) => e < longest));
  }

  /**
   * Electron's `toBitmap()` is BGRA on every platform it ships on; jsQR wants
   * RGBA. A copy, so the caller's buffer is left as it was.
   */
  function bgraToRgba(bgra) {
    const out = new Uint8ClampedArray(bgra.length);
    for (let i = 0; i + 3 < bgra.length; i += 4) {
      out[i] = bgra[i + 2];
      out[i + 1] = bgra[i + 1];
      out[i + 2] = bgra[i];
      out[i + 3] = bgra[i + 3];
    }
    return out;
  }

  /**
   * The text of the QR code in one RGBA bitmap, or '' when there is none.
   * `decode` is jsQR. A receipt printed light-on-dark is rare and costs a
   * second pass, so both are tried.
   */
  function findCode(rgba, width, height, decode) {
    if (typeof decode !== 'function') return '';
    if (!rgba || rgba.length < width * height * 4) return '';
    try {
      const hit = decode(rgba, width, height, { inversionAttempts: 'attemptBoth' });
      return hit && typeof hit.data === 'string' ? hit.data.trim() : '';
    } catch (e) {
      return '';
    }
  }

  const api = { MAX_MEGAPIXELS, edgesToTry, bgraToRgba, findCode };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytReceiptQrImage = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
