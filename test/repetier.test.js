/**
 * Repetier-Server, against payloads shaped the way the vendor says they arrive.
 *
 * The defect these were written for is not subtle once the payload is right,
 * and was invisible while it was wrong: `done` (progress) and `job` (filename)
 * were read off `?a=stateList`, and neither field is on that call. Repetier's
 * own API reference lists what `stateList` returns — temperatures, active
 * extruder, layer, position — and RepetierSharp, a typed client whose
 * `PrinterState` matches that list field for field, puts `done` and `job` on the
 * model that `?a=listPrinter` returns instead.
 *
 * Reading an absent field never throws. It returns undefined, undefined becomes
 * 0, and 0 with an empty filename reads as an idle machine — so a Repetier
 * printer at 42% with a hot nozzle looked Idle, forever, and said so quietly.
 * The first test here is that exact machine.
 *
 * So the fixtures below are built from the two calls separately, and never from
 * one merged blob: a test that hands the adapter everything it needs in one
 * object cannot fail the way the shipped code failed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { repetierStatus, printerEntry, machineState, JOB_STATE_WORDS } = require('../lib/repetier.js');
const { normalizeProgress } = require('../lib/printer-status.js');

/** `?a=stateList` — an object keyed by printer slug. Machine state only. */
const stateList = (slug, over = {}) => ({
  error: '',
  data: {
    [slug]: {
      activeExtruder: 0,
      extruder: [{ tempRead: 212.4, tempSet: 215, output: 88 }],
      heatedBeds: [{ tempRead: 59.8, tempSet: 60, output: 40 }],
      layer: 87,
      numExtruder: 1,
      firmware: 'Repetier 1.0.5',
      x: 110.2, y: 98.4, z: 17.4,
      speedMultiply: 100, flowMultiply: 100,
      sdcardMounted: false, powerOn: true,
      ...over,
    },
  },
});

/** `?a=listPrinter` — documented as an ARRAY of printers. Job state only. */
const listPrinter = (slug, over = {}) => ({
  error: '',
  data: [{
    active: true,
    done: 42.37,
    job: 'dragon-body.gcode',
    jobid: 118,
    linesSend: 402911,
    name: 'Workshop',
    ofLayer: 214,
    online: 1,
    pauseState: 0,
    paused: false,
    printStart: 1756200000,
    slug,
    totalLines: 951204,
    ...over,
  }],
});

const status = (stateData, listData, slug = 'workshop') =>
  repetierStatus({ stateData, listData, slug, normalizeProgress });

test('a printing machine reports as printing — the defect this file exists for', () => {
  const s = status(stateList('workshop'), listPrinter('workshop'));
  assert.equal(s.state, 'Printing');
  assert.equal(s.progress, 42);        // `done` is a percentage, not a 0-1 fraction
  assert.equal(s.filename, 'dragon-body.gcode');
  assert.equal(s.tempNozzle, 212.4);
  assert.equal(s.tempBed, 59.8);
});

test('the job fields are NOT taken from stateList, however tempting', () => {
  // The shape of the old bug: a server that answered stateList with `done` and
  // `job` on it would have made the broken adapter look correct. Nothing may be
  // read from there, so putting them there must change nothing.
  const poisoned = stateList('workshop', { done: 99, job: 'not-this-one.gcode' });
  const s = status(poisoned, listPrinter('workshop'));
  assert.equal(s.progress, 42);
  assert.equal(s.filename, 'dragon-body.gcode');
});

test('temperatures survive a listing that failed', () => {
  // The second request is allowed to fail on its own — losing the job must not
  // cost the temperatures, the same rule the PrusaLink branch follows.
  const s = status(stateList('workshop'), null);
  assert.equal(s.tempNozzle, 212.4);
  assert.equal(s.tempBed, 59.8);
  assert.equal(s.progress, 0);
  assert.equal(s.state, 'Idle');
});

test('"printing" in the job field is a state, not a file called printing', () => {
  // Repetier documents the printer listing's `job` as one of
  // none|paused|printing|waitstart, while RepetierSharp types it as the job's
  // NAME. Both are attested; betting on the name would put the literal word
  // "printing" in a shop's queue as though somebody had sliced a file called it.
  const s = status(stateList('workshop'), listPrinter('workshop', { job: 'printing', done: 7 }));
  assert.equal(s.state, 'Printing');
  assert.equal(s.filename, '');
  assert.equal(s.progress, 7);
  for (const word of JOB_STATE_WORDS) {
    const one = status(stateList('workshop'), listPrinter('workshop', { job: word }));
    assert.equal(one.filename, '', `${word} is a state word and must never be a filename`);
  }
});

