const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { COMMANDS, buildCommand, requiresJobId } = require('../lib/printer-commands.js');

/**
 * Khayt could start a print and watch it, but never stop one — there was no
 * pause/resume/cancel path for any of the six adapters. These pin the per-
 * protocol request shapes, which are otherwise only verifiable with hardware.
 */

test('Moonraker uses its dedicated print endpoints', () => {
  assert.deepEqual(buildCommand('moonraker', 'pause'), { method: 'POST', path: '/printer/print/pause' });
  assert.deepEqual(buildCommand('moonraker', 'resume'), { method: 'POST', path: '/printer/print/resume' });
  assert.deepEqual(buildCommand('moonraker', 'cancel'), { method: 'POST', path: '/printer/print/cancel' });
});

test('OctoPrint always sends an explicit action, never relying on toggle', () => {
  // With no `action`, OctoPrint TOGGLES. For an unattended shop panel that makes
  // pause and resume the same button, with the outcome depending on state the
  // caller may not have. This is the single most important detail here.
  const pause = buildCommand('octoprint', 'pause');
  assert.equal(pause.path, '/api/job');
  assert.deepEqual(pause.body, { command: 'pause', action: 'pause' });

  const resume = buildCommand('octoprint', 'resume');
  assert.deepEqual(resume.body, { command: 'pause', action: 'resume' },
    'resume is the same command with a different action, not a different command');

  assert.deepEqual(buildCommand('octoprint', 'cancel').body, { command: 'cancel' });
});

test('PrusaLink keys its endpoints by the live job id', () => {
  assert.deepEqual(buildCommand('prusalink', 'pause', 42),
    { method: 'PUT', path: '/api/v1/job/42/pause', needsJobId: true });
  assert.deepEqual(buildCommand('prusalink', 'resume', 42),
    { method: 'PUT', path: '/api/v1/job/42/resume', needsJobId: true });
  assert.deepEqual(buildCommand('prusalink', 'cancel', 42),
    { method: 'DELETE', path: '/api/v1/job/42', needsJobId: true });
});

test('PrusaLink declines rather than guessing when no job is running', () => {
  // Buddy 404s on a stale id, so a missing one must not be papered over.
  for (const id of [null, undefined, '']) {
    assert.match(buildCommand('prusalink', 'pause', id).unsupported, /no active job/);
  }
});

test('a job id is escaped, not interpolated raw', () => {
  const req = buildCommand('prusalink', 'cancel', '7/../../admin');
  assert.ok(!req.path.includes('../'), `path traversal survived: ${req.path}`);
});

test('only PrusaLink needs a job id fetched first', () => {
  assert.equal(requiresJobId('prusalink'), true);
  for (const t of ['moonraker', 'octoprint', 'duet', 'repetier', 'bambu']) {
    assert.equal(requiresJobId(t), false, `${t} should not need a job id`);
  }
});

test('Duet has no REST job control — it is G-code, on whichever surface answers', () => {
  // Standalone RepRapFirmware: the code rides in the query string.
  assert.equal(buildCommand('duet', 'pause', null, { duetFlavour: 'standalone' }).path, '/rr_gcode?gcode=M25');
  assert.equal(buildCommand('duet', 'resume', null, { duetFlavour: 'standalone' }).path, '/rr_gcode?gcode=M24');

  // A Duet 3 with an SBC has no rr_gcode AT ALL — DSF's own REST documentation
  // says its endpoints "differ from those provided by RepRapFirmware's native
  // network interface". Every command Khayt sent such a machine 404'd, while
  // the poller watched it happily over machine/model. The code goes in the
  // BODY, as text/plain.
  const sbc = buildCommand('duet', 'pause', null, { duetFlavour: 'sbc' });
  assert.equal(sbc.method, 'POST');
  assert.equal(sbc.path, '/machine/code');
  assert.equal(sbc.body, 'M25');
  assert.equal(sbc.contentType, 'text/plain');
  assert.ok(!/rr_gcode/.test(JSON.stringify(sbc)), 'the standalone path must not leak onto the SBC surface');

  // Standalone is assumed when nothing says otherwise — it is the far more
  // common build, and it is what every existing caller got before.
  assert.equal(buildCommand('duet', 'pause').path, '/rr_gcode?gcode=M25');
});

test('Duet cancel is M25 then M0, because that is what Duet\'s own UI does', () => {
  // DuetWebControl renders pause/resume as M25/M24, and renders the cancel
  // button ONLY when the machine is already paused (`v-if="isPaused"`,
  // `code="M0"`). It never offers M0 to a running print. Khayt sent a bare M0
  // into one regardless.
  for (const flavour of ['standalone', 'sbc']) {
    const req = buildCommand('duet', 'cancel', null, { duetFlavour: flavour });
    assert.equal(req.sequence.length, 2, `${flavour}: cancel is two codes`);
    const codes = req.sequence.map((s) => (s.body || decodeURIComponent(s.path)).replace(/.*gcode=/, ''));
    assert.deepEqual(codes, ['M25', 'M0'], `${flavour}: pause first, then stop`);
  }

  // Sent as two requests rather than one newline-joined payload: whether both
  // surfaces split a multi-code body identically is not testable on this bench,
  // and two requests need no such assumption.
  const std = buildCommand('duet', 'cancel', null, { duetFlavour: 'standalone' });
  assert.ok(std.sequence.every((s) => !/%0A|\n/.test(s.path + (s.body || ''))), 'no code is newline-joined');
});

