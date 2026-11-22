'use strict';
/**
 * U1 idea 3: a time-lapse kept as the customer's proof (lib/webcam.js
 * timelapseAttach). Copied ONLY on "Keep as proof" (Turki, Nov 19), within
 * the host's budget, never fetched blind, never twice; otherwise the job
 * keeps the existing link.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/webcam.js');

const match = { video: 'plate_20261119_120000.mp4', cover: 'plate_20261119_120000.jpg', bytes: 42e6 };

test('kept, within budget: a timelapse row for the host to download and store', () => {
  assert.deepEqual(W.timelapseAttach({ attachedFiles: [] }, match, { maxBytes: 200e6, freeBytes: 500e6 }, { keep: true, machineId: 'M1' }), {
    attach: { originalName: 'plate_20261119_120000.mp4', size: 42e6, kind: 'timelapse', video: 'plate_20261119_120000.mp4', cover: 'plate_20261119_120000.jpg', machineId: 'M1' },
  });
});

test('not asked: the link stays, nothing is copied (Turki: only on "Keep as proof")', () => {
  for (const opts of [undefined, {}, { keep: 'yes' }, { keep: 1 }]) assert.deepEqual(W.timelapseAttach({}, match, {}, opts), { keepLink: 'not-kept' });
});

test('over the budget, either the per-video cap or what the job may still take', () => {
  assert.deepEqual(W.timelapseAttach({}, match, { maxBytes: 10e6 }, { keep: true }), { keepLink: 'over-budget', bytes: 42e6 });
  assert.deepEqual(W.timelapseAttach({}, match, { freeBytes: 41e6 }, { keep: true }), { keepLink: 'over-budget', bytes: 42e6 });
  assert.ok(W.timelapseAttach({}, match, { maxBytes: 42e6, freeBytes: 42e6 }, { keep: true }).attach, 'exactly at the limit fits');
});

test('never fetched blind, never a file outside the camera folder, never twice', () => {
  for (const bytes of [undefined, null, 0, -5, 'big', NaN]) assert.deepEqual(W.timelapseAttach({}, { ...match, bytes }, {}, { keep: true }), { keepLink: 'size-unknown' });
  for (const video of ['../etc/passwd', 'sub/x.mp4', '.hidden.mp4', 'x.mov', '', null]) assert.deepEqual(W.timelapseAttach({}, { ...match, video }, {}, { keep: true }), { keepLink: 'no-match' });
  assert.deepEqual(W.timelapseAttach({}, null, {}, { keep: true }), { keepLink: 'no-match' });
  const kept = { attachedFiles: [{ filename: 'f1.mp4', kind: 'timelapse', video: match.video }] };
  assert.deepEqual(W.timelapseAttach(kept, match, {}, { keep: true }), { keepLink: 'already-kept' });
  // A bad cover is left off, the video still kept.
  assert.equal(W.timelapseAttach({}, { ...match, cover: '../x.jpg' }, {}, { keep: true }).attach.cover, undefined);
});
