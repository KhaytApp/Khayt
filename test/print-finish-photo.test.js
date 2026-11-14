const { test } = require('node:test');
const assert = require('node:assert/strict');
const F = require('../lib/print-finish-photo.js');
const PI = require('../lib/product-images.js');

/** Run a sequence of polls through `track` and count the captures. */
function run(states, machineId = 'M1') {
  let memo = {};
  const fired = [];
  for (const s of states) {
    const r = F.track(memo, machineId, s);
    memo = r.memo;
    if (r.capture) fired.push(r.filename);
  }
  return fired;
}

// ── WHEN ────────────────────────────────────────────────────────────────────

test('a finish fires once, however long the printer sits on complete', () => {
  const fired = run([
    { state: 'standby', progress: 0 },
    { state: 'printing', progress: 10, filename: 'lamp.gcode' },
    { state: 'printing', progress: 99, filename: 'lamp.gcode' },
    { state: 'complete', progress: 100, filename: 'lamp.gcode' },
    { state: 'complete', progress: 100, filename: 'lamp.gcode' },
    { state: 'complete', progress: 100, filename: 'lamp.gcode' },
    { state: 'standby', progress: 0 },
  ]);
  assert.deepEqual(fired, ['lamp.gcode']);
});

test('two prints in a row are two photos', () => {
  const fired = run([
    { state: 'printing', progress: 50, filename: 'a.gcode' },
    { state: 'complete', progress: 100, filename: 'a.gcode' },
    { state: 'printing', progress: 1, filename: 'b.gcode' },
    { state: 'complete', progress: 100, filename: 'b.gcode' },
  ]);
  assert.deepEqual(fired, ['a.gcode', 'b.gcode']);
});

test('pausing is not finishing, and a resumed print still fires at its end', () => {
  const fired = run([
    { state: 'printing', progress: 40, filename: 'a.gcode' },
    { state: 'paused', progress: 40, filename: 'a.gcode' },
    { state: 'printing', progress: 41, filename: 'a.gcode' },
    { state: 'complete', progress: 100, filename: 'a.gcode' },
  ]);
  assert.deepEqual(fired, ['a.gcode']);
});

test('no photo for a cancelled, failed or errored print', () => {
  for (const end of ['cancelled', 'error', 'FAILED', 'STOPPED', 'Cancelling', 'Offline after error']) {
    const fired = run([
      { state: 'printing', progress: 99, filename: 'a.gcode' },
      { state: end, progress: 99, filename: 'a.gcode' },
      { state: 'standby', progress: 0 },
    ]);
    assert.deepEqual(fired, [], `${end} took a photo`);
  }
});

test('a cancel from pause takes no photo either', () => {
  assert.deepEqual(run([
    { state: 'printing', progress: 20, filename: 'a.gcode' },
    { state: 'paused', progress: 20, filename: 'a.gcode' },
    { state: 'cancelled', progress: 20, filename: 'a.gcode' },
  ]), []);
});

test('a firmware that goes straight to idle: finished only if it reached the end', () => {
  assert.deepEqual(run([
    { state: 'Printing', progress: 100, filename: 'a.gcode' },
    { state: 'Operational', progress: 0 },
  ]), ['a.gcode'], 'OctoPrint after a finished print forgets the file; the memo keeps it');
  assert.deepEqual(run([
    { state: 'Printing', progress: 40, filename: 'a.gcode' },
    { state: 'Operational', progress: 0 },
  ]), [], 'an idle printer at 40% is a cancel that did not say so');
});

test('each printer has its own memory', () => {
  let memo = {};
  memo = F.track(memo, 'M1', { state: 'printing', progress: 50 }).memo;
  const other = F.track(memo, 'M2', { state: 'complete', progress: 100 });
  assert.equal(other.capture, false, 'M2 was never printing');
  const mine = F.track(other.memo, 'M1', { state: 'complete', progress: 100 });
  assert.equal(mine.capture, true);
});

test('the other finish words', () => {
  for (const end of ['FINISHED', 'FINISH', 'complete']) {
    assert.equal(F.outcome({ state: 'printing' }, { state: end }), 'finished', end);
  }
  assert.equal(F.outcome({ state: 'standby' }, { state: 'complete' }), null, 'no edge');
});

