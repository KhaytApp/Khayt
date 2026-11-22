'use strict';
// The planner's synthesized part took the slicer's MINUTES as printTime, which
// every part reads as HOURS (#printTime; the plate picker divides by 60), so a
// five-hour print was costed as 300 hours of machine, power and wear.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const P = require('../renderer/color-planner.js');

test('the slicer time goes in as hours', () => {
  assert.equal(P.slicerHours({ parsed: { printTimeMins: 300 } }), 5);
  assert.equal(P.slicerHours({ parsed: { printTimeMins: 90 } }), 1.5);
  assert.equal(P.slicerHours({ parsed: {} }), 0);
  assert.equal(P.slicerHours({}), 0);
  assert.equal(P.slicerHours(null), 0);
});

test('figures from older bytes (figuresStaleFor, set by the Mac) are not used', () => {
  assert.equal(P.slicerHours({ figuresStaleFor: 'sha-old', parsed: { printTimeMins: 300 } }), 0);
  assert.equal(P.slicerHours({ figuresStaleFor: '  ', parsed: { printTimeMins: 300 } }), 5);
});

test('wired: the planned part reads slicerHours, never raw minutes', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'color-planner.js'), 'utf8');
  assert.match(src, /printTime: slicerHours\(rec\) \|\| rf\('#printTime'\),/);
  assert.doesNotMatch(src, /printTime: \(rec\.parsed && \+rec\.parsed\.printTimeMins\)/);
});
