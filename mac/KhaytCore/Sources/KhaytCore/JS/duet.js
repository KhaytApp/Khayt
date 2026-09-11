'use strict';

(function (global) {
/**
 * Duet / RepRapFirmware — the two ways a Duet answers, and the one object model
 * behind both.
 *
 * A Duet is reachable over two entirely different HTTP surfaces depending on how
 * it was built, and Khayt only ever spoke one of them:
 *
 *   STANDALONE   RepRapFirmware serves the network itself.
 *                `rr_connect`, `rr_model?key=…&flags=…`, `rr_status`.
 *
 *   SBC          A Duet 3 with a Raspberry Pi attached. DuetWebServer serves the
 *                network and Duet Software Framework talks to the board.
 *                `machine/connect`, `machine/model`.
 *                Its own documentation is blunt about it: "these endpoints
 *                differ from those provided by RepRapFirmware's native network
 *                interface", and there is no `rr_*` compatibility layer.
 *
 * So every `rr_model` request Khayt sent to a Duet 3 + SBC — a common and
 * officially supported configuration — 404'd, both of them, and the machine read
 * as unreachable. Not degraded. Absent.
 *
 * WHAT IS SHARED, AND WHY THAT IS THE WHOLE TRICK
 *
 * The transports differ; the OBJECT MODEL does not. `job`, `heat`, `state` and
 * `tools` mean the same things and carry the same field names either way. The
 * only structural difference is the envelope: `rr_model` answers
 * `{key, flags, result:{…}}` and `machine/model` answers the model bare.
 *
 * So this file parses the model once, and the transports are reduced to "get me
 * a model". That is deliberate: two parsers would drift, and the last time two
 * implementations of one contract sat in this codebase without a test comparing
 * them, three storefronts quietly lost half their fields.
 *
 * SESSIONS
 *
 * Both surfaces are session-based and neither says so loudly.
 *
 *   Standalone   "Every request except for rr_connect returns HTTP status code
 *                401 if the client does not have a valid session." A machine with
 *                NO password auto-creates one on any request, which is why this
 *                has worked for everybody who never set `M551` — and why a shop
 *                that did set one found Khayt could not poll it at all, with no
 *                field to type the password into.
 *
 *   SBC          `machine/connect` returns a `sessionKey`; every other request
 *                needs it in `X-Session-Key` and answers 403 without it. The
 *                session lasts "at least 8 seconds", so it expires between polls
 *                as a matter of course and re-authenticating is normal operation
 *                rather than an error path.
 *
 * Field names, status codes and session behaviour here are from Duet3D's own
 * HTTP-requests wiki, the DuetSoftwareFramework REST-API wiki, and
 * RepRapFirmware's source. See docs/PRINTER-PROTOCOL-AUDIT.md.
 *
 * NOT VERIFIED AGAINST HARDWARE. There is no Duet on this bench. Every branch
 * below is reachable from a test with an injected fetch, which is the most that
 * can honestly be claimed — the same standard R7's socket layer is held to.
 */

/** `rr_connect` err codes, per the RepRapFirmware HTTP wiki. */
const RR_CONNECT_ERR = {
  0: null,                        // ok
  1: 'Duet refused the password',
  2: 'The Duet has no free client sessions — close a browser tab pointed at it',
};

/**
 * Read an `rr_connect` reply.
 *
 * `err: 0` is success and everything else is not, but the two failures need
 * different words: a wrong password is the shop's to fix, and "no more sessions"
 * is a Duet Web Control tab left open on somebody's laptop, which is not
 * obviously a Khayt problem unless Khayt says so.
 *
 * @returns {{ok: boolean, sessionKey: string|null, error: string|null}}
 */
function rrConnectResult(json) {
  // `Number(json && json.err)` would be 0 — a SUCCESS code — for a null reply,
  // because `null && …` is null and `Number(null)` is 0. That is the same trap
  // that had Klipper's "layer not set" reading as layer zero, and here it would
  // turn "the Duet said nothing" into "the Duet let us in". So `err` has to
  // arrive as an actual number on an actual object.
  const err = (json && typeof json === 'object' && typeof json.err === 'number') ? json.err : NaN;
  if (!Number.isFinite(err)) return { ok: false, sessionKey: null, error: 'Duet gave no answer to rr_connect' };
  if (err !== 0) {
    return { ok: false, sessionKey: null, error: RR_CONNECT_ERR[err] || `Duet refused the connection (err ${err})` };
  }
  // sessionKey only exists in RRF 3.5-b4 and later, and only when it was asked
  // for. Older firmware authenticates by IP, so no key is not a failure.
  const key = json && json.sessionKey;
  return { ok: true, sessionKey: key === undefined || key === null ? null : String(key), error: null };
}

/**
 * Read a `machine/connect` reply.
 *
 * DSF signals a bad password with HTTP 403 rather than a body field, so by the
 * time a body is being read the password was accepted; what remains is whether a
 * key came back at all.
 */
function dsfConnectResult(json) {
  const key = json && json.sessionKey;
  if (key === undefined || key === null || key === '') {
    return { ok: false, sessionKey: null, error: 'Duet (SBC) returned no session key' };
  }
  return { ok: true, sessionKey: String(key), error: null };
}

/**
 * Unwrap whatever a transport returned into a bare object model.
 *
 * `rr_model` wraps in `result`; `machine/model` does not. Accepting both here
 * means neither transport has to remember which it is.
 */
function objectModel(payload) {
  if (!payload || typeof payload !== 'object') return {};
  // `result` is rr_model's envelope. A bare model has no `result` key at the top
  // level — the object model's own top-level keys are boards, fans, heat, job,
  // move, network, sensors, seqs, spindles, state, tools, volumes.
  if (payload.result && typeof payload.result === 'object') return payload.result;
  return payload;
}

/**
 * A Duet's bed or tool temperature, resolved the way RepRapFirmware describes it
 * rather than by index convention.
 *
 * `heat.heaters[0]` is the bed and `heat.heaters[1]` is the hotend on a stock
 * single-tool config, and that is all it is — a stock config. RRF publishes the
 * real mapping: `heat.bedHeaters[]` holds the bed heaters' indices (documented as
 * "may be -1 if unconfigured"), and each tool lists its own in
 * `tools[].heaters[]`. A tool-only machine with the hotend on heater 0 was being
 * shown its hotend temperature labelled "bed", and its bed temperature — which it
 * does not have — labelled with whatever sat at index 1.
 *
 * Falls back to the old indices when the machine publishes no mapping, because a
 * plausible number beats a blank for the common case that was already working.
 *
 * @param {object} heat   the object model's `heat` key
 * @param {Array}  tools  the object model's `tools` key
 * @param {'bed'|'tool'} which
 * @returns {number|null} degrees C, or null when nothing is configured
 */
function duetHeaterTemp(heat, tools, which) {
  const heaters = (heat && Array.isArray(heat.heaters)) ? heat.heaters : [];
  const at = (i) => {
    const h = Number.isInteger(i) && i >= 0 ? heaters[i] : null;
    const t = h && Number(h.current);
    return Number.isFinite(t) ? t : null;
  };

  if (which === 'bed') {
    const beds = (heat && Array.isArray(heat.bedHeaters)) ? heat.bedHeaters : null;
    if (beds) {
      // -1 entries mean "not configured"; a machine with no bed reports no bed
      // rather than borrowing heater 0 from whatever else is on it.
      const idx = beds.find((i) => Number.isInteger(i) && i >= 0);
      return idx === undefined ? null : at(idx);
    }
    return at(0);
  }

  // The first heater belonging to the first configured tool. Multi-tool machines
  // get the first tool's, which is the same thing every other adapter here shows
  // and is at least a heater the machine actually has.
  if (Array.isArray(tools)) {
    for (const tool of tools) {
      const list = tool && Array.isArray(tool.heaters) ? tool.heaters : null;
      if (!list || !list.length) continue;
      const idx = list.find((i) => Number.isInteger(i) && i >= 0);
      if (idx !== undefined) return at(idx);
    }
    // Tools published, none of them heated — say so rather than falling through
    // to an index that belongs to something else.
    if (tools.length) return null;
  }
  return at(1);
}

/**
 * One Duet object model → the status shape every adapter returns.
 *
 * @param {object} payload   what the transport returned (wrapped or bare)
 * @param {object} [fileOM]  a separately-fetched `job.file`, for the standalone
 *                           transport whose live query filters it out. Ignored
 *                           when the model already carries one.
 * @param {object} [helpers] {fileProgressPct, extractActuals, stockOpts} —
 *                           injected so this module stays free of its siblings
 *                           and can be tested on its own.
 */
function statusFromObjectModel(payload, fileOM, helpers = {}) {
  const om = objectModel(payload);
  const job = (om && om.job) || {};
  // A model that carries its own file wins: that is the SBC case, and the
  // standalone case once the second query has answered. `fileOM` is the
  // standalone fallback and is itself already unwrapped by the caller.
  const file = (job.file && typeof job.file === 'object') ? job.file : (fileOM || {});
  const heat = om.heat || {};

  const pct = helpers.fileProgressPct || ((p, s) => {
    const a = Number(p), b = Number(s);
    return (!Number.isFinite(a) || !Number.isFinite(b) || b <= 0) ? 0
      : Math.min(100, Math.max(0, Math.round((a / b) * 100)));
  });

  const out = {
    state: (om.state && om.state.status) || 'Unknown',
    progress: pct(job.filePosition, file.size),
    filename: file.fileName || '',
    timeRemaining: (job.timesLeft && job.timesLeft.file) || null,
    tempNozzle: duetHeaterTemp(heat, om.tools, 'tool'),
    tempBed: duetHeaterTemp(heat, om.tools, 'bed'),
    type: 'duet',
  };
  if (helpers.extractActuals) {
    out.actuals = helpers.extractActuals('duet', om, helpers.stockOpts || {});
  }
  return out;
}

/** Where each transport's endpoints live, so the paths exist in exactly one place. */
const ENDPOINTS = {
  standalone: {
    connect: (pw) => `/rr_connect?password=${encodeURIComponent(pw || '')}&sessionKey=yes`,
    // The live query. `f` is right for the numbers that move and wrong for the
    // file, which is why the file is fetched separately — see the audit doc.
    live: '/rr_model?key=&flags=d99fn',
    file: '/rr_model?key=job.file&flags=d99n',
    legacy: '/rr_status?type=3',
    // Sending G-code. A Duet has no REST job control — pause, resume and cancel
    // are M25, M24 and M0, and they go down the same pipe as any other code.
    code: (gcode) => ({ method: 'GET', path: `/rr_gcode?gcode=${encodeURIComponent(gcode)}` }),
    // "Every request except for rr_connect returns 401 if the client does not
    // have a valid session."
    unauthorized: 401,
  },
  sbc: {
    // "If no password is expected, the `password` key can be omitted."
    connect: (pw) => (pw ? `/machine/connect?password=${encodeURIComponent(pw)}` : '/machine/connect'),
    // Returns the FULL model, so no separate file query and no `f` trap.
    live: '/machine/model',
    file: null,
    legacy: null,
    // The SBC surface has no `rr_gcode` — DSF's own REST documentation says
    // outright that "these endpoints differ from those provided by
    // RepRapFirmware's native network interface". The code goes in the BODY as
    // text/plain, not in the query string, and 403 is what a missing session
    // key earns here.
    code: (gcode) => ({ method: 'POST', path: '/machine/code', body: gcode, contentType: 'text/plain' }),
    unauthorized: 403,
  },
};

/**
 * The request that sends one G-code to a Duet, on whichever surface it answers.
 *
 * This exists so that "which transport am I on" is asked in exactly one place.
 * It was not, and the cost was concrete: the poller learned both surfaces when
 * SBC support was added, and job control did not — so a Duet 3 with an SBC
 * could be watched perfectly and could not be paused, because pause was still
 * being sent to `rr_gcode`, which does not exist there. The two paths were
 * fixed in different releases and nobody diffed them.
 */
function duetCodeRequest(flavour, gcode) {
  const ep = ENDPOINTS[flavour];
  if (!ep || !ep.code) return { unsupported: `unknown Duet transport: ${flavour}` };
  const code = String(gcode || '').trim();
  if (!code) return { unsupported: 'no G-code to send' };
  return ep.code(code);
}

/**
 * Progress from the pre-RRF-3 `rr_status?type=3` response.
 *
 * THE VENDOR'S OWN DOCUMENTATION CONTRADICTS ITSELF about this field, and
 * nobody here has a Duet to settle it against. From the Duet3D wiki's
 * JSON-responses page (fetched 2026-09-03):
 *
 *     "fractionPrinted": Fraction of the file printed on a scale of
 *     0.0 to 100.0. This equals filePosition / fileSize
 *
 * "a scale of 0.0 to 100.0" and "equals filePosition / fileSize" cannot both be
 * true — the second is a ratio between 0 and 1. The adjacent comment in the
 * same file, `// one decimal place`, leans towards 0-100: one decimal place on
 * a 0-1 fraction gives eleven possible values, which is useless for a progress
 * bar. The reprap.org mirror asserts 0-1, but reasons from the field's NAME,
 * which is the guess this exists to avoid. `fileSize` is not in the type-3
 * response, so the ratio cannot be recomputed from it either.
 *
 * Khayt multiplied by 100 unconditionally. If the 0-100 reading is right, that
 * made every print from 1% onward show as COMPLETE — clamped to 100 — on the
 * one Duet surface nobody can test.
 *
 * So: read it both ways rather than pick one. At or below 1 it is a fraction;
 * above 1 it is already a percentage. Correct under either reading except in
 * the first 1% of a print under the 0-100 reading, where it reports ahead of
 * itself — the mild error, not the one that calls a running print finished.
 *
 * @param {*} fractionPrinted the raw field
 * @returns {number} 0-100
 */
function legacyProgressPercent(fractionPrinted) {
  const n = Number(fractionPrinted);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return n <= 1 ? n * 100 : n;
}

/**
 * The pre-RRF-3 status shape, from `/rr_status?type=3`.
 *
 * The last thing tried when both object-model surfaces refuse. It predates the
 * object model entirely and exists only on standalone firmware.
 *
 * LIFTED HERE because it was built inline in `main.js`, and the Mac app needed
 * the same shape — which is the moment an inline object becomes two of them.
 * `duetCodeRequest` exists a few lines up for exactly this reason, and its own
 * comment records what the last divergence cost: "the poller learned both
 * surfaces when SBC support was added, and job control did not… a Duet 3 with
 * an SBC could be watched perfectly and could not be paused".
 *
 * @param {object} data the `rr_status` payload
 * @param {function} normalizeProgress the shared 0-100 clamp
 */
function legacyStatus(data, normalizeProgress) {
  const d = data && typeof data === 'object' ? data : {};
  const clamp = typeof normalizeProgress === 'function' ? normalizeProgress : (v) => v;
  return {
    state: d.status || 'Unknown',
    progress: clamp(legacyProgressPercent(d.fractionPrinted)),
    // This endpoint carries no filename. Empty is the honest answer; the
    // object-model surfaces are where a name comes from.
    filename: '',
    timeRemaining: null,
    tempNozzle: (d.temps && d.temps.heads && d.temps.heads.current && d.temps.heads.current[0]) || null,
    tempBed: (d.temps && d.temps.bed && d.temps.bed.current) || null,
    type: 'duet',
  };
}

const api = { rrConnectResult, dsfConnectResult, objectModel, duetHeaterTemp, statusFromObjectModel, duetCodeRequest, ENDPOINTS, RR_CONNECT_ERR, legacyProgressPercent, legacyStatus };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytDuet = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
