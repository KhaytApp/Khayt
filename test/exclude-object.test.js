'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const ex = require('../lib/exclude-object.js');

/**
 * Dropping one object from a running print.
 *
 * The command is a G-CODE SCRIPT built from a name that came out of a sliced
 * file, so most of these are about what may NOT be sent.
 */

const reply = (held) => ({ result: { status: held === undefined ? {} : { exclude_object: held } } });

const plate = reply({
  objects: [{ name: 'Crown_id_0' }, { name: 'Crown_id_1' }, { name: 'Base_id_0' }],
  excluded_objects: [],
  current_object: 'Crown_id_0',
});

test('what is on the plate, and which one is printing', () => {
  const p = ex.plate(plate);
  assert.equal(p.supported, true);
  assert.deepEqual(p.objects, ['Crown_id_0', 'Crown_id_1', 'Base_id_0']);
  assert.equal(p.current, 'Crown_id_0');
});

/// The difference a screen has to say out loud.
test('a printer that cannot do this is not a plate with nothing on it', () => {
  const none = ex.plate(reply(undefined));
  assert.equal(none.supported, false, 'a missing key read as a supported empty plate');
  assert.deepEqual(none.objects, []);

  // Configured, and genuinely nothing printing.
  const empty = ex.plate(reply({ objects: [], excluded_objects: [], current_object: null }));
  assert.equal(empty.supported, true);
  assert.deepEqual(empty.objects, []);
});

test('an object already dropped is not offered again', () => {
  const after = reply({
    objects: [{ name: 'Crown_id_0' }, { name: 'Crown_id_1' }, { name: 'Base_id_0' }],
    excluded_objects: ['Crown_id_1'],
    current_object: 'Crown_id_0',
  });
  assert.deepEqual(ex.remaining(after), ['Crown_id_0', 'Base_id_0']);
  assert.match(ex.excludeRequest('Crown_id_1', after).refused, /already/);
});

test('dropping one builds the script Klipper expects', () => {
  const req = ex.excludeRequest('Base_id_0', plate);
  assert.equal(req.method, 'POST');
  assert.equal(req.path,
    '/printer/gcode/script?script=' + encodeURIComponent('EXCLUDE_OBJECT NAME=Base_id_0'));
});

/// THE GUARD THE WHOLE MODULE IS SHAPED AROUND.
///
/// The name reaches the printer inside a G-code script. A sliced file is often
/// a stranger's, and a name carrying a newline would end that command and begin
/// another — arbitrary G-code on a hot machine. Nothing is escaped; a name that
/// the printer did not itself just report is simply refused.
test('a name the printer did not report is refused, however it is spelled', () => {
  for (const attack of [
    'Base_id_0\nM104 S300',
    'Base_id_0\r\nG28',
    'Base_id_0; M140 S150',
    'Base_id_0 ',            // a trailing space is a different name
    '',
    null,
    undefined,
    'Nonexistent',
  ]) {
    const out = ex.excludeRequest(attack, plate);
    assert.ok(out.refused, `accepted ${JSON.stringify(attack)}`);
    assert.equal(out.path, undefined);
  }
});

/// A print with nothing left to print is a machine heating an empty plate.
test('the last object cannot be dropped — that is a cancel', () => {
  const nearlyDone = reply({
    objects: [{ name: 'A' }, { name: 'B' }],
    excluded_objects: ['A'],
    current_object: 'B',
  });
  assert.match(ex.excludeRequest('B', nearlyDone).refused, /cancel/i);
});

test('a printer without the module refuses rather than building a command', () => {
  assert.match(ex.excludeRequest('anything', reply(undefined)).refused, /does not report/);
});

/// Said out loud because every caller has to warn before it acts.
test('this is not reversible, and says so', () => {
  assert.equal(ex.reversible, false);
});

// ── AND THAT IT IS ACTUALLY REACHABLE ────────────────────────────────────────
//
// The same guard `printer-commands.test.js` carries, for the same reason it
// gives: renderer files are plain scripts and main/preload are separate
// contexts, so a module that exists and is never reachable is a real failure
// mode here — and this repo's commonest one.
const fs = require('node:fs');
const path = require('node:path');

const mainJs = () => fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

test('the handlers are wired through main and the preload bridge', () => {
  const main = mainJs();
  const preload = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  assert.match(main, /require\('\.\/lib\/exclude-object'\)/, 'main never requires the module');
  assert.match(main, /ipcMain\.handle\('hub:printer-plate'/, 'no plate handler in main');
  assert.match(main, /ipcMain\.handle\('hub:printer-exclude-object'/, 'no exclude handler in main');
  assert.match(preload, /hub:printer-plate/, 'the plate is not on the preload bridge');
  assert.match(preload, /hub:printer-exclude-object/, 'excluding is not on the preload bridge');
});

test('the plate read reuses the SSRF host allowlist', () => {
  // It reaches a LAN device on the user's behalf, so it must not be steerable
  // off the validated address any more than the status poller is.
  const main = mainJs();
  const fn = main.slice(main.indexOf('async function plateObjects'),
                        main.indexOf("ipcMain.handle('hub:printer-plate'"));
  assert.match(fn, /isAllowedPrinterHost/, 'no host allowlist check');
  assert.match(fn, /redirect: 'manual'/, 'redirects are not pinned');
});

/// The name must be checked against a plate read in THIS call.
///
/// A list the renderer is holding is a list from some seconds ago, and the
/// object it names may have finished printing since. Worse, trusting a
/// renderer-supplied list would put the whole guard in the caller's hands —
/// and the guard is the only reason the name needs no escaping.
test('excluding re-reads the plate rather than trusting the caller', () => {
  const main = mainJs();
  const handler = main.slice(main.indexOf("ipcMain.handle('hub:printer-exclude-object'"));
  const body = handler.slice(0, handler.indexOf('\n});'));
  assert.match(body, /await plateObjects\(machine\)/, 'the plate is not re-read');
  assert.match(body, /excludeObject\.excludeRequest\(name, read\.data\)/,
    'the name is not checked against the plate just read');
  assert.match(body, /redirect: 'manual'/, 'redirects are not pinned on the command itself');
});
