'use strict';
(function () {

/**
 * Scan-code router — classify a scanned/typed string into a Khayt action.
 * Closes the loop with the printed labels (lib/labels.js): spool labels encode
 * "KHAYT-SPOOL:<id>", order labels "KHAYT-ORDER:<id>" or the customer tracking
 * URL ".../p/<token>". Anything else falls through to the filament text parser.
 *
 * Pure (no I/O) so it's unit-testable; the renderer maps the result to an action
 * (open the spool / open the order).
 */
function parseScanCode(text) {
  const s = String(text == null ? '' : text).trim();
  if (!s) return { type: 'empty' };

  let m = /^KHAYT-SPOOL:(.+)$/i.exec(s);
  if (m) return { type: 'spool', id: m[1].trim() };

  m = /^KHAYT-ORDER:(.+)$/i.exec(s);
  if (m) return { type: 'order', id: m[1].trim() };

  // Customer tracking link → the order's public token.
  m = /\/p\/([A-Za-z0-9_\-]+)\/?$/.exec(s);
  if (m) return { type: 'track', token: m[1] };

  return { type: 'unknown', raw: s };
}

const api = { parseScanCode };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytScan = api;

})();
