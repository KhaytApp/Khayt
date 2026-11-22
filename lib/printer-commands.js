/**
 * Job control — pause, resume, cancel — per printer protocol.
 *
 * Khayt could start a print and watch it, but never stop one: there was no
 * pause/resume/cancel path for any of the six adapters. This module holds the
 * per-protocol request shapes so they can be tested without a printer on the
 * bench; main.js performs the fetch (HTTP), and the Mac app
 * carries the MQTT and SDCP ones too.
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
   * Bambu: MQTT, not HTTP — `print.pause` / `print.resume` / `print.stop`,
   * published to `device/<serial>/request`.
   *
   * THE OLD REFUSAL WAS WRONG FOR THE ONE PRINTER KHAYT CAN READ. This used to
   * say "Bambu requires Bambu Connect for remote job control" for every Bambu.
   * Bambu's own wiki says Developer Mode "opens the MQTT channel … full
   * control" on the LAN (wiki.bambulab.com/en/knowledge-sharing/enable-developer-mode),
   * and Developer Mode is already what Khayt needs to READ a Bambu at all — a
   * printer without it accepts the connection and says nothing. So the command
   * is built, and only the printer's own refusal (`result: "fail"`) is reported
   * as one.
   *
   * The shape is OpenBambuAPI `mqtt.md` (`print.stop`, `print.pause`,
   * `print.resume`: `{"print":{"sequence_id":"0","command":"…","param":""}}`,
   * "param … Always empty"), and the same verbs ha-bambulab sends
   * (`pybambu/commands.py` PAUSE / RESUME / STOP). Cancel is `stop`: Bambu has
   * no other verb for ending a job.
   *
   * `sequence_id` is a STRING on the wire and is "Incremented by 1 on each
   * command" per OpenBambuAPI; the printer echoes it in its reply, which is how
   * the caller knows which reply is this command's. The caller owns the
   * counter (one per connection).
   *
   * The payload is returned already serialised so both apps put the same bytes
   * on the wire — a JSON writer that reorders keys is a second encoding.
   */
  function bambu(command, opts) {
    const seq = opts && opts.sequenceId != null ? String(opts.sequenceId) : '0';
    if (!/^\d{1,10}$/.test(seq)) return { unsupported: 'invalid sequence id' };
    const verb = command === 'cancel' ? 'stop' : command;
    const payload = JSON.stringify({ print: { sequence_id: seq, command: verb, param: '' } });
    return { mqtt: { topic: 'request', section: 'print', command: verb, sequenceId: seq, payload } };
  }

  /**
   * Elegoo SDCP v3 (resin): a WebSocket frame. Pause 129, Stop 130, Continue
   * 131 — "Pause Printing(Cmd: 129)", "Stop Printing(Cmd: 130)", "Continue
   * Printing(Cmd: 131)" in cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0,
   * each with an empty inner `Data: {}` and a reply on `sdcp/response/<id>`
   * carrying `Data.Data.Ack` (0 = success).
   *
   * Built through `KhaytSdcp.buildRequest`, the one place the nested-`Data`
   * envelope is written, and serialised here for the same reason as Bambu's.
   * The mainboard id is the address on this protocol; without it there is
   * nothing to send to.
   */
  function sdcp(command, opts) {
    const KhaytSdcp = (typeof require !== 'undefined')
      ? require('./sdcp')
      : (typeof globalThis !== 'undefined' ? globalThis.KhaytSdcp : undefined);
    if (!KhaytSdcp) return { unsupported: 'SDCP module not loaded' };
    const mainboardId = opts && opts.mainboardId ? String(opts.mainboardId).trim() : '';
    if (!mainboardId) return { unsupported: 'This printer needs its mainboard ID before it can be told anything' };
    const cmd = command === 'pause' ? KhaytSdcp.CMD.PAUSE
      : command === 'resume' ? KhaytSdcp.CMD.RESUME : KhaytSdcp.CMD.STOP;
    const frame = KhaytSdcp.buildRequest(cmd, {
      mainboardId,
      requestId: opts.requestId || undefined,
      timestamp: opts.timestamp,
    });
    return { sdcp: { cmd, requestId: frame.Data.RequestID, frame: JSON.stringify(frame) } };
  }

  /**
   * Build the request for a command, or explain why it cannot be built.
   *
   * `jobId` is only consulted for PrusaLink, `opts.duetFlavour` only for Duet,
   * `opts.printerSlug` only for Repetier, `opts.sequenceId` only for Bambu, and
   * `opts.mainboardId` / `opts.requestId` / `opts.timestamp` only for SDCP.
   *
   * `opts.transports` lists the transports the CALLER can perform —
   * `'http'`, `'mqtt'`, `'sdcp'`. Absent means `['http']`, today's behaviour:
   * desktop main.js performs only HTTP descriptors and shows a card's buttons
   * whenever `unsupported` is falsy, so Bambu and SDCP stay `{ unsupported }`
   * for it until it passes `'mqtt'` / `'sdcp'`. A Bambu descriptor is `{ mqtt: { payload, … } }` and
   * an SDCP one `{ sdcp: { frame, … } }`; neither has a method or a path.
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
      // Not HTTP. Built only for a caller that says it can carry the transport
      // (`opts.transports`), so an HTTP-only caller is refused in words rather than
      // handed a descriptor with no method and no path to fetch.
      case 'bambu':
        if (!transports(opts, 'mqtt')) return { unsupported: 'This app cannot send job commands to a Bambu printer yet' };
        return bambu(command, opts);
      case 'sdcp':
        if (!transports(opts, 'sdcp')) return { unsupported: 'This app cannot send job commands to an Elegoo resin printer yet' };
        return sdcp(command, opts);
      default:          return { unsupported: `unknown printer type: ${type || 'none'}` };
    }
  }

  function transports(opts, transport) {
    return !!(opts && Array.isArray(opts.transports) && opts.transports.includes(transport));
  }

  /**
   * Bambu machine controls beyond the job verbs: the speed preset and the
   * chamber light. Same transport gate as `buildCommand` (`opts.transports`
   * must include 'mqtt'); `opts.sequenceId` as there.
   *
   *   speed  value 1 silent · 2 standard · 3 sport · 4 ludicrous.
   *          OpenBambuAPI mqtt.md `print.print_speed`: `param` is "Print speed
   *          level as a string"; ha-bambulab SPEED_PROFILE_TEMPLATE is the same
   *          object. Needs LAN/Developer Mode, like every MQTT command here.
   *   light  value 'on' | 'off'. OpenBambuAPI `system.ledctrl` with
   *          `led_node: "chamber_light"`; the flashing fields "required to be
   *          present always", with ha-bambulab CHAMBER_LIGHT_ON/OFF's values
   *          (500, 500, 0, 0).
   *
   * Anything else, or any other protocol, is `{ unsupported }`. The value is
   * checked against the closed set, so a field's text never reaches the wire.
   * The reply comes back under the same top-level key (`print` / `system`),
   * which is returned as `mqtt.section` for the caller's reply matching.
   */
  const SPEEDS = Object.freeze({ 1: 'silent', 2: 'standard', 3: 'sport', 4: 'ludicrous' });

  function buildControl(type, control, value, opts = {}) {
    if (type !== 'bambu') return { unsupported: `${control} is not available for this printer type` };
    if (!transports(opts, 'mqtt')) return { unsupported: 'This app cannot send commands to a Bambu printer yet' };
    const seq = opts.sequenceId != null ? String(opts.sequenceId) : '0';
    if (!/^\d{1,10}$/.test(seq)) return { unsupported: 'invalid sequence id' };
    if (control === 'speed') {
      const level = Number(value);
      if (!Number.isInteger(level) || !SPEEDS[level]) return { unsupported: 'speed must be 1, 2, 3 or 4' };
      const payload = JSON.stringify({ print: { sequence_id: seq, command: 'print_speed', param: String(level) } });
      return { mqtt: { topic: 'request', section: 'print', command: 'print_speed', sequenceId: seq, payload } };
    }
    if (control === 'light') {
      if (value !== 'on' && value !== 'off') return { unsupported: "light must be 'on' or 'off'" };
      const payload = JSON.stringify({ system: {
        sequence_id: seq, command: 'ledctrl', led_node: 'chamber_light', led_mode: value,
        led_on_time: 500, led_off_time: 500, loop_times: 0, interval_time: 0,
      } });
      return { mqtt: { topic: 'request', section: 'system', command: 'ledctrl', sequenceId: seq, payload } };
    }
    return { unsupported: `unknown control: ${control}` };
  }

  /** Does this protocol need the current job id fetched first? */
  function requiresJobId(type) {
    return type === 'prusalink';
  }

  /**
   * Can this protocol do this command AT ALL — the question a button asks
   * before it is drawn, not the one a press asks of a particular job.
   *
   * Answered by building the command and seeing whether it comes back
   * `unsupported`, so there is one table of what each protocol can do and not
   * a second list beside it that drifts. The job id is a stand-in because
   * PrusaLink's endpoints are keyed by one and say "no active job" without it,
   * which is a fact about this moment and not about the protocol.
   */
  function supports(type, command, opts) {
    // SDCP's mainboard id is the same kind of fact as PrusaLink's job id: one
    // printer's, read at press time, and nothing to do with the protocol.
    const o = Object.assign({ mainboardId: '0' }, opts || {});
    const built = buildCommand(type, command, requiresJobId(type) ? '0' : null, o);
    return !!built && !built.unsupported;
  }

  const api = { COMMANDS, SPEEDS, buildCommand, buildControl, requiresJobId, supports };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrinterCommands = api;

  })(typeof globalThis !== 'undefined' ? globalThis : this);