test('how it ended: failed and cancelled are told apart', () => {
  const end = (s, p = 50) => F.outcome({ state: 'printing', progress: p }, { state: s, progress: p });
  for (const s of ['error', 'FAILED', 'Offline after error']) assert.equal(end(s), 'failed', s);
  for (const s of ['cancelled', 'STOPPED', 'Cancelling']) assert.equal(end(s), 'cancelled', s);
  assert.equal(end('Operational', 40), 'cancelled', 'idle short of the end is a silent cancel');
  assert.equal(end('Operational', 100), 'finished');
});

test('every edge reports its outcome and how long the job ran', () => {
  let memo = {};
  const at = (s) => { const r = F.track(memo, 'M1', s); memo = r.memo; return r; };
  assert.equal(at({ state: 'printing', progress: 10, actuals: { durationS: 600 } }).outcome, null);
  assert.equal(at({ state: 'printing', progress: 50, actuals: { durationS: 1800 } }).durationS, null,
    'no edge, nothing to report');
  const ended = at({ state: 'cancelled', progress: 50 });
  assert.equal(ended.outcome, 'cancelled');
  assert.equal(ended.capture, false);
  assert.equal(ended.durationS, 1800, 'the printer cleared its counter: the last reading during the job');

  at({ state: 'printing', progress: 1, actuals: { durationS: 5 } });
  const done = at({ state: 'complete', progress: 100, actuals: { durationS: 3600 } });
  assert.equal(done.outcome, 'finished');
  assert.equal(done.durationS, 3600, 'the finished reading wins');

  at({ state: 'printing', progress: 1 });
  assert.equal(at({ state: 'complete', progress: 100 }).durationS, null, 'never said, so null');
});

// ── WHICH JOB ───────────────────────────────────────────────────────────────

const job = (id, status, machineId, fileRef) => ({
  id, status, machineId, parts: fileRef ? [{ name: 'p', fileRef }] : [],
});

test('the printing job on that machine whose part names the file', () => {
  const log = [
    job('A', 'printing', 'M1', 'other.gcode'),
    job('B', 'printing', 'M1', 'gcodes/Lamp.gcode'),
    job('C', 'printing', 'M2', 'lamp.gcode'),
  ];
  assert.equal(F.jobFor(log, 'M1', 'lamp.gcode'), 'B');
});

test('the only printing job on the machine, when no file matches', () => {
  const log = [job('A', 'printing', 'M1'), job('B', 'pending', 'M1'), job('C', 'printing', 'M2')];
  assert.equal(F.jobFor(log, 'M1', 'unknown.gcode'), 'A');
});

test('two printing jobs and no file to tell them apart is no guess', () => {
  const log = [job('A', 'printing', 'M1'), job('B', 'printing', 'M1')];
  assert.equal(F.jobFor(log, 'M1', 'x.gcode'), null);
});

test('a job the shop already moved on is still found by its file', () => {
  const log = [job('A', 'qc', 'M1', 'lamp.gcode'), job('B', 'completed', 'M1', 'old.gcode')];
  assert.equal(F.jobFor(log, 'M1', 'lamp.gcode'), 'A');
  assert.equal(F.jobFor(log, 'M1', 'nothing.gcode'), null);
});

test('no machine, no job; a cancelled job is never the one', () => {
  assert.equal(F.jobFor([job('A', 'printing', 'M1')], '', 'a'), null);
  assert.equal(F.jobFor([job('A', 'cancelled', 'M1', 'a.gcode')], 'M1', 'a.gcode'), null);
});

// ── AS A PRODUCT PICTURE ────────────────────────────────────────────────────

test('addImage appends a print-kind picture without taking the primary', () => {
  const product = {
    id: 'PRD-1',
    images: [{ id: 'PIMG-PRD1-0', path: 'r.jpeg', thumbnail: 'data:image/jpeg;base64,R', kind: 'render' }],
  };
  const out = PI.addImage(product, { thumbnail: 'data:image/jpeg;base64,P', path: 'p.jpeg', kind: 'print' });
  assert.equal(out.added, true);
  assert.equal(out.image.kind, 'print');
  assert.equal(out.product.images.length, 2);
  assert.equal(out.product.images[0].kind, 'render', 'the shop chose the primary');
  assert.equal(out.product.imagePath, 'r.jpeg');
  assert.equal(PI.hasRealPhoto(out.product), true);
  const photos = PI.storefrontPhotos(out.product);
  assert.equal(photos[1].kind, 'print', 'the storefront carries it second, as the honest one');
});