test('an unknown Duet transport is refused, not silently sent somewhere', () => {
  const req = buildCommand('duet', 'pause', null, { duetFlavour: 'carrier-pigeon' });
  assert.match(req.unsupported, /unknown Duet transport/);
  assert.equal(req.path, undefined, 'nothing to send is better than something to guess');
});

test('Repetier can resume and cancel, and says precisely why it cannot pause', () => {
  // stopJob and continueJob take NO parameters, which is what makes them
  // shippable without a Repetier on the bench: there is no parameter-passing
  // convention left to guess at.
  assert.equal(
    buildCommand('repetier', 'cancel', null, { printerSlug: 'irapid' }).path,
    '/printer/api/irapid?a=stopJob',
  );
  assert.equal(
    buildCommand('repetier', 'resume', null, { printerSlug: 'irapid' }).path,
    '/printer/api/irapid?a=continueJob',
  );

  // THE TRAP. Read alone, "stopJob" beside "continueJob" reads like a
  // pause/resume pair — one reading of the vendor's prose concluded exactly
  // that. It is wrong: RepetierSharp models PauseJob, StopJob and ContinueJob
  // as three distinct operations, and pause is `send { cmd: "@pause …" }`.
  // Acting on the misreading would make Cancel pause and Pause end the print,
  // so this asserts the mapping rather than trusting anyone to remember it.
  assert.match(buildCommand('repetier', 'cancel', null, {}).path, /a=stopJob/, 'cancel is stopJob, never continueJob');
  assert.ok(!/continueJob/.test(buildCommand('repetier', 'cancel', null, {}).path));

  // Pause needs the `send` action to carry a `cmd`, and how the HTTP interface
  // passes parameters is the one thing the audit could not settle — the
  // vendor's own demo client is a websocket client, so it cannot answer for
  // HTTP. Declining names the limit rather than guessing at a string to push
  // into a running print.
  const paused = buildCommand('repetier', 'pause', null, { printerSlug: 'irapid' });
  assert.match(paused.unsupported, /not supported yet/);
  assert.match(paused.unsupported, /resume or cancel/, 'and says what it CAN do');
  assert.equal(paused.path, undefined);

  // An unconfigured slug still produces a request; "default" is what the poller
  // falls back to as well.
  assert.equal(buildCommand('repetier', 'cancel').path, '/printer/api/default?a=stopJob');
  // And a slug is escaped, never interpolated raw.
  assert.match(buildCommand('repetier', 'cancel', null, { printerSlug: 'a b/c' }).path, /a%20b%2Fc/);
});

test('protocols that genuinely cannot do this say why', () => {
  // An honest refusal beats a request built on a guess and sent at a running print.
  assert.match(buildCommand('repetier', 'pause').unsupported, /not supported yet/);
  assert.match(buildCommand('bambu', 'pause').unsupported, /Bambu Connect/);
  assert.match(buildCommand('', 'pause').unsupported, /unknown printer type/);
});

test('an unknown command is refused before any request is built', () => {
  for (const bad of ['stop', 'DROP TABLE', '', null, 'start']) {
    const r = buildCommand('moonraker', bad);
    assert.ok(r.unsupported, `built a request for "${bad}"`);
  }
  assert.deepEqual([...COMMANDS], ['pause', 'resume', 'cancel']);
});

test('the handler is wired through main and the preload bridge', () => {
  // Renderer files are plain scripts and main/preload are separate contexts, so
  // a module that exists but is never reachable is a real failure mode here.
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const preload = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  assert.match(main, /ipcMain\.handle\('hub:printer-command'/, 'no IPC handler in main');
  assert.match(main, /require\('\.\/lib\/printer-commands'\)/, 'main never requires the module');
  assert.match(preload, /hub:printer-command/, 'not exposed on the preload bridge');
});

test('the command path reuses the SSRF host allowlist', () => {
  // This reaches a LAN device on the user's behalf; it must not be steerable off
  // the validated address any more than the status poller is.
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const fn = main.slice(main.indexOf('async function sendPrinterCommand'),
                        main.indexOf("ipcMain.handle('hub:printer-command'"));
  assert.match(fn, /resolvePrinterTarget\(host\)/, 'no resolved-and-pinned LAN host check');
  assert.match(fn, /redirect: 'manual'/, 'redirects are not pinned');
});
