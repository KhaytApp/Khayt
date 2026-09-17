const { test } = require('node:test');
const assert = require('node:assert/strict');

const RT = require('../lib/rating-trend.js');

const rated = (month, rating, extra = {}) => ({
  id: `O-${month}-${rating}`,
  status: 'completed',
  completedAt: `${month}-15T10:00:00.000Z`,
  survey: { rating },
  ...extra,
});

const SIX = ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09'];

/* ------------------------------------------------------------------
   The caption described a different set of jobs than the line.
   ------------------------------------------------------------------ */

test('the count and the average cover the months drawn, not all of history', () => {
  const orders = [
    // Two years ago, when the shop was worse. Off the left of the chart.
    rated('2024-03', 1), rated('2024-04', 1), rated('2024-05', 2),
    // The window.
    rated('2026-05', 5), rated('2026-06', 5), rated('2026-07', 5),
  ];
  const r = RT.trend(orders, SIX);
  assert.equal(r.responses, 3, 'three ratings fall in the six months');
  assert.equal(r.average, 5, 'and they all say five');
  assert.equal(r.allTimeResponses, 6, 'the older three are still counted, separately');

  // The old caption was this, printed under a line of 5.0 dots.
  const allTimeAverage = orders.reduce((s, o) => s + o.survey.rating, 0) / orders.length;
  assert.ok(allTimeAverage < 3.2, `was ${allTimeAverage}`);
  assert.notEqual(r.average, allTimeAverage);
});

test('every point on the line is a month that was asked for', () => {
  const r = RT.trend([rated('2026-06', 4), rated('2026-06', 2)], SIX);
  assert.deepEqual(r.points.map(p => p.month), SIX);
  assert.deepEqual(r.points.map(p => p.responses), [0, 0, 2, 0, 0, 0]);
  assert.deepEqual(r.points.map(p => p.average), [null, null, 3, null, null, null]);
});

test('a month with no responses is a gap, not a zero', () => {
  const r = RT.trend([rated('2026-04', 5)], SIX);
  assert.equal(r.points[0].average, 5);
  assert.equal(r.points[1].average, null, 'a gap the caller can leave blank');
});

/* ------------------------------------------------------------------
   A rating on a job with no completedAt was thrown away.
   ------------------------------------------------------------------ */

test('a rating counts even when the job carries no completedAt', () => {
  // A book written before completedAt existed, or an imported one, or a job
  // that went straight to delivered. The customer still gave a rating.
  const legacy = { id: 'L1', status: 'delivered', date: '2026-06-10', survey: { rating: 4 } };
  const r = RT.trend([legacy], SIX, { minResponses: 1 });
  assert.equal(r.responses, 1);
  assert.equal(r.average, 4);
  assert.equal(r.points[2].month, '2026-06');
});

test('the old filter dropped exactly those jobs', () => {
  const legacy = { id: 'L1', status: 'delivered', date: '2026-06-10', survey: { rating: 4 } };
  const theOldWay = [legacy].filter(o => o.survey?.rating && o.completedAt);
  assert.deepEqual(theOldWay, [], 'no completedAt, no rating counted');
});

test('a plain date is sliced, not parsed through a timezone', () => {
  // "2026-06-01" parses as midnight UTC, which is the 31st of May west of it.
  assert.equal(RT.monthOf({ date: '2026-06-01', survey: { rating: 5 } }), '2026-06');
  assert.equal(RT.monthOf({ date: '2026-01-01', survey: { rating: 5 } }), '2026-01');
  assert.equal(RT.monthOf({ date: 'not a date' }), '');
  assert.equal(RT.monthOf({}), '');
});

test('a timestamp is read in the reader\'s own month', () => {
  const o = { completedAt: '2026-06-15T10:00:00.000Z' };
  const d = new Date(o.completedAt);
  const expected = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
  assert.equal(RT.monthOf(o), expected);
});

/* ------------------------------------------------------------------
   What counts as a rating.
   ------------------------------------------------------------------ */

test('a rating outside one to five is not a rating', () => {
  assert.equal(RT.ratingOf({ survey: { rating: 3 } }), 3);
  assert.equal(RT.ratingOf({ survey: { rating: '4' } }), 4);
  assert.equal(RT.ratingOf({ survey: { rating: 0 } }), null);
  assert.equal(RT.ratingOf({ survey: { rating: 6 } }), null);
  assert.equal(RT.ratingOf({ survey: { rating: -1 } }), null);
  assert.equal(RT.ratingOf({ survey: { rating: 'great' } }), null);
  assert.equal(RT.ratingOf({ survey: {} }), null);
  assert.equal(RT.ratingOf({}), null);
  assert.equal(RT.ratingOf(null), null);
});

/* ------------------------------------------------------------------
   Whether there is enough to draw.
   ------------------------------------------------------------------ */

test('enough counts the window, so old ratings cannot unlock an empty chart', () => {
  const stale = [rated('2024-03', 5), rated('2024-04', 5), rated('2024-05', 5)];
  const r = RT.trend(stale, SIX);
  assert.equal(r.allTimeResponses, 3);
  assert.equal(r.responses, 0);
  assert.equal(r.enough, false, 'three ratings from two years ago are not this half-year');
  assert.equal(r.average, null);
});

test('three in the window is enough, two is not', () => {
  const two = [rated('2026-06', 5), rated('2026-07', 4)];
  assert.equal(RT.trend(two, SIX).enough, false);
  assert.equal(RT.trend(two.concat(rated('2026-08', 3)), SIX).enough, true);
  assert.equal(RT.trend(two, SIX, { minResponses: 2 }).enough, true);
});

test('an empty book yields an empty, drawable report', () => {
  const r = RT.trend([], SIX);
  assert.equal(r.responses, 0);
  assert.equal(r.average, null);
  assert.equal(r.enough, false);
  assert.equal(r.points.length, 6);
  assert.deepEqual(RT.trend(undefined, undefined).points, []);
});