test('addImage on a product with no pictures makes it the primary', () => {
  const out = PI.addImage({ id: 'P' }, { thumbnail: 'data:image/jpeg;base64,P', path: 'p.jpeg', kind: 'print' });
  assert.equal(out.product.imagePath, 'p.jpeg');
  assert.equal(out.product.thumbnail, 'data:image/jpeg;base64,P');
});

test('addImage mints an id that is not already taken', () => {
  const product = { id: 'P', images: [{ id: 'PIMG-P-1', path: 'x', thumbnail: 't' }] };
  const out = PI.addImage(product, { thumbnail: 'u', path: 'y', kind: 'print' });
  assert.notEqual(out.image.id, 'PIMG-P-1');
  assert.equal(new Set(out.product.images.map((i) => i.id)).size, 2);
});

test('addImage twice with the same picture is one picture', () => {
  const first = PI.addImage({ id: 'P' }, { thumbnail: 'same', path: 'a', kind: 'print' });
  const again = PI.addImage(first.product, { thumbnail: 'same', path: 'b', kind: 'print' });
  assert.equal(again.added, false);
  assert.equal(again.product.images.length, 1);
});

test('addImage refuses an unknown kind by falling back to render', () => {
  const out = PI.addImage({ id: 'P' }, { thumbnail: 't', kind: 'glamour' });
  assert.equal(out.image.kind, 'render');
});

// ── A FINISH THE DEVICE DID NOT SEE (Baby U1, Nov 14) ──────────────────────
// The Mac quit mid-print and came back after the end: its memo says printing
// at a mid-print progress, the U1 now says `standby` with no file. That is
// not a cancel — the printer's history says how it ended.

test('a missed edge with an unnamed idle state is unknown, never guessed as cancelled', () => {
  const memo = { u1: { state: 'printing', progress: 41, filename: 'Silica Box_PETG_15h22m.gcode' } };
  const now = { state: 'standby', progress: 0, filename: '' };
  const missed = F.track(memo, 'u1', now, { missed: true });
  assert.equal(missed.outcome, 'unknown');
  assert.equal(missed.capture, false);
  assert.equal(missed.filename, 'Silica Box_PETG_15h22m.gcode', 'the file it was printing, from the memo');
  // Without the flag the live rule is unchanged: OctoPrint's bare return to idle at 41% is a cancel.
  assert.equal(F.track(memo, 'u1', now).outcome, 'cancelled');
  // A state that names how it ended still decides, missed or not.
  assert.equal(F.track(memo, 'u1', { state: 'complete', filename: 'x' }, { missed: true }).outcome, 'finished');
  assert.equal(F.track(memo, 'u1', { state: 'error' }, { missed: true }).outcome, 'failed');
});

test('fromHistory: the newest job for the file, with its real end', () => {
  const jobs = [
    { filename: 'Silica Box_PETG_15h22m.gcode', status: 'cancelled', endedAt: '2026-11-12T08:00:00.000Z' },
    { filename: 'Silica Box_PETG_15h22m.gcode', status: 'completed', endedAt: '2026-11-14T10:43:00.000Z' },
    { filename: 'other.gcode', status: 'completed', endedAt: '2026-11-14T11:00:00.000Z' },
  ];
  assert.deepEqual(F.fromHistory(jobs, 'Silica Box_PETG_15h22m.gcode'),
    { outcome: 'finished', endedAt: '2026-11-14T10:43:00.000Z' });
  // Matched by the last path component, case-insensitively, as jobFor matches.
  assert.equal(F.fromHistory(jobs, 'gcodes/SILICA BOX_PETG_15H22M.gcode').outcome, 'finished');
  assert.equal(F.fromHistory([{ filename: 'a.gcode', status: 'error', endedAt: '' }], 'a.gcode').outcome, 'failed');
  assert.equal(F.fromHistory([{ filename: 'a.gcode', status: 'klippy_shutdown' }], 'a.gcode').outcome, 'failed');
  assert.equal(F.fromHistory([{ filename: 'a.gcode', status: 'cancelled' }], 'a.gcode').outcome, 'cancelled');
  // Nothing it can back: no job for the file, or a status that says nothing.
  assert.equal(F.fromHistory(jobs, 'missing.gcode'), null);
  assert.equal(F.fromHistory([{ filename: 'a.gcode', status: 'in_progress' }], 'a.gcode'), null);
  assert.equal(F.fromHistory([{ filename: 'a.gcode', status: 'interrupted' }], 'a.gcode'), null);
  assert.equal(F.fromHistory(jobs, ''), null);
  assert.equal(F.fromHistory(null, 'a.gcode'), null);
});
