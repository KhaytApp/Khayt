/**
 * The half of the poller that lives in main.js, and cannot be called from here.
 *
 * `fetchPrinterStatus` is an Electron main-process function that opens sockets;
 * it is not exported and there is nothing to require. The pure parsing it hands
 * off to is properly tested — lib/repetier.js in test/repetier.test.js,
 * lib/duet.js in test/duet.test.js, the shared normalisers in
 * test/printer-status.test.js. What is left in main.js is the ORCHESTRATION:
 * which endpoints are asked for, and which failures are allowed to be survived.
 *
 * That orchestration is where the defects found in the 2026-08-27 audit passes
 * actually lived, so it gets a guard even though a source scan is the weakest
 * kind of test there is. Each assertion below is written to fail if the
 * behaviour is removed, not merely if the wording changes.
 *
 * A caution recorded with them: these read one named file, deliberately. Tests
 * in this repo that walk the whole directory can pass locally against the stray
 * checkouts sitting in the working root and fail in CI.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

/**
 * The body of one `if (type === '<x>') { … }` branch in fetchPrinterStatus.
 *
 * Anchored on the function, not on the first match in the file: main.js also
 * switches on `type` when UPLOADING to a printer, and that branch is the one a
 * naive search finds first. A guard that reads the wrong function proves
 * nothing about the one it names.
 */
function branch(type) {
  const poller = main.indexOf('async function fetchPrinterStatus(');
  assert.notEqual(poller, -1, 'fetchPrinterStatus has been renamed');
  const start = main.indexOf(`if (type === '${type}') {`, poller);
  assert.notEqual(start, -1, `no ${type} branch in fetchPrinterStatus`);
  const end = main.indexOf("\n  if (type === '", start + 10);
  return main.slice(start, end === -1 ? start + 4000 : end);
}

test('OctoPrint survives the 409 it answers whenever no printer is connected', () => {
  // GET /api/printer is guarded by `abort(409, "Printer is not operational")` in
  // OctoPrint's server/api/printer.py — in the 1.11 line and the 2.0 line alike.
  // Awaiting it together with /api/job failed the whole poll on that 409, so a
  // shop with OctoPrint running and the printer switched off saw an error where
  // "Offline" belonged. GET /api/job carries no such guard and answers fine.
  const octo = branch('octoprint');
  assert.match(octo, /\/api\/job/, 'the job is still asked for');
  assert.match(
    octo,
    /get\('\/api\/printer'\)\.catch\([^)]*\)/s,
    '/api/printer must be asked for tolerantly, not awaited bare',
  );
  assert.match(octo, /status === 409/, 'and only 409 may be survived');
  assert.match(octo, /throw e/, 'every other status is still a fault');
  // What is DONE with the two payloads moved to lib/octoprint.js, where it can
  // be driven with per-endpoint bodies instead of scanned for. That the null
  // printer payload is tolerated is asserted there, on the real function —
  // see test/octoprint.test.js.
  assert.match(octo, /octoprint\.readStatus\(printer, job\)/,
    'the reading is the shared module\'s, and both payloads reach it');
});

