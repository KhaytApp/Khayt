'use strict';
(function (global) {

/**
 * A finished print's time-lapse kept WITH the job, as proof for the customer
 * (U1 idea 3, Mac plan Nov 19; ideas only from bloodf/u1control, no code).
 *
 * lib/webcam.js already matches a job's video on the printer and LINKS it
 * (`printerTimelapse`, file names only). A link dies when the printer clears
 * its camera folder, and a printer does. This decides whether the video can
 * be COPIED into the job's attachments, and what that row says.
 *
 * ONLY ON "KEEP AS PROOF". Videos are tens of MB each, and a shop that prints
 * all day would fill a disk copying every one; the caller asks this only when
 * the shop presses the button. It never downloads: the copy is the host's
 * (the same printer pins as every printer read, no redirects, capped at
 * `maxBytes`).
 *
 *   timelapseAttach(order, match, opts)
 *     match  lib/webcam.js matchTimelapse's result, or the job's
 *            `printerTimelapse` record: { video, cover?, bytes?, machineId? }
 *     opts   { machineId, maxBytes = MAX_BYTES, stamp }  `stamp` names the
 *            copy (the host passes Date.now().toString(36)); pure, no clock
 *
 *   → { action: 'attach', row, maxBytes }
 *                                 copy it; `row` is the attachedFiles entry
 *                                 (filename, originalName, size, kind, from).
 *                                 `bytes` is the PRINTER'S CLAIM, so the host
 *                                 stops reading at `maxBytes` whatever it said,
 *                                 drops a copy that ran over, and writes `size`
 *                                 from what it actually wrote (security review
 *                                 of #2611)
 *   → { action: 'link', reason }  keep it on the printer: 'over-budget'
 *                                 (bigger than maxBytes) or 'size-unknown'
 *                                 (the printer did not say, so the copy
 *                                 could be anything)
 *   → { action: 'already', index } this video is already one of the job's files
 *   → { action: 'none' }          nothing usable to keep
 */

/** The largest video kept with a job: the mesh budget, the same ceiling as a kept model. */
const MAX_BYTES = 150 * 1024 * 1024;
const KIND = 'timelapse';

function lib(name, file) {
  if (global && global[name]) return global[name];
  if (typeof require === 'function') { try { return require(file); } catch (_) { return null; } }
  return null;
}

const str = (v) => (v == null ? '' : String(v).trim());

function timelapseAttach(order, match, opts = {}) {
  const W = lib('KhaytWebcam', './webcam.js');
  const m = match && typeof match === 'object' ? match : null;
  const video = m ? str(m.video) : '';
  if (!video || !/\.mp4$/i.test(video) || (W && typeof W.safeCameraFile === 'function' && !W.safeCameraFile(video))) {
    return { action: 'none' };
  }
  const machineId = str(opts.machineId || (m && m.machineId));
  const files = order && Array.isArray(order.attachedFiles) ? order.attachedFiles : [];
  const index = files.findIndex((f) => f && f.kind === KIND && f.from && f.from.video === video
    && str(f.from.machineId) === machineId);
  if (index >= 0) return { action: 'already', index };
  const bytes = Number(m.bytes);
  if (m.bytes == null || !Number.isFinite(bytes) || bytes <= 0) return { action: 'link', reason: 'size-unknown' };
  const cap = Number.isFinite(Number(opts.maxBytes)) && Number(opts.maxBytes) > 0 ? Number(opts.maxBytes) : MAX_BYTES;
  if (bytes > cap) return { action: 'link', reason: 'over-budget', bytes, maxBytes: cap };
  const safeId = str(order && order.id).replace(/[^a-zA-Z0-9_-]/g, '_') || 'job';
  const stamp = str(opts.stamp).replace(/[^a-z0-9]/gi, '') || '0';
  const base = video.split('/').pop();
  return {
    action: 'attach',
    maxBytes: cap,
    row: {
      filename: `${safeId}-timelapse-${stamp}.mp4`,
      originalName: base,
      size: bytes,
      kind: KIND,
      from: { machineId, video },
    },
  };
}

const api = { MAX_BYTES, KIND, timelapseAttach };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytTimelapseAttach = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
