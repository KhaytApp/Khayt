'use strict';
// lib/vat-periods.js returnPeriodFor: the period the VAT return card opens on.
// It opened on the last ENDED period for ever, so in November a quarterly
// filer saw Q3, whose return was due by Oct 31 (Nov 11 desktop UI review, X15).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { returnPeriodFor } = require('../lib/vat-periods.js');

test('quarterly: the ended quarter until the end of the next month, then the running one', () => {
  assert.equal(returnPeriodFor('2026-10-01', 'quarterly'), '2026-Q3');
  assert.equal(returnPeriodFor('2026-10-31', 'quarterly'), '2026-Q3');
  assert.equal(returnPeriodFor('2026-11-01', 'quarterly'), '2026-Q4');
  assert.equal(returnPeriodFor('2026-11-11', 'quarterly'), '2026-Q4');
  assert.equal(returnPeriodFor('2026-12-31', 'quarterly'), '2026-Q4');
});

test('across New Year the previous year\'s Q4 is the one being filed in January', () => {
  assert.equal(returnPeriodFor('2027-01-15', 'quarterly'), '2026-Q4');
  assert.equal(returnPeriodFor('2027-02-01', 'quarterly'), '2027-Q1');
});

test('monthly filers: last month until the end of this month', () => {
  assert.equal(returnPeriodFor('2026-11-11', 'monthly'), '2026-10');
  assert.equal(returnPeriodFor('2026-11-30', 'monthly'), '2026-10');
  assert.equal(returnPeriodFor('2026-12-01', 'monthly'), '2026-11');
  assert.equal(returnPeriodFor('2027-01-05', 'monthly'), '2026-12');
});

test('a day that is not one gives nothing', () => {
  assert.equal(returnPeriodFor('', 'quarterly'), '');
  assert.equal(returnPeriodFor('soon', 'monthly'), '');
});