test('Repetier asks for the call the job is actually on', () => {
  // `done` and `job` are on ?a=listPrinter. They are not on ?a=stateList, and
  // reading them from there is why every Repetier machine reported Idle / 0%.
  const rep = branch('repetier');
  assert.match(rep, /a=stateList/, 'the machine state');
  assert.match(rep, /a=listPrinter/, 'the job state — the call that was missing');
  assert.match(rep, /KhaytRepetier\.repetierStatus/, 'parsing belongs in lib/repetier.js');
  // Losing the job must not cost the temperatures, the rule PrusaLink follows.
  assert.match(rep, /a=listPrinter[^\n]*\.catch\(/, 'the listing is allowed to fail on its own');
  assert.ok(!/state\.done|state\.job\b/.test(rep), 'nothing may be read off the state object again');
  assert.match(main, /require\('\.\/lib\/repetier'\)/, 'and the module is wired in');
});

test('a refused poll is explained in the vendor’s terms, with its own body', () => {
  // `HTTP 409` is rendered verbatim on the dashboard card. The body is where the
  // vendors put the useful half, so it has to be read before the message is
  // built — and failing to read it must not turn a 409 into a network error.
  const get = main.slice(main.indexOf('const get = async (p, extraHeaders)'));
  assert.match(get, /explainPrinterHttp\(type, res\.status, body\)/);
  assert.match(get, /res\.text\(\)\.catch\(/, 'reading the body cannot itself fail the poll');
  assert.match(get, /\|\| `HTTP \$\{res\.status\}`/, 'an unexplained status still says what it was');
  assert.match(get, /e\.status = res\.status/, 'the Duet transport probe still needs the number');
});


test('job control speaks both Duet surfaces, exactly as the poller does', () => {
  // The defect: the poller learned the SBC transport and the session handshake
  // when Duet 3 + SBC support landed, and job control did not. So a machine
  // Khayt could watch perfectly could not be paused — every command went to
  // `rr_gcode`, which does not exist on that surface — and a password-protected
  // Duet refused every command with a 401 nobody could act on.
  //
  // These assert that the command path uses the SAME helpers as the poll path
  // rather than a second copy of the same knowledge, because two copies is what
  // drifted in the first place.
  const cmd = main.slice(
    main.indexOf('async function sendPrinterCommand('),
    main.indexOf("ipcMain.handle('hub:printer-command'"),
  );
  assert.ok(cmd.length > 0, 'sendPrinterCommand has been renamed');

  assert.match(cmd, /duetFlavourFor\(base\)/, 'both surfaces are tried, most likely first');
  assert.match(cmd, /rememberDuetFlavour\(base, flavour\)/, 'and the answer is remembered, as the poller does');
  assert.match(cmd, /duetFlavour: flavour/, 'the descriptor is built for the surface being tried');
  assert.match(cmd, /X-Session-Key/, 'a password-protected Duet gets its session key');
  assert.match(cmd, /rrConnectResult|dsfConnectResult/, 'and the handshake is parsed by lib/duet.js, not re-implemented');
  assert.match(cmd, /ENDPOINTS\[flavour\]\.unauthorized/, 'only a refusal earns the handshake — 401 standalone, 403 SBC');

  // A Duet takes text/plain. Encoding a string as JSON would send "M25" with
  // quotes to a firmware expecting M25.
  assert.match(cmd, /typeof req\.body === 'string' \? req\.body : JSON\.stringify/, 'a text/plain body is not JSON-encoded');
  // Cancel is two requests; a descriptor may carry a sequence.
  assert.match(cmd, /Array\.isArray\(req\.sequence\)/, 'a multi-step command is run in order');
});

test('a carrier webhook tells an unreadable body apart from an unknown order', () => {
  // These were one branch answering 200 "ignored", on one comment about not
  // leaking order existence. That reason covers the ORDER lookup and not the
  // parse: reaching the parse means the HMAC matched, so it genuinely is the
  // carrier sending something Khayt cannot read. Answering "received, handled"
  // to that hid a broken integration completely — the shop saw shipments that
  // never advanced, which is what a silent carrier looks like too.
  const lanServer = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');
  const at = lanServer.indexOf("const carrierId = pathname.split('/').pop()");
  assert.notEqual(at, -1, 'the carrier webhook handler has moved');
  // Sized to the whole handler with room to spare, and measured rather than
  // guessed: the first version of this cut at 4000 characters and missed the
  // `idx < 0` branch by 400 once the comments explaining the split were added.
  const body = lanServer.slice(at, at + 8000);

  // Unreadable, but authentic → 422, so it lands in the carrier's own dashboard.
  assert.match(body, /res\.writeHead\(422/, 'an unreadable payload is reported, not swallowed');
  assert.match(body, /Signature valid, but this payload carried no tracking number/);

  // Unknown order → still 200, because THAT is the case that would leak which
  // tracking numbers this shop holds. The lookup is `lib/carrier-webhook.js`
  // now; the handler writes only on `advanced` and answers 200 otherwise, and
  // `carrier-webhook.test.js` sends an unknown parcel over HTTP to prove it.
  const gate = body.indexOf("outcome === 'advanced'");
  assert.notEqual(gate, -1, 'the handler no longer answers an unknown parcel without writing');
  assert.match(body.slice(gate, gate + 2000), /writeHead\(200/);

  // And the signature check still comes first — a 422 must never be reachable
  // by an unsigned caller probing for a response that differs.
  assert.ok(body.indexOf('Invalid signature') < body.indexOf('422'), 'signature is verified before any parse');
});
