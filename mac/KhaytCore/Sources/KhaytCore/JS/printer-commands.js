/**
 * Job control — pause, resume, cancel — per printer protocol.
 *
 * Khayt could start a print and watch it, but never stop one: there was no
 * pause/resume/cancel path for any of the six adapters. This module holds the
 * per-protocol request shapes so they can be tested without a printer on the
 * bench; main.js performs the fetch.
 *
 * Each builder returns a descriptor:
 *   { method, path, headers?, body?, contentType? }
 * or { unsupported: reason } when the protocol genuinely cannot do it.
 *
 * PrusaLink additionally sets { needsJobId: true } — its endpoints are keyed by
 * the current job id, which must be fetched immediately before the call.
 *
 * ── WRAPPED, BECAUSE THE MAC APP LOADS IT TOO ─────────────────────────────
 *
 * This was written as a Node module: bare top-level bindings and a closing
 * `module.exports`. The native Mac app runs these rules in JavaScriptCore,
 * which has no `module` at all — loading it there failed on the first line with
 * `Can't find variable: module`, and the app could not tell a printer anything.
 *
 * So it takes the shape every other shared module has: an IIFE that assigns a
 * global and ALSO sets `module.exports` when there is one, which is what keeps
 * `main.js` working unchanged.
 */
(function (global) {

  const COMMANDS = Object.freeze(['pause', 'resume', 'cancel']);

  // Duet's two transports live in lib/duet.js, next to the poller that already
  // speaks both. Requiring it here rather than restating the paths is the whole
  // point: the defect this fixes was the same knowledge written down twice.
  const KhaytDuet = (typeof require !== 'undefined')
    ? require('./duet')
    : (typeof globalThis !== 'undefined' ? globalThis.KhaytDuet : undefined);

  /** Moonraker: plain POSTs, response wrapped as {"result": "ok"}. */
  function moonraker(command) {
    return { method: 'POST', path: `/printer/print/${command}` };
  }

  /**
   * OctoPrint: one endpoint, command in the body.
   *
   * The `action` is always sent explicitly. OctoPrint's default when it is
   * omitted is *toggle*, which for an unattended shop panel means "pause" and
   * "resume" become the same button and the result depends on state the caller
   * may not have. Never rely on that default.
   */
  function octoprint(command) {
    const body = command === 'cancel'
      ? { command: 'cancel' }
      : { command: 'pause', action: command === 'pause' ? 'pause' : 'resume' };
    return { method: 'POST', path: '/api/job', body, contentType: 'application/json' };
  }

  /**
   * PrusaLink: endpoints keyed by the current job id.
   *
   * Buddy returns 404 when the id does not match the job actually running, so the
   * id must be read immediately before use and never cached across jobs.
   */
  function prusalink(command, jobId) {
    if (jobId == null || jobId === '') return { unsupported: 'no active job' };
    const id = encodeURIComponent(String(jobId));
    if (command === 'cancel') return { method: 'DELETE', path: `/api/v1/job/${id}`, needsJobId: true };
    return { method: 'PUT', path: `/api/v1/job/${id}/${command}`, needsJobId: true };
  }

  /**
   * Duet: no REST job control — it is G-code. M25 pause, M24 resume, M0 stop.
   *
   * TWO THINGS THIS GOT WRONG, BOTH FOUND IN THE 2026-08-27 COMMAND-PATH AUDIT.
   *
   * **The transport.** This built `/rr_gcode?…` unconditionally, which is the
   * RepRapFirmware standalone surface. A Duet 3 with an SBC attached does not
   * have it — DSF's REST documentation says outright that "these endpoints differ
   * from those provided by RepRapFirmware's native network interface" — so on a
   * machine the poller had been watching happily since the SBC transport landed,
   * every pause and every cancel 404'd. The transports are now asked for by name,
   * from the same table in lib/duet.js the poller reads, so there is one place to
   * be wrong rather than two to drift.
   *
   * **Cancel is two codes, not one.** Duet's own web interface renders pause and
   * resume as M25 / M24 — and renders the cancel button ONLY when the machine is
   * already paused (`v-if="isPaused"`, `code="M0"`). It never offers M0 to a
   * running print. Khayt sent a bare M0 into one regardless, so the sanctioned
   * sequence is followed instead: M25, then M0.
   *
   * Sent as two requests rather than one newline-joined code, deliberately.
   * Whether both surfaces split a multi-code payload the same way is not
   * something this bench can test, and there is no Duet here — two requests need
   * no such assumption. If the second fails, the machine is left PAUSED, which is
   * a safe place for a print to sit and is reported rather than hidden.
   */
  /**
   * Repetier: two of the three, and the third is declined for a reason that is
   * now precise rather than blanket.
   *
   * This used to refuse everything, saying Repetier's commands were "documented
   * only in a manual I could not verify against source". Two of them can now be
   * sourced properly, and the audit that closed that gap is worth summarising
   * because the answer was NOT what the vendor's prose first suggested.
   *
   *   stopJob      no parameters. Repetier's own API reference: "Stops the
   *                running print!" — a cancel.
   *   continueJob  no parameters. "Continues the paused print!" — a resume.
   *   pause        NOT an action at all. RepetierSharp, a typed client for this
   *                server, implements `PauseJob(reason)` as
   *                `send { cmd: "@pause <reason>" }` — the Repetier host command,
   *                pushed through the generic g-code action.
   *
   * The trap avoided: read alone, "stopJob" beside "continueJob" reads like a
   * pause/resume pair, and one summary of the documentation concluded exactly
   * that. It is wrong — RepetierSharp models `PauseJob`, `StopJob` and
   * `ContinueJob` as three distinct operations — and acting on it would have made
   * Khayt's Cancel button pause, and its Pause button end the print.
   *
   * WHY PAUSE IS STILL DECLINED. It needs the `send` action to carry a `cmd`
   * parameter, and how the HTTP interface passes parameters is the one thing this
   * audit could not settle. The reference says additional parameters are query
   * parameters; the vendor's own demo client is a WEBSOCKET client, where they
   * travel in a JSON `data` object, so it cannot answer for HTTP. stopJob and
   * continueJob take no parameters at all, so they are unambiguous either way —
   * which is exactly why those two can ship and pause cannot. A wrong guess here
   * does not fail loudly: it sends some other string to a running print.
   *
   * Resume is worth having without pause. A print can be paused by the machine
   * itself — a filament runout, an M600 — or from Repetier's own interface, and
   * this is then the button that gets it going again.
   */
  function repetier(command, printerSlug) {
    if (command === 'pause') {
      return { unsupported: 'Pausing a Repetier print is not supported yet — Khayt can resume or cancel one' };
    }
    const slug = encodeURIComponent(String(printerSlug || 'default'));
    const action = command === 'cancel' ? 'stopJob' : 'continueJob';
    // GET, though the vendor sanctions either: "You can use GET or POST just as
    // you like." GET is the shape already proven against a real server by the
    // status poller, which reaches this same `/printer/api/<slug>?a=…` endpoint
    // every thirty seconds. With no Repetier here to test against, matching the
    // request that is known to work beats being tidier about verbs.
    return { method: 'GET', path: `/printer/api/${slug}?a=${action}` };
  }

  function duet(command, flavour) {
    const build = (gcode) => KhaytDuet.duetCodeRequest(flavour || 'standalone', gcode);
    if (command === 'cancel') {
      const steps = [build('M25'), build('M0')];
      const bad = steps.find((s) => s.unsupported);
      return bad || { sequence: steps };
    }
    return build(command === 'pause' ? 'M25' : 'M24');
  }

  /**
   * Build the request for a command, or explain why it cannot be built.
   *
   * `jobId` is only consulted for PrusaLink, `opts.duetFlavour` only for Duet, and
   * `opts.printerSlug` only for Repetier.
   *
   * A descriptor may carry `sequence: [descriptor, …]` instead of a single
   * request, for a command that is genuinely more than one call. The caller runs
   * them in order and stops at the first failure.
   */
  function buildCommand(type, command, jobId, opts = {}) {
    if (!COMMANDS.includes(command)) return { unsupported: `unknown command: ${command}` };
    switch (type) {
      case 'moonraker': return moonraker(command);
      case 'octoprint': return octoprint(command);
      case 'prusalink': return prusalink(command, jobId);
      case 'duet':      return duet(command, opts.duetFlavour);
      case 'repetier':  return repetier(command, opts.printerSlug);
      // Bambu speaks MQTT, not HTTP, and Bambu now requires their own connector to
      // start or control a job from third-party software. Status still works.
      case 'bambu':     return { unsupported: 'Bambu requires Bambu Connect for remote job control' };
      default:          return { unsupported: `unknown printer type: ${type || 'none'}` };
    }
  }

  /** Does this protocol need the current job id fetched first? */
  function requiresJobId(type) {
    return type === 'prusalink';
  }

  const api = { COMMANDS, buildCommand, requiresJobId };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrinterCommands = api;

  })(typeof globalThis !== 'undefined' ? globalThis : this);
