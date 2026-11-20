'use strict';
/**
 * U1 idea 3: a print's time-lapse kept with the job as proof, only when the
 * shop asks ("Keep as proof"). lib/timelapse-attach.js decides; the host
 * copies. Synthetic names in the U1 camera folder's shape.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
require('../lib/webcam.js');
const T = require('../lib/timelapse-attach.js');
const SFP = require('../lib/safe-file-path.js');

const match = (over) => ({ video: 'plate_1_20261119T101500.mp4', cover: 'plate_1_20261119T101500.jpg', bytes: 42 * 1048576, ...over });
const order = (over) => ({ id: 'PO-17', attachedFiles: [], ...over });

test('a video within the budget is copied: the attachment row', () => {
  assert.deepEqual(T.timelapseAttach(order(), match(), { machineId: 'M1', stamp: 'lx9k2' }), {
    action: 'attach',
    row: { filename: 'PO-17-timelapse-lx9k2.mp4', originalName: 'plate_1_20261119T101500.mp4', size: 42 * 1048576, kind: 'timelapse', from: { machineId: 'M1', video: 'plate_1_20261119T101500.mp4' } },
  });
});

test('over the budget, or a size the printer did not give, stays on the printer as a link', () => {
  assert.deepEqual(T.timelapseAttach(order(), match({ bytes: T.MAX_BYTES + 1 }), { machineId: 'M1' }), { action: 'link', reason: 'over-budget', bytes: T.MAX_BYTES + 1, maxBytes: T.MAX_BYTES });
  assert.equal(T.timelapseAttach(order(), match({ bytes: 30 }), { machineId: 'M1', maxBytes: 10 }).reason, 'over-budget');
  for (const b of [undefined, null, 0, -1, 'x']) assert.deepEqual(T.timelapseAttach(order(), match({ bytes: b }), { machineId: 'M1' }), { action: 'link', reason: 'size-unknown' }, String(b));
});

test('kept once: the same video from the same printer is "already"; from another printer it is not', () => {
  const first = T.timelapseAttach(order(), match(), { machineId: 'M1', stamp: 'a' }).row;
  const o = order({ attachedFiles: [{ filename: 'PO-17-a.pdf' }, first] });
  assert.deepEqual(T.timelapseAttach(o, match(), { machineId: 'M1', stamp: 'b' }), { action: 'already', index: 1 });
  assert.equal(T.timelapseAttach(o, match(), { machineId: 'M2', stamp: 'b' }).action, 'attach');
});

test('nothing usable: no match, not an mp4, a path that leaves the camera folder', () => {
  for (const m of [null, {}, match({ video: 'cover.jpg' }), match({ video: '../etc/passwd.mp4' }), match({ video: 'a/b.mp4' }), match({ video: '.hidden.mp4' })]) {
    assert.deepEqual(T.timelapseAttach(order(), m, { machineId: 'M1' }), { action: 'none' }, JSON.stringify(m));
  }
});

test('the filename is the shop\'s own: a hostile job id or stamp cannot steer it', () => {
  const r = T.timelapseAttach(order({ id: '../../x y' }), match(), { machineId: 'M1', stamp: '../z' }).row;
  assert.equal(r.filename, '______x_y-timelapse-z.mp4');
  assert.equal(T.timelapseAttach({}, match(), { stamp: '1' }).row.filename, 'job-timelapse-1.mp4');
});

test('the copy opens like any attachment (mp4 is on the attachment list), and the job is never changed', () => {
  assert.ok(SFP.ATTACHMENT_EXTS.includes('mp4'));
  const o = order();
  T.timelapseAttach(o, match(), { machineId: 'M1', stamp: 'a' });
  assert.deepEqual(o, order());
});
