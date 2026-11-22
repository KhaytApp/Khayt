'use strict';
/**
 * Whether the shop keeps its promises.
 *
 * Lifted from renderSLASection, whose one remaining fault — delivered jobs
 * left out of the delivery record — is the first test.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/on-time.js');

const job = (over) => ({ id: 'J', status: 'completed', date: '2026-09-01', dueDate: '2026-09-05', completedAt: '2026-09-04T12:00:00', project: 'Bracket', ...over });

test('a DELIVERED job is part of the delivery record', () => {
  const r = T.onTime([job(), job({ status: 'delivered', completedAt: undefined, deliveredAt: '2026-09-07T09:00:00' })]);
  assert.equal(r.promised, 2);
  assert.equal(r.onTime, 1);
  assert.equal(r.late, 1);
  assert.equal(r.rate, 50);
  assert.equal(r.avgDelayDays, 2);
  assert.equal(r.worstDelayDays, 2);
  assert.equal(r.lateJobs[0].finishedDay, '2026-09-07');
});

test('a job with no due date made no promise, and nothing promised is no record', () => {
  const r = T.onTime([job({ dueDate: null }), job({ dueDate: '' })]);
  assert.equal(r.promised, 0);
  assert.equal(r.rate, null, 'not 0%, not 100%');
  assert.equal(r.avgDelayDays, null);
  assert.deepEqual(r.lateJobs, []);
});

test('voided, unfinished and out-of-trade jobs are not promises', () => {
  const r = T.onTime([
    job(), job({ voidedAt: 'x' }), job({ status: 'pending' }), job({ status: 'quote' }), job({ hobby: true }),
  ], { countsForBusiness: (o) => !o.hobby });
  assert.equal(r.promised, 1);
});

test('the finish is judged in the shop\'s own day, on or before the due day', () => {
  // 23:30 local on the due day is on time; the UTC date of that instant may be the next day.
  const lateNight = new Date(2026, 8, 5, 23, 30).toISOString();
  assert.equal(T.onTime([job({ completedAt: lateNight })]).onTime, 1);
  // Exactly the due day, by the day taken when there is no finish instant.
  assert.equal(T.onTime([job({ completedAt: undefined, date: '2026-09-05' })]).onTime, 1);
  assert.equal(T.onTime([job({ completedAt: undefined, date: '2026-09-06' })]).late, 1);
});

test('the late list is worst first, with how many days each missed by', () => {
  const r = T.onTime([
    job({ id: 'A', completedAt: '2026-09-06T10:00:00' }),   // 1 day
    job({ id: 'B', completedAt: '2026-09-15T10:00:00' }),   // 10 days
    job({ id: 'C' }),                                        // on time
  ]);
  assert.deepEqual(r.lateJobs.map((j) => [j.id, j.delayDays]), [['B', 10], ['A', 1]]);
  assert.equal(r.avgDelayDays, 5.5);
  assert.equal(r.worstDelayDays, 10);
  assert.equal(r.rate, 33.3);
});

test('a window by the day the job was taken', () => {
  const r = T.onTime([job({ date: '2026-08-01' }), job({ date: '2026-09-01' })], { since: '2026-09-01' });
  assert.equal(r.promised, 1);
});