test('idle, paused, waiting and offline each say what they are', () => {
  const idle = status(stateList('workshop'), listPrinter('workshop', { job: 'none', done: 0 }));
  assert.equal(idle.state, 'Idle');
  assert.equal(idle.filename, '');

  // Paused is reported three different ways across versions; any of them counts,
  // because a paused job that reads as "Printing" is a shop waiting on a machine
  // that is waiting on them.
  assert.equal(status(stateList('workshop'), listPrinter('workshop', { paused: true })).state, 'Paused');
  assert.equal(status(stateList('workshop'), listPrinter('workshop', { job: 'paused' })).state, 'Paused');
  assert.equal(status(stateList('workshop'), listPrinter('workshop', { pauseState: 2 })).state, 'Paused');

  assert.equal(status(stateList('workshop'), listPrinter('workshop', { job: 'waitstart' })).state, 'Preparing');
  assert.equal(status(stateList('workshop'), listPrinter('workshop', { online: 0 })).state, 'Offline');
});

test('the listing is read whether it arrives as an array or keyed by slug', () => {
  // stateList is keyed by slug and the listing is documented as an array, which
  // is precisely the confusion that produced the original `data.data[0]`. Both
  // are accepted rather than assumed: a server answering the other way would
  // otherwise return silently to reporting 0%.
  const keyed = { error: '', data: { workshop: { done: 42.37, job: 'dragon-body.gcode', slug: 'workshop', online: 1 } } };
  const s = status(stateList('workshop'), keyed);
  assert.equal(s.progress, 42);
  assert.equal(s.filename, 'dragon-body.gcode');

  const wrapped = { error: '', data: { printers: [{ done: 12, job: 'a.gcode', slug: 'workshop', online: 1 }] } };
  assert.equal(status(stateList('workshop'), wrapped).progress, 12);
});

test('a slug nobody configured still finds the only printer there is', () => {
  // `printerSlug` is optional in the machine dialog and defaults to "default",
  // which is a slug most servers do not use. One printer and one entry is not
  // ambiguous, and refusing to read it would report a working machine as idle.
  const s = status(stateList('irapid'), listPrinter('irapid'), 'default');
  assert.equal(s.filename, 'dragon-body.gcode');
  assert.equal(s.tempNozzle, 212.4);

  // With two printers and no matching slug there IS an ambiguity, and guessing
  // would show one machine's job against another's name.
  const two = { error: '', data: [{ slug: 'a', done: 10, job: 'a.gcode', online: 1 }, { slug: 'b', done: 90, job: 'b.gcode', online: 1 }] };
  assert.equal(printerEntry(two, 'default').done, undefined);
  assert.equal(status(stateList('a'), two, 'default').progress, 0);
});

test('the bed is found under every spelling this server has used', () => {
  // heatedBeds (list) is what RepetierSharp models and Home Assistant's client
  // reads; heatedBed (object) is the vendor's own example. heated_bed is what
  // Khayt used to read and is neither, so it stays accepted but proves nothing.
  const singular = stateList('workshop', { heatedBeds: undefined, heatedBed: { tempRead: 61.1 } });
  assert.equal(status(singular, listPrinter('workshop')).tempBed, 61.1);
  const lower = stateList('workshop', { heatedBeds: undefined, heatedbeds: [{ tempRead: 62.2 }] });
  assert.equal(status(lower, listPrinter('workshop')).tempBed, 62.2);
  const none = stateList('workshop', { heatedBeds: undefined });
  assert.equal(status(none, listPrinter('workshop')).tempBed, null);
});

test('a toolchanger reads the extruder that is live', () => {
  // The same mistake as the Klipper one the last audit found: index 0 is a
  // toolhead, not necessarily THE toolhead.
  const multi = stateList('workshop', {
    activeExtruder: 2,
    extruder: [{ tempRead: 25 }, { tempRead: 26 }, { tempRead: 240 }],
  });
  assert.equal(status(multi, listPrinter('workshop')).tempNozzle, 240);
});

test('nothing is invented when the server says nothing', () => {
  const s = status({ error: '', data: {} }, { error: '', data: [] });
  assert.equal(s.state, 'Idle');
  assert.equal(s.progress, 0);
  assert.equal(s.filename, '');
  assert.equal(s.tempNozzle, null);
  assert.equal(s.tempBed, null);
  // printTime and printedTimeComp are in the listing and are deliberately not
  // read: what they mean is undocumented, and a guessed ETA is how OctoPrint's
  // filament figure became a measurement that never was.
  assert.equal(s.timeRemaining, null);
  assert.equal(machineState(null, 'x').activeExtruder, undefined);
});

test('a progress figure outside 0-100 cannot reach the UI', () => {
  assert.equal(status(stateList('w'), listPrinter('w', { done: 100000 }), 'w').progress, 100);
  assert.equal(status(stateList('w'), listPrinter('w', { done: -4 }), 'w').progress, 0);
  assert.equal(status(stateList('w'), listPrinter('w', { done: 'lots' }), 'w').progress, 0);
});
