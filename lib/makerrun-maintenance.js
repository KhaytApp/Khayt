'use strict';
/**
 * MakerRun's planned-downtime gate.
 *
 * While a migration is applied by hand to the live database, EVERY makerrun.com
 * endpoint answers `503` with `error.code === "maintenance"` and a `Retry-After`
 * header. Reads included; `/auth` included.
 *
 * Khayt turned that into "Library fetch failed (HTTP 503)" — a shop told its
 * sync is broken, during a window in which nothing is broken and nothing was
 * half-written. Closing the door is what prevents a half-write.
 *
 * TWO DIFFERENT 503s, AND ONLY ONE IS WORTH RETRYING. `unavailable` means the
 * server is misconfigured and will keep saying so. `maintenance` means come back
 * shortly. They share a status, so this branches on `error.code` — never on the
 * number, which is the same rule `mfa_required` needs against a plain `forbidden`.
 *
 * Pure: takes a status, a parsed body and a header getter. No fetch, no clock.
 */

/** Is this response the planned-downtime gate, rather than a broken server? */
function isMaintenance(status, body) {
  if (Number(status) !== 503) return false;
  const code = body && body.error && body.error.code;
  return String(code || '') === 'maintenance';
}

/**
 * Seconds to wait, from `Retry-After`.
 *
 * The header is honoured rather than a back-off of our own: the server knows how
 * long its migration takes and we do not. Absent or unparseable falls back to a
 * minute — long enough not to hammer a closed door, short enough that a shop
 * retrying by hand is not waiting on us.
 *
 * `Retry-After` may also carry an HTTP date. Both forms are accepted; a date is
 * turned into seconds against `now`, which is injected so this stays testable.
 */
function retryAfterSeconds(headerValue, now) {
  const raw = String(headerValue == null ? '' : headerValue).trim();
  if (!raw) return 60;
  if (/^\d+$/.test(raw)) {
    const n = parseInt(raw, 10);
    // A huge or negative value is not a wait a person will sit through; treat it
    // as "no useful hint" rather than sleeping for a day.
    return n > 0 && n <= 3600 ? n : 60;
  }
  const at = Date.parse(raw);
  if (!Number.isFinite(at)) return 60;
  const secs = Math.round((at - (Number.isFinite(now) ? now : Date.now())) / 1000);
  return secs > 0 && secs <= 3600 ? secs : 60;
}

/**
 * The error to throw for a maintenance response.
 *
 * Carries `maintenance: true` and `retryAfter` so a caller can keep the user's
 * work and retry, instead of treating it as a failure and discarding it.
 */
function maintenanceError(retryAfter) {
  const mins = Math.max(1, Math.round(Number(retryAfter || 60) / 60));
  const e = new Error(`MakerRun is briefly unavailable for maintenance — try again in about ${mins} minute${mins === 1 ? '' : 's'}.`);
  e.maintenance = true;
  e.retryAfter = Number(retryAfter || 60);
  return e;
}

module.exports = { isMaintenance, retryAfterSeconds, maintenanceError };
